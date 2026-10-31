#!/usr/bin/env bash
# Part 1: Aider Polyglot, one model at a time.
#   ./10-aider-bench.sh                 all models in MODELS_DEFAULT order
#   ./10-aider-bench.sh ornith minimax  only these
# Resumable: re-run the same command after a crash; finished exercises are kept.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
LOG_FILE="$LOG_DIR/aider.log"

select_models "$@"
[[ -d "$AIDER_DIR/tmp.benchmarks/polyglot-benchmark" ]] || die "run ./01-setup-aider.sh first"
"${DOCKER_CMD[@]}" image inspect "$AIDER_IMAGE" >/dev/null 2>&1 || die "docker image $AIDER_IMAGE missing; run ./01-setup-aider.sh"

LANG_TAG="${LANGUAGES:-all}"; LANG_TAG="${LANG_TAG//,/_}"
SLOTS="$THREADS"   # one llama-server slot per aider thread, each with CTX tokens
CONTAINER=""
DOCKER_PID=""
ENV_FILE="$STATE_DIR/aider.env"

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$CONTAINER" ]]; then "${DOCKER_CMD[@]}" stop -t 20 "$CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ -n "$DOCKER_PID" ]]; then wait "$DOCKER_PID" 2>/dev/null || true; fi
  rm -f "$ENV_FILE"
  stop_all_servers || true
  exit "$rc"
}
trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

write_settings() {  # model -> aider model-settings yaml (sampling sent with every request)
  local m="$1" f="$2"
  cat >"$f" <<YAML
- name: openai/bakeoff-$m
  edit_format: $EDIT_FORMAT
  use_temperature: ${MODEL_TEMP[$m]}
  reasoning_tag: think
  examples_as_sys_msg: false
  extra_params:
    timeout: 86400
    top_p: ${MODEL_TOP_P[$m]}
    presence_penalty: ${MODEL_PRESENCE[$m]}
    extra_body:
      top_k: ${MODEL_TOP_K[$m]}
      min_p: ${MODEL_MIN_P[$m]}
YAML
}

find_run_dir() {
  local name="$1" d found=()
  for d in "$AIDER_DIR/tmp.benchmarks/"*"--$name"; do [[ -d "$d" ]] && found+=("$d"); done
  ((${#found[@]} <= 1)) || die "several run dirs match *--$name; move the old ones out of $AIDER_DIR/tmp.benchmarks"
  ((${#found[@]} == 1)) && echo "${found[0]}"
  return 0
}

run_model() {
  local m="$1" run_name pass rc restarts=0 run_dir out bargs settings
  run_name="bakeoff-$m-$EDIT_FORMAT-$LANG_TAG${NUM_TESTS:+-n$NUM_TESTS}"
  out="$RESULTS_DIR/$m"
  if [[ -f "$out/DONE-$run_name" ]]; then log "$m: $run_name already complete, skipping (delete $out/DONE-$run_name to redo)"; return 0; fi
  mkdir -p "$out"
  settings="bakeoff-settings-$m.yml"
  write_settings "$m" "$AIDER_DIR/tmp.benchmarks/$settings"
  cp "$AIDER_DIR/tmp.benchmarks/$settings" "$out/aider-model-settings.yml"

  bargs=(--model "openai/bakeoff-$m" --edit-format "$EDIT_FORMAT" --threads "$THREADS" --tries "$TRIES"
    --exercises-dir polyglot-benchmark --read-model-settings "/benchmarks/$settings" --cont)
  [[ -n "$LANGUAGES" ]] && bargs+=(--languages "$LANGUAGES")
  [[ -n "$NUM_TESTS" ]] && bargs+=(--num-tests "$NUM_TESTS")

  start_server "$m"
  cp "$STATE_DIR/server-cmd-$m.txt" "$out/server-cmd.txt"

  for ((pass = 1; pass <= MAX_PASSES; pass++)); do
    log "$m: aider pass $pass/$MAX_PASSES ($run_name)"
    umask 077
    printf 'OPENAI_API_KEY=%s\nOPENAI_API_BASE=%s/v1\nAIDER_DOCKER=1\nAIDER_BENCHMARK_DIR=/benchmarks\nHOST_UID=%s\nHOST_GID=%s\n' \
      "$(api_key)" "$(base_url)" "$(id -u)" "$(id -g)" >"$ENV_FILE"
    umask 022
    CONTAINER="bakeoff-aider-$m-$$"
    "${DOCKER_CMD[@]}" run --rm --init --name "$CONTAINER" --network host \
      --memory "$DOCKER_MEMORY" --memory-swap "$DOCKER_MEMORY" \
      --env-file "$ENV_FILE" \
      -v "$AIDER_DIR:/aider" -v "$AIDER_DIR/tmp.benchmarks:/benchmarks" -v "$KIT_DIR/lib:/kit:ro" \
      "$AIDER_IMAGE" bash /kit/aider_in_container.sh "$run_name" "${bargs[@]}" \
      >>"$LOG_DIR/aider-$m.log" 2>&1 &
    DOCKER_PID=$!
    log "$m: benchmark running (container $CONTAINER); progress: tail -f logs/aider-$m.log"
    # Watchdog: if llama-server dies, restart it; aider keeps retrying the request meanwhile.
    while kill -0 "$DOCKER_PID" 2>/dev/null; do
      sleep "$WATCHDOG_INTERVAL"
      kill -0 "$DOCKER_PID" 2>/dev/null || break
      if ! server_alive; then
        sleep 15
        if ! server_alive; then
          restarts=$((restarts + 1))
          ((restarts <= MAX_SERVER_RESTARTS)) || die "$m: llama-server died $restarts times; giving up (re-run to resume)"
          warn "$m: llama-server is down, restart $restarts/$MAX_SERVER_RESTARTS"
          start_server "$m"
        fi
      fi
    done
    rc=0; wait "$DOCKER_PID" || rc=$?
    DOCKER_PID=""; CONTAINER=""
    rm -f "$ENV_FILE"
    log "$m: container exited with $rc"

    run_dir="$(find_run_dir "$run_name")"
    [[ -n "$run_dir" ]] || die "$m: no run dir *--$run_name created; see logs/aider-$m.log"
    rc=0
    python3 "$KIT_DIR/lib/aider_stats.py" run "$run_dir" --model "$m" --out "$out" \
      --languages "$LANGUAGES" --num-tests "${NUM_TESTS:-0}" --tries "$TRIES" \
      --meta "desc=${MODEL_DESC[$m]}" --meta "edit_format=$EDIT_FORMAT" --meta "ctx=$CTX" \
      --meta "sampling=temp ${MODEL_TEMP[$m]} top_p ${MODEL_TOP_P[$m]} top_k ${MODEL_TOP_K[$m]} min_p ${MODEL_MIN_P[$m]}" \
      --meta "threads=$THREADS" --meta "aider_run_dir=$run_dir" | tee -a "$LOG_FILE" || rc=$?
    if ((rc == 0)); then
      touch "$out/DONE-$run_name"
      log "$m: complete"
      break
    fi
    [[ -n "$NUM_TESTS" ]] && { log "$m: NUM_TESTS subset run, not retrying"; break; }
    warn "$m: run incomplete after pass $pass"
    server_alive || start_server "$m"
  done
  stop_all_servers
}

for m in "${SELECTED_MODELS[@]}"; do run_model "$m"; done
python3 "$KIT_DIR/lib/aider_stats.py" summary "$RESULTS_DIR" | tee -a "$LOG_FILE" || true
log "Part 1 finished. Table: results/summary.md and results/summary.csv"
