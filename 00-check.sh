#!/usr/bin/env bash
# Prerequisite check. Changes nothing; prints what is missing and how to install it.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KIT_DIR
# shellcheck source=config.sh
source "$KIT_DIR/config.sh"

ok=0; bad=0; FIX=()
pass() { printf '  [ok]   %s\n' "$*"; ok=$((ok + 1)); }
fail() { printf '  [MISS] %s\n' "$*"; bad=$((bad + 1)); }
info() { printf '  [info] %s\n' "$*"; }
fix()  { FIX+=("$*"); }
NOTES=()
note() { NOTES+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== tools"
for t in git curl jq python3 awk pgrep; do
  if have "$t"; then pass "$t"; else
    fail "$t"
    case $t in
      python3) fix "sudo pacman -S --needed python" ;;
      pgrep) fix "sudo pacman -S --needed procps-ng" ;;
      awk) fix "sudo pacman -S --needed gawk" ;;
      *) fix "sudo pacman -S --needed $t" ;;
    esac
  fi
done
if have gh; then
  pass "gh $(gh --version | head -n1 | awk '{print $3}')"
  if gh auth status >/dev/null 2>&1; then pass "gh is logged in"; else fail "gh not logged in (needed only to push the blind folder)"; fix "gh auth login"; fi
else
  fail "gh (GitHub CLI, needed only to push the blind folder)"; fix "sudo pacman -S --needed github-cli"
fi
if have hf; then pass "hf CLI"; else fail "hf CLI (only needed to download models)"; fix "pipx install huggingface_hub"; fi

echo "== docker (required by Aider Polyglot; also used for sandboxed Rust checks)"
if have "${DOCKER_CMD[0]}"; then
  pass "docker binary"
  if "${DOCKER_CMD[@]}" info >/dev/null 2>&1; then
    pass "docker daemon reachable as $(id -un)"
    if "${DOCKER_CMD[@]}" buildx version >/dev/null 2>&1; then pass "docker buildx"; else fail "docker buildx (legacy builder works but warns)"; fix "sudo pacman -S --needed docker-buildx"; fi
  else
    fail "docker daemon not reachable (not running, or $(id -un) not in the docker group)"
    fix "sudo systemctl enable --now docker.service"
    fix "sudo usermod -aG docker $(id -un)"; note "after usermod, log out and back in (or run newgrp docker) so the group applies"
  fi
else
  fail "docker"; fix "sudo pacman -S --needed docker docker-buildx"; fix "sudo systemctl enable --now docker.service"
  fix "sudo usermod -aG docker $(id -un)"; note "after usermod, log out and back in so the docker group applies"
fi

echo "== rust toolchain on the host (optional: only for ./22-custom-check.sh --native)"
if have cargo; then
  pass "cargo $(cargo --version | awk '{print $2}')"
  if cargo clippy --version >/dev/null 2>&1; then pass "clippy"; else fail "clippy"; fix "rustup component add clippy"; note "clippy/rustfmt: the pacman rust package bundles both; with rustup use the component add commands"; fi
  if cargo fmt --version >/dev/null 2>&1; then pass "rustfmt"; else fail "rustfmt"; fix "rustup component add rustfmt"; fi
else
  info "no cargo on host; fine if you use the docker checks (default)"
  info "to install it anyway: sudo pacman -S --needed rustup; rustup default stable; rustup component add clippy rustfmt"
fi

echo "== llama.cpp"
if [[ -x "$LLAMA_SERVER" ]]; then
  pass "llama-server at $LLAMA_SERVER"
  ver="$("$LLAMA_SERVER" --version 2>&1 | grep -m1 -o 'build [0-9]*' || true)"
  info "${ver:-version unknown}"
  help="$("$LLAMA_SERVER" --help 2>&1 || true)"
  for flag in --reasoning-format --api-key-file --no-kv-unified --presence-penalty --jinja; do
    if grep -q -- "$flag" <<<"$help"; then pass "supports $flag"; else fail "llama-server lacks $flag: edit COMMON_SERVER_ARGS in config.sh or update llama.cpp"; fi
  done
else
  fail "llama-server not found at $LLAMA_SERVER: edit LLAMA_SERVER in config.sh"
fi
if [[ -r "$API_KEY_FILE" ]]; then pass "API key file $API_KEY_FILE"; else
  fail "API key file $API_KEY_FILE"
  fix "mkdir -p ~/.config/llama; openssl rand -hex 32 > ~/.config/llama/api-key; chmod 600 ~/.config/llama/api-key"
fi
if pgrep -x llama-server >/dev/null; then info "a llama-server is running now; the scripts will stop it before each load"; fi

echo "== models"
total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
info "RAM total $((total_kb / 1048576)) GiB"
for m in "${MODELS_DEFAULT[@]}"; do
  p="${MODEL_PATH[$m]}"
  if [[ -f "$p" ]]; then
    sz=0
    if [[ "$p" =~ ^(.*)-00001-of-([0-9]{5})\.gguf$ ]]; then
      n=$((10#${BASH_REMATCH[2]})); cnt=0
      for f in "${BASH_REMATCH[1]}"-*-of-"${BASH_REMATCH[2]}".gguf; do sz=$((sz + $(stat -c %s "$f"))); cnt=$((cnt + 1)); done
      if ((cnt == n)); then pass "$m: all $n parts, $((sz / 1073741824)) GiB"; else fail "$m: only $cnt of $n split parts present"; fi
    else
      sz=$(stat -c %s "$p"); pass "$m: $(basename "$p") $((sz / 1073741824)) GiB"
    fi
  else
    fail "$m: $p not found"
    case $m in
      qwen) fix "hf download unsloth/Qwen3.8-27B-GGUF --include 'BF16/*' --local-dir ~/models/qwen3.8-27b" ;;
      ornith) fix "hf download ornith-ai/Ornith-1.5-122B-GGUF Ornith-1.5-122B-Q6_K.gguf --local-dir ~/models/ornith-official" ;;
      *) note "download the $m GGUF or fix MODEL_PATH[$m] in config.sh" ;;
    esac
  fi
done

echo "== disk and port"
mkdir -p "$KIT_DIR/work"
free_gb=$(df -Pk "$KIT_DIR/work" | awk 'NR==2 {print int($4/1048576)}')
if ((free_gb >= 20)); then pass "${free_gb} GiB free under $KIT_DIR (docker image ~5 GiB, results < 2 GiB)"; else fail "only ${free_gb} GiB free under $KIT_DIR (want 20)"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HOST:$PORT/health" || true)
if [[ "$code" == "000" ]]; then pass "port $PORT free"; else info "port $PORT answers (HTTP $code): probably your current llama-server; it will be stopped"; fi

echo
echo "== $ok ok, $bad missing"
if ((${#FIX[@]})); then
  echo "Run these (fish-safe), then re-run ./00-check.sh:"
  printf '%s\n' "${FIX[@]}" | awk '!seen[$0]++' | sed 's/^/    /'
fi
if ((${#NOTES[@]})); then printf 'note: %s\n' "${NOTES[@]}"; fi
((bad == 0))
