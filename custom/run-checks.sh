#!/usr/bin/env bash
# Mechanical checks for the blind entries. Run from this folder.
#   ./run-checks.sh              all entries (A, B, C, ...) inside a docker sandbox (default)
#   ./run-checks.sh B            one entry
#   ./run-checks.sh --native     use the host's cargo instead of docker (runs model-written code on your machine)
# Output: checks/<letter>/*.log, checks/<letter>/results.json, checks/SUMMARY.md
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
HERE="$PWD"
IMAGE="${CHECKS_IMAGE:-bakeoff-rust-checks}"
TEST_TIMEOUT="${TEST_TIMEOUT:-900}"
read -r -a DOCKER <<<"${DOCKER_CMD_OVERRIDE:-docker}"
native=0; inside=0; letters=()
for a in "$@"; do
  case "$a" in
    --native) native=1 ;;
    --in-container) native=1; inside=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) letters+=("$a") ;;
  esac
done
if ((${#letters[@]} == 0)); then
  for d in [A-Z]; do [[ -d "$d" ]] && letters+=("$d"); done
fi
((${#letters[@]})) || { echo "no entry folders (A, B, ...) here" >&2; exit 1; }

if ((native == 0)); then
  "${DOCKER[@]}" build -q -t "$IMAGE" -f checks.Dockerfile . >/dev/null
  exec "${DOCKER[@]}" run --rm --network none --memory 8g --pids-limit 4096 \
    --user "$(id -u):$(id -g)" -e CARGO_HOME=/tmp/cargo -e HOME=/tmp -e TEST_TIMEOUT \
    -v "$HERE:/blind" -w /blind "$IMAGE" bash ./run-checks.sh --in-container "${letters[@]}"
fi
((inside)) || echo "warning: --native runs model-written build and test code directly on this machine" >&2
command -v cargo >/dev/null || { echo "cargo not found" >&2; exit 1; }
cargo clippy --version >/dev/null 2>&1 || { echo "clippy missing: rustup component add clippy" >&2; exit 1; }
cargo fmt --version >/dev/null 2>&1 || { echo "rustfmt missing: rustup component add rustfmt" >&2; exit 1; }

HIDDEN_TOTAL=$(grep -c '^#\[test\]' hidden-tests/hidden_suite.rs)
mkdir -p checks

step() {  # name, timeout_s, command... -> logs/exit code into $out
  local name="$1" t="$2"; shift 2
  local rc=0
  timeout -k 10 "$t" "$@" >"$out/$name.log" 2>&1 || rc=$?
  echo "$rc" >"$out/$name.rc"
  ((rc == 124 || rc == 137)) && echo "TIMEOUT after ${t}s" >>"$out/$name.log"
  return 0
}
rc_of() { cat "$out/$1.rc" 2>/dev/null || echo skipped; }
count_tests() {  # log -> "passed failed"
  awk '/^test result:/ { for (i=1;i<=NF;i++) { if ($(i+1) ~ /^passed/) p+=$i; if ($(i+1) ~ /^failed/) f+=$i } }
       END { printf "%d %d\n", p, f }' "$1"
}

for L in "${letters[@]}"; do
  echo "== $L"
  out="$HERE/checks/$L"; work="$HERE/checks/work/$L"
  rm -rf "$out" "$work"; mkdir -p "$out" "$(dirname "$work")"
  cp -r "$HERE/$L" "$work"; rm -rf "$work/target"
  export CARGO_TARGET_DIR="$work/target"
  if [[ ! -f "$work/Cargo.toml" ]]; then
    echo "no Cargo.toml" >"$out/build.log"; echo 101 >"$out/build.rc"
  else
    (cd "$work" && step fmt 300 cargo fmt --check)
    (cd "$work" && step clippy 1800 cargo clippy --offline --all-targets -- -D warnings)
    (cd "$work" && step build 1800 cargo build --offline)
    (cd "$work" && step test "$TEST_TIMEOUT" cargo test --offline)
    mkdir -p "$work/tests"; cp hidden-tests/hidden_suite.rs "$work/tests/hidden_suite.rs"
    (cd "$work" && step hidden "$TEST_TIMEOUT" cargo test --offline --test hidden_suite -- --test-threads=4)
  fi
  read -r own_p own_f < <(count_tests "$out/test.log" 2>/dev/null || echo "0 0")
  read -r hid_p hid_f < <(count_tests "$out/hidden.log" 2>/dev/null || echo "0 0")
  grep -E '^test .* \.\.\. FAILED$' "$out/hidden.log" 2>/dev/null | sed 's/^test //; s/ \.\.\. FAILED$//' >"$out/hidden-failed.txt" || true
  deps="none"
  if [[ -f "$work/Cargo.toml" ]] && awk '/^\[(dev-)?dependencies\]/{s=1;next} /^\[/{s=0} s && NF && $1 !~ /^#/ {f=1} END{exit !f}' "$work/Cargo.toml"; then deps="DECLARED (forbidden)"; fi
  forbid="no"; grep -qs '#!\[forbid(unsafe_code)\]' "$work/src/lib.rs" && forbid="yes"
  unsafe_n=$( { grep -rhoE '\bunsafe\b' "$work/src" 2>/dev/null || true; } | wc -l)
  src_lines=$(find "$work/src" -name '*.rs' -exec cat {} + 2>/dev/null | grep -cvE '^\s*(//.*)?$' || true)
  test_files=$( { find "$work/tests" -name '*.rs' ! -name hidden_suite.rs 2>/dev/null || true; } | wc -l)
  design_words=$(wc -w <"$work/DESIGN.md" 2>/dev/null || echo 0)
  jq -n --arg L "$L" --arg fmt "$(rc_of fmt)" --arg clippy "$(rc_of clippy)" --arg build "$(rc_of build)" \
    --arg test "$(rc_of test)" --arg hidden "$(rc_of hidden)" --argjson own_p "$own_p" --argjson own_f "$own_f" \
    --argjson hid_p "$hid_p" --argjson hid_f "$hid_f" --argjson hid_total "$HIDDEN_TOTAL" --arg deps "$deps" \
    --arg forbid "$forbid" --argjson unsafe_n "$unsafe_n" --argjson src_lines "${src_lines:-0}" \
    --argjson test_files "$test_files" --argjson design_words "${design_words:-0}" \
    '{entry:$L, exit_codes:{fmt:$fmt, clippy:$clippy, build:$build, test:$test, hidden:$hidden},
      own_tests:{passed:$own_p, failed:$own_f}, hidden_tests:{passed:$hid_p, failed:$hid_f, total:$hid_total},
      dependencies:$deps, forbid_unsafe:$forbid, unsafe_keyword_count:$unsafe_n,
      src_code_lines:$src_lines, own_test_files:$test_files, design_md_words:$design_words}' >"$out/results.json"
  echo "   fmt=$(rc_of fmt) clippy=$(rc_of clippy) build=$(rc_of build) test=$(rc_of test) hidden=$hid_p/$HIDDEN_TOTAL"
done

{
  echo "# Mechanical checks"
  echo
  echo "Exit code 0 = pass. Hidden suite: $HIDDEN_TOTAL tests. Logs in checks/<entry>/."
  echo
  echo "| entry | fmt --check | clippy -D warnings | build | own tests (pass/fail) | hidden (pass/total) | deps | forbid(unsafe) | unsafe kw | src LOC | DESIGN.md words |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|"
  for f in checks/[A-Z]/results.json; do
    jq -r '"| \(.entry) | \(.exit_codes.fmt) | \(.exit_codes.clippy) | \(.exit_codes.build) | \(.own_tests.passed)/\(.own_tests.failed) (rc \(.exit_codes.test)) | \(.hidden_tests.passed)/\(.hidden_tests.total) (rc \(.exit_codes.hidden)) | \(.dependencies) | \(.forbid_unsafe) | \(.unsafe_keyword_count) | \(.src_code_lines) | \(.design_md_words) |"' "$f"
  done
  echo
  for f in checks/[A-Z]/hidden-failed.txt; do
    [[ -s "$f" ]] && { echo "Hidden failures, $(basename "$(dirname "$f")"): $(paste -sd, "$f" | sed 's/,/, /g')"; echo; }
  done
  true
} >checks/SUMMARY.md
rm -rf checks/work
cat checks/SUMMARY.md
