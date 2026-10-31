#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline end-to-end test of the kit with a fake llama-server and a fake docker.
# Copies the kit to a temp dir, so it never touches your real results/ or models.
#   ./selftest/run-selftest.sh
# Needs: python3, curl, jq; for the Part 2 checks also cargo with clippy + rustfmt.
set -Eeuo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$SELF")"
T="$(mktemp -d /tmp/bakeoff-selftest.XXXXXX)"
K="$T/kit"
fails=0
ok()   { printf 'PASS %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
check() { local d="$1"; shift; if "$@" >/dev/null; then ok "$d"; else bad "$d"; fi; }

pgrep -x llama-server >/dev/null && { echo "a real llama-server is running; stop it first (the kit kills every llama-server)" >&2; exit 1; }

mkdir -p "$K"
tar -C "$SRC" --exclude=./results --exclude=./logs --exclude=./state --exclude=./work -cf - . | tar -C "$K" -xf -

# fake models
mkdir -p "$T/models/qwen/BF16" "$T/models/ornith" "$T/models/minimax"
head -c 1000 /dev/zero >"$T/models/qwen/BF16/Qwen3.8-27B-BF16-00002-of-00002.gguf"
head -c 3000 /dev/zero >"$T/models/qwen/BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf"
head -c 10 /dev/zero >"$T/models/qwen/BF16/mmproj-BF16.gguf"
head -c 2000 /dev/zero >"$T/models/ornith/Ornith-1.5-122B-Q6_K.gguf"
for i in 1 2 3 4; do head -c 500 /dev/zero >"$T/models/minimax/MiniMax-M2.5-UD-Q3_K_XL-0000$i-of-00004.gguf"; done
mkdir -p "$T/cfg"; echo "selftest-key-123" >"$T/cfg/api-key"; chmod 600 "$T/cfg/api-key"

# fake polyglot checkout: 6 languages x 2 exercises
PB="$K/work/aider/tmp.benchmarks/polyglot-benchmark"
for l in cpp go java javascript python rust; do
  for e in alpha beta; do mkdir -p "$PB/$l/exercises/practice/$l-$e"; echo x >"$PB/$l/exercises/practice/$l-$e/.keep"; done
done

export LLAMA_SERVER="$SELF/llama-server" API_KEY_FILE="$T/cfg/api-key" PORT=18080
export QWEN_DIR="$T/models/qwen/BF16"
export MODEL_PATH_ornith="$T/models/ornith/Ornith-1.5-122B-Q6_K.gguf"
export MODEL_PATH_minimax="$T/models/minimax/MiniMax-M2.5-UD-Q3_K_XL-00001-of-00004.gguf"
export DOCKER_CMD_OVERRIDE="$SELF/fake-docker"
export WATCHDOG_INTERVAL=2 LOAD_TIMEOUT=60 STOP_TIMEOUT=10 MEM_WAIT_TIMEOUT=5 MEM_HEADROOM_GB=0
export FAKE_REF_DIR="$SRC/custom/_reference" FAKE_LOAD_DELAY=2 FAKE_CRASH_FIRST=2 FAKE_REQ_LOG="$T/requests.jsonl"
cd "$K"

echo "== config resolution"
# shellcheck disable=SC1091
check "qwen path = first BF16 shard, mmproj skipped" bash -c 'KIT_DIR=. source ./config.sh; [[ "${MODEL_PATH[qwen]}" == */Qwen3.8-27B-BF16-00001-of-00002.gguf ]]'
check "empty qwen folder reports NO-GGUF-FOUND" bash -c 'QWEN_DIR=/nonexistent KIT_DIR=. source ./config.sh; [[ "${MODEL_PATH[qwen]}" == /nonexistent/NO-GGUF-FOUND ]]'
check "default order is ornith qwen minimax" bash -c 'KIT_DIR=. source ./config.sh; [[ "${MODELS_DEFAULT[*]}" == "ornith qwen minimax" ]]'
check "env MODELS overrides the order" bash -c 'MODELS="qwen minimax" KIT_DIR=. source ./config.sh; [[ "${MODELS_DEFAULT[*]}" == "qwen minimax" ]]'

echo "== 00-check (docker etc. may be reported missing here; must not crash)"
rc=0; ./00-check.sh >"$T/check.out" 2>&1 || rc=$?
check "00-check ran to the end (rc=$rc)" grep -q "== disk and port" "$T/check.out"
check "00-check sees all 4 minimax parts" grep -q "minimax: all 4 parts" "$T/check.out"
check "00-check sees both qwen parts" grep -q "qwen: all 2 parts" "$T/check.out"

echo "== Part 1: aider (qwen, ornith), first pass crashes 2 exercises each"
./10-aider-bench.sh qwen ornith >"$T/aider1.out" 2>&1 || { tail -30 "$T/aider1.out"; bad "10-aider-bench.sh qwen ornith"; }
for m in qwen ornith; do
  check "$m: stats complete 12/12" jq -e '.complete == true and .completed == 12 and .expected == 12 and .crashed == 0' "results/$m/stats.json"
  check "$m: DONE marker" test -f "results/$m/DONE-bakeoff-$m-diff-all"
  check "$m: settings yaml has sampling" grep -q "top_k: " "results/$m/aider-model-settings.yml"
done
check "pass 2 resumed after crashes" grep -q "aider pass 2/3" "$T/aider1.out"
check "purge removed crashed results" grep -q "removed 2 crashed" "$K/logs/aider-qwen.log"
check "no llama-server left running" bash -c '! pgrep -x llama-server'
check "qwen server got BF16 shard 1" grep -q "BF16-00001-of-00002" results/qwen/server-cmd.txt
check "server cmd has -fa on --jinja" grep -q -- "-fa on --jinja" results/qwen/server-cmd.txt
check "server cmd has ornith top-k 20 temp 0.6" grep -q -- "--temp 0.6 --top-p 0.95 --top-k 20" results/ornith/server-cmd.txt
pr1=$(jq .pass_rate_1 results/qwen/stats.json); pr2=$(jq .pass_rate_2 results/qwen/stats.json)
check "pass_rate_2 >= pass_rate_1 ($pr1 / $pr2)" python3 -c "import sys; sys.exit(not $pr2 >= $pr1)"

echo "== Part 1: rerun is a no-op"
./10-aider-bench.sh qwen >"$T/aider2.out" 2>&1 || bad "rerun"
check "rerun skipped qwen" grep -q "already complete, skipping" "$T/aider2.out"

echo "== Part 1: language subset (minimax, rust,go)"
env LANGUAGES=rust,go FAKE_CRASH_FIRST=0 ./10-aider-bench.sh minimax >"$T/aider3.out" 2>&1 || { tail -30 "$T/aider3.out"; bad "subset run"; }
check "minimax subset 4/4" jq -e '.completed == 4 and .expected == 4 and .languages == "rust,go"' results/minimax/stats.json

echo "== Part 1: summary"
./11-aider-summary.sh >"$T/summary.out" 2>&1 || bad "11-aider-summary.sh"
check "summary.md has 3 model rows" bash -c '[[ $(grep -cE "^\| (qwen|ornith|minimax)" results/summary.md) == 6 ]]'
check "summary.csv has header + 3 rows" bash -c '[[ $(wc -l <results/summary.csv) == 4 ]]'

echo "== Part 2: generation"
./20-custom-run.sh >"$T/custom.out" 2>&1 || { tail -30 "$T/custom.out"; bad "20-custom-run.sh"; }
check "20 ran in default order ornith, qwen, minimax" bash -c "[[ \"\$(grep -o 'starting [a-z]*' '$T/custom.out' | awk '{print \$2}' | paste -sd' ')\" == 'ornith qwen minimax' ]]"
for m in qwen ornith minimax; do
  check "$m: extracted src/lib.rs" test -s "results/custom/$m/project/src/lib.rs"
  check "$m: meta.json finish_reason stop" jq -e '.finish_reason == "stop"' "results/custom/$m/meta.json"
done
check "ornith fences stripped" bash -c '! grep -q "^\`\`\`" results/custom/ornith/project/src/lib.rs'
check "path traversal rejected" grep -q "REJECTED '../escape.txt'" results/custom/ornith/extract-report.txt
check "no file escaped project dir" test ! -e results/custom/ornith/escape.txt
check "request carried minimax top_k 40 min_p 0.01" bash -c "grep '\"bakeoff-minimax\"' '$T/requests.jsonl' | grep -q '\"top_k\": 40, \"min_p\": 0.01'"
./20-custom-run.sh qwen >"$T/custom2.out" 2>&1 || bad "20 rerun"
check "20 rerun skips existing response" grep -q "response exists, skipping" "$T/custom2.out"

echo "== Part 2: anonymize"
./21-custom-anonymize.sh >"$T/anon.out" 2>&1 || { cat "$T/anon.out"; bad "21-custom-anonymize.sh"; }
check "blind A B C exist" test -d results/custom-blind/A -a -d results/custom-blind/B -a -d results/custom-blind/C
check "mapping outside blind folder" test -f results/custom-mapping.json
check "mapping is a permutation" jq -e '[.mapping[]] | sort == ["minimax","ornith","qwen"]' results/custom-mapping.json
check "no model names in blind folder paths" bash -c '! find results/custom-blind | grep -iqE "qwen|ornith|minimax"'
check "reference impl not in blind folder" bash -c '! find results/custom-blind -name _reference | grep -q .'
rc=0; ./21-custom-anonymize.sh >/dev/null 2>&1 || rc=$?
check "anonymize refuses to overwrite" test "$rc" -ne 0

echo "== Part 2: checks (native cargo)"
if cargo clippy --version >/dev/null 2>&1 && cargo fmt --version >/dev/null 2>&1; then
  ./22-custom-check.sh --native >"$T/checks.out" 2>&1 || { tail -30 "$T/checks.out"; bad "22-custom-check.sh"; }
  broken=$(jq -r '.mapping | to_entries[] | select(.value=="minimax") | .key' results/custom-mapping.json)
  for L in A B C; do
    f="results/custom-blind/checks/$L/results.json"
    if [[ "$L" == "$broken" ]]; then
      check "$L (broken entry): hidden suite fails" jq -e '.hidden_tests.passed == 0 and .exit_codes.hidden != "0"' "$f"
    else
      check "$L: fmt/clippy/build/test pass, hidden 26/26" jq -e '.exit_codes.fmt=="0" and .exit_codes.clippy=="0" and .exit_codes.build=="0" and .exit_codes.test=="0" and .hidden_tests.passed==26' "$f"
    fi
  done
  check "SUMMARY.md written" test -s results/custom-blind/checks/SUMMARY.md
else
  echo "SKIP cargo checks: clippy/rustfmt not available"
fi

echo
echo "selftest dir: $T"
if ((fails)); then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
