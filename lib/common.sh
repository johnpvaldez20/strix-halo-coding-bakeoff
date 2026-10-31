# shellcheck shell=bash
# Shared helpers. Sourced by the numbered scripts (bash only).

set -Eeuo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_DIR
# shellcheck source=../config.sh
source "$KIT_DIR/config.sh"

RESULTS_DIR="$KIT_DIR/results"
LOG_DIR="$KIT_DIR/logs"
STATE_DIR="$KIT_DIR/state"
mkdir -p "$RESULTS_DIR" "$LOG_DIR" "$STATE_DIR"
: "${LOG_FILE:=$LOG_DIR/bakeoff.log}"
SERVER_PID_FILE="$STATE_DIR/server.pid"
SERVER_MODEL_FILE="$STATE_DIR/server.model"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

base_url() { printf 'http://%s:%s' "$HOST" "$PORT"; }

api_key() {
  [[ -r "$API_KEY_FILE" ]] || die "API key file not readable: $API_KEY_FILE"
  # first non-comment, non-empty line
  grep -v -e '^#' -e '^[[:space:]]*$' "$API_KEY_FILE" | head -n1 | tr -d '[:space:]'
}

# Selected models: command-line args, else MODELS_DEFAULT. Validates names.
select_models() {
  local m
  SELECTED_MODELS=()
  if (($# == 0)); then SELECTED_MODELS=("${MODELS_DEFAULT[@]}"); else SELECTED_MODELS=("$@"); fi
  for m in "${SELECTED_MODELS[@]}"; do
    [[ -n "${MODEL_PATH[$m]:-}" ]] || die "unknown model '$m' (known: ${!MODEL_PATH[*]})"
  done
}

# Total bytes of a GGUF, summing all split parts (-00001-of-0000N.gguf).
model_bytes() {
  local first="$1" total=0 f pattern
  if [[ "$first" =~ ^(.*)-00001-of-([0-9]{5})\.gguf$ ]]; then
    pattern="${BASH_REMATCH[1]}-*-of-${BASH_REMATCH[2]}.gguf"
    for f in $pattern; do
      [[ -f "$f" ]] && total=$((total + $(stat -c %s "$f")))
    done
  elif [[ -f "$first" ]]; then
    total=$(stat -c %s "$first")
  fi
  echo "$total"
}

mem_available_bytes() { awk '/^MemAvailable:/ {print $2 * 1024}' /proc/meminfo; }

llama_pids() { pgrep -x llama-server || true; }

# Kill every llama-server we are allowed to kill, wait until all are gone.
stop_all_servers() {
  local pids waited=0
  pids="$(llama_pids)"
  if [[ -z "$pids" ]]; then rm -f "$SERVER_PID_FILE" "$SERVER_MODEL_FILE"; return 0; fi
  log "stopping llama-server (pids: $(echo "$pids" | tr '\n' ' '))"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  while [[ -n "$(llama_pids)" ]]; do
    if ((waited >= STOP_TIMEOUT)); then
      warn "llama-server still running after ${STOP_TIMEOUT}s, sending SIGKILL"
      pids="$(llama_pids)"
      # shellcheck disable=SC2086
      kill -KILL $pids 2>/dev/null || true
      sleep 5
      [[ -z "$(llama_pids)" ]] || die "cannot stop llama-server (owned by another user or a systemd unit?): $(llama_pids | tr '\n' ' ')"
      break
    fi
    sleep 2; waited=$((waited + 2))
  done
  rm -f "$SERVER_PID_FILE" "$SERVER_MODEL_FILE"
  log "llama-server stopped"
}

# Wait until MemAvailable >= model size + headroom. Warns (does not abort) on timeout.
wait_for_memory() {
  local need_bytes="$1" waited=0 avail
  need_bytes=$((need_bytes + MEM_HEADROOM_GB * 1024 * 1024 * 1024))
  while :; do
    avail="$(mem_available_bytes)"
    if ((avail >= need_bytes)); then
      log "memory ok: $((avail / 1073741824)) GiB available, need $((need_bytes / 1073741824)) GiB"
      return 0
    fi
    if ((waited >= MEM_WAIT_TIMEOUT)); then
      warn "only $((avail / 1073741824)) GiB available, want $((need_bytes / 1073741824)) GiB; continuing anyway (close other programs if the load fails)"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
}

# Number of server slots = aider threads (custom part always uses 1).
server_slots() { echo "${SLOTS:-1}"; }

server_cmd() {
  local m="$1" slots extra=()
  slots="$(server_slots)"
  if [[ -n "${MODEL_EXTRA_ARGS[$m]}" ]]; then read -r -a extra <<<"${MODEL_EXTRA_ARGS[$m]}"; fi
  SERVER_CMD=("$LLAMA_SERVER" -m "${MODEL_PATH[$m]}" --alias "bakeoff-$m"
    "${COMMON_SERVER_ARGS[@]}"
    -c "$((CTX * slots))" -np "$slots"
    --temp "${MODEL_TEMP[$m]}" --top-p "${MODEL_TOP_P[$m]}" --top-k "${MODEL_TOP_K[$m]}"
    --min-p "${MODEL_MIN_P[$m]}" --presence-penalty "${MODEL_PRESENCE[$m]}"
    --host "$HOST" --port "$PORT" --api-key-file "$API_KEY_FILE" --timeout "$SERVER_TIMEOUT"
    "${extra[@]}")
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }

# Start model $1 and block until /health returns 200.
start_server() {
  local m="$1" ts slog pid waited=0 code bytes
  [[ -f "${MODEL_PATH[$m]}" ]] || die "model file missing for $m: ${MODEL_PATH[$m]}"
  [[ -x "$LLAMA_SERVER" ]] || die "llama-server not executable: $LLAMA_SERVER"
  stop_all_servers
  code="$(http_code "$(base_url)/health")"
  [[ "$code" == "000" ]] || die "something else answers on $(base_url) (HTTP $code); free port $PORT first"
  bytes="$(model_bytes "${MODEL_PATH[$m]}")"
  wait_for_memory "$bytes"
  server_cmd "$m"
  ts="$(date +%Y%m%d-%H%M%S)"
  slog="$LOG_DIR/server-$m-$ts.log"
  log "starting $m: ${SERVER_CMD[*]}"
  printf '%q ' "${SERVER_CMD[@]}" >"$STATE_DIR/server-cmd-$m.txt"
  nohup "${SERVER_CMD[@]}" >"$slog" 2>&1 </dev/null &
  pid=$!
  echo "$pid" >"$SERVER_PID_FILE"
  echo "$m" >"$SERVER_MODEL_FILE"
  # shellcheck disable=SC2034  # read by callers
  SERVER_LOG="$slog"
  log "llama-server pid $pid, log $slog; waiting for /health (up to ${LOAD_TIMEOUT}s)"
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 30 "$slog" >&2 || true
      die "llama-server for $m exited during load (see $slog)"
    fi
    code="$(http_code "$(base_url)/health")"
    [[ "$code" == "200" ]] && break
    if ((waited >= LOAD_TIMEOUT)); then
      die "llama-server for $m not healthy after ${LOAD_TIMEOUT}s (last HTTP $code, see $slog)"
    fi
    sleep 5; waited=$((waited + 5))
    if ((waited % 60 == 0)); then log "  still loading $m (${waited}s, HTTP $code)"; fi
  done
  code="$(http_code -H "Authorization: Bearer $(api_key)" "$(base_url)/v1/models")"
  [[ "$code" == "200" ]] || die "/v1/models returned HTTP $code with the API key from $API_KEY_FILE"
  log "$m ready after ${waited}s"
}

server_alive() {
  local pid
  pid="$(cat "$SERVER_PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ "$(http_code "$(base_url)/health")" == "200" ]]
}
