#!/usr/bin/env bash
# Part 2 step 1: send custom/prompt.md to each model once, save the answer, extract files.
#   ./20-custom-run.sh               all models
#   ./20-custom-run.sh qwen          one model
#   env FORCE=1 ./20-custom-run.sh   regenerate even if a response exists
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
LOG_FILE="$LOG_DIR/custom.log"
select_models "$@"
PROMPT="$KIT_DIR/custom/prompt.md"
[[ -s "$PROMPT" ]] || die "missing $PROMPT"
SLOTS=1
trap 'stop_all_servers || true' EXIT
trap 'log "interrupted"; exit 130' INT TERM

for m in "${SELECTED_MODELS[@]}"; do
  out="$RESULTS_DIR/custom/$m"
  if [[ -z "${FORCE:-}" ]] && jq -e '.choices[0].message.content | length > 0' "$out/response.json" >/dev/null 2>&1; then
    log "$m: response exists, skipping (env FORCE=1 to redo)"
    continue
  fi
  rm -rf "$out"; mkdir -p "$out"
  start_server "$m"
  body="$out/request.json"
  jq -n --rawfile prompt "$PROMPT" --arg model "bakeoff-$m" \
    --argjson temp "${MODEL_TEMP[$m]}" --argjson top_p "${MODEL_TOP_P[$m]}" \
    --argjson top_k "${MODEL_TOP_K[$m]}" --argjson min_p "${MODEL_MIN_P[$m]}" \
    --argjson presence "${MODEL_PRESENCE[$m]}" --arg max_tokens "$CUSTOM_MAX_TOKENS" '
    {model: $model, stream: false,
     messages: [{role: "user", content: $prompt}],
     temperature: $temp, top_p: $top_p, top_k: $top_k, min_p: $min_p, presence_penalty: $presence}
    + (if $max_tokens == "" then {} else {max_tokens: ($max_tokens | tonumber)} end)' >"$body"
  log "$m: generating (no client timeout; Qwen BF16 can take hours). Server log: $SERVER_LOG"
  start=$(date +%s)
  hdr="$STATE_DIR/curl-hdr"
  printf 'Authorization: Bearer %s\n' "$(api_key)" >"$hdr"; chmod 600 "$hdr"
  code=$(curl -sS -o "$out/response.json" -w '%{http_code}' -H "@$hdr" -H 'Content-Type: application/json' \
    --data-binary "@$body" "$(base_url)/v1/chat/completions") || code="curl-failed"
  rm -f "$hdr"
  secs=$(($(date +%s) - start))
  [[ "$code" == 200 ]] || die "$m: HTTP $code after ${secs}s; see $out/response.json and $SERVER_LOG"
  jq -r '.choices[0].message.content // ""' "$out/response.json" >"$out/response.md"
  jq -r '.choices[0].message.reasoning_content // ""' "$out/response.json" >"$out/reasoning.md"
  jq --argjson secs "$secs" --arg desc "${MODEL_DESC[$m]}" '{model: .model, desc: $desc, wall_seconds: $secs,
      finish_reason: .choices[0].finish_reason, usage: .usage, timings: .timings}' "$out/response.json" >"$out/meta.json"
  cp "$STATE_DIR/server-cmd-$m.txt" "$out/server-cmd.txt"
  fr=$(jq -r .finish_reason "$out/meta.json")
  [[ "$fr" == stop ]] || warn "$m: finish_reason=$fr (length = hit the context/max_tokens limit; answer may be truncated)"
  python3 "$KIT_DIR/lib/extract_files.py" "$out/response.md" "$out/project" | tee -a "$LOG_FILE" ||
    warn "$m: no files extracted; check $out/response.md"
  log "$m: done in ${secs}s, $(jq -r '.usage.completion_tokens // "?"' "$out/meta.json") completion tokens"
  stop_all_servers
done
log "Part 2 generation finished. Next: ./21-custom-anonymize.sh"
