# shellcheck shell=bash disable=SC2034
# Bake-off configuration. Edit this file; the scripts read it.
# Every variable written as ': "${VAR:=default}"' can also be overridden
# per run from fish with:   env CTX=32768 ./10-aider-bench.sh

# ---------------------------------------------------------------- server
: "${LLAMA_SERVER:=$HOME/src/llama.cpp/build/bin/llama-server}"
: "${API_KEY_FILE:=$HOME/.config/llama/api-key}"
: "${HOST:=127.0.0.1}"
: "${PORT:=8080}"
: "${CTX:=65536}"                 # context per request, same for all models
: "${LOAD_TIMEOUT:=3600}"         # seconds to wait for /health after launch
: "${STOP_TIMEOUT:=180}"          # seconds to wait for llama-server to exit
: "${MEM_WAIT_TIMEOUT:=600}"      # seconds to wait for RAM to be released
: "${MEM_HEADROOM_GB:=6}"         # free RAM required on top of the model file size
: "${SERVER_TIMEOUT:=172800}"     # llama-server --timeout (socket r/w), 48 h

# Flags shared by all three models. -np is set from THREADS (one slot per
# aider thread); the total -c is CTX * slots so every request gets CTX.
COMMON_SERVER_ARGS=(-ngl 999 -fa on --jinja --reasoning-format deepseek --no-kv-unified)

# ---------------------------------------------------------------- models
# Run order (ornith, then qwen, then minimax). Reorder or remove names here, or pass
# names on the command line, e.g. ./10-aider-bench.sh qwen ornith
MODELS_DEFAULT=(ornith qwen minimax)
# Or per run from fish: env MODELS="qwen minimax" ./20-custom-run.sh
if [[ -n "${MODELS:-}" ]]; then read -r -a MODELS_DEFAULT <<<"$MODELS"; fi

declare -A MODEL_PATH MODEL_DESC MODEL_TEMP MODEL_TOP_P MODEL_TOP_K MODEL_MIN_P MODEL_PRESENCE MODEL_EXTRA_ARGS

# First .gguf in a folder, sorted (part -00001-of- when split), skipping mmproj files.
# Prints "<dir>/NO-GGUF-FOUND" if there is none, so ./00-check.sh reports it.
first_gguf() {
  local dir="$1" f
  f="$(find "$dir" -maxdepth 1 -type f -name '*.gguf' ! -iname '*mmproj*' 2>/dev/null | LC_ALL=C sort | head -n 1)"
  printf '%s\n' "${f:-$dir/NO-GGUF-FOUND}"
}

# Qwen3.8-27B, dense, Unsloth BF16 (native precision). Path = first .gguf in the folder.
# Sampling = Qwen's official "Thinking Mode" values (Qwen/Qwen3.8-27B model card,
# Best Practices). Thinking is on by default.
# Fallback if BF16 will not load on Vulkan: set QWEN_DIR or replace this line with
# MODEL_PATH[qwen]="$HOME/models/qwen3.8-27b/Qwen3.8-27B-Q8_0.gguf"
: "${QWEN_DIR:=$HOME/models/qwen3.8-27b/BF16}"
MODEL_PATH[qwen]="$(first_gguf "$QWEN_DIR")"
MODEL_DESC[qwen]="Qwen3.8-27B dense BF16 (unsloth)"
MODEL_TEMP[qwen]=1.0; MODEL_TOP_P[qwen]=0.95; MODEL_TOP_K[qwen]=20; MODEL_MIN_P[qwen]=0.0; MODEL_PRESENCE[qwen]=0.0
MODEL_EXTRA_ARGS[qwen]=""

# Ornith-1.5-122B MoE, official Q6_K. Sampling = authors' "precise coding" values.
MODEL_PATH[ornith]="$HOME/models/ornith-official/Ornith-1.5-122B-Q6_K.gguf"
MODEL_DESC[ornith]="Ornith-1.5-122B MoE Q6_K"
MODEL_TEMP[ornith]=0.6; MODEL_TOP_P[ornith]=0.95; MODEL_TOP_K[ornith]=20; MODEL_MIN_P[ornith]=0.0; MODEL_PRESENCE[ornith]=0.0
MODEL_EXTRA_ARGS[ornith]=""

# MiniMax-M2.5 230B MoE, Unsloth UD-Q3_K_XL (4 split files; give part 1).
# Sampling = MiniMax/Unsloth recommendation.
MODEL_PATH[minimax]="$HOME/models/minimax/UD-Q3_K_XL/MiniMax-M2.5-UD-Q3_K_XL-00001-of-00004.gguf"
MODEL_DESC[minimax]="MiniMax-M2.5 230B MoE UD-Q3_K_XL"
MODEL_TEMP[minimax]=1.0; MODEL_TOP_P[minimax]=0.95; MODEL_TOP_K[minimax]=40; MODEL_MIN_P[minimax]=0.01; MODEL_PRESENCE[minimax]=0.0
MODEL_EXTRA_ARGS[minimax]=""
# MODEL_EXTRA_ARGS is split on spaces, e.g. "--no-mmap" or "-ub 2048".

# Per-run path override without editing this file, e.g. from fish:
#   env MODEL_PATH_qwen=/path/to/other.gguf ./20-custom-run.sh qwen
for _m in "${!MODEL_PATH[@]}"; do
  _v="MODEL_PATH_$_m"
  if [[ -n "${!_v:-}" ]]; then MODEL_PATH[$_m]="${!_v}"; fi
done
unset _m _v

# ---------------------------------------------------------------- part 1: aider polyglot
: "${WORK_DIR:=$KIT_DIR/work}"
: "${AIDER_DIR:=$WORK_DIR/aider}"
: "${AIDER_REF:=main}"            # git ref of Aider-AI/aider to check out (pin a commit for repeatability)
: "${AIDER_IMAGE:=aider-benchmark}"
: "${EDIT_FORMAT:=diff}"          # same for all models; "whole" is the forgiving alternative
: "${TRIES:=2}"                   # pass_rate_1 / pass_rate_2
: "${THREADS:=1}"                 # parallel exercises; >1 adds llama-server slots
: "${LANGUAGES:=}"                # empty = all 225 exercises; e.g. rust,java for a quick run
: "${NUM_TESTS:=}"                # empty = all; a number = random subset (smoke test only)
: "${MAX_PASSES:=3}"              # re-run passes to retry exercises that crashed
: "${MAX_SERVER_RESTARTS:=5}"     # per model, if llama-server dies mid-run
: "${WATCHDOG_INTERVAL:=30}"      # seconds between llama-server health checks during a run
: "${DOCKER_MEMORY:=12g}"         # container RAM limit (the model runs outside it)
# Command used to call docker. Use (sudo docker) if you are not in the docker group.
if [[ -z "${DOCKER_CMD_OVERRIDE:-}" ]]; then DOCKER_CMD=(docker); else read -r -a DOCKER_CMD <<<"$DOCKER_CMD_OVERRIDE"; fi

# ---------------------------------------------------------------- part 2: custom rust project
: "${CUSTOM_MAX_TOKENS:=}"        # empty = no cap (generation stops at end of context)
: "${CHECKS_IMAGE:=bakeoff-rust-checks}"
