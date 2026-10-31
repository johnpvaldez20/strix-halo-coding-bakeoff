#!/usr/bin/env bash
# Runs INSIDE the aider-benchmark container (as root). Called by 10-aider-bench.sh.
# Args: RUN_NAME then the benchmark.py arguments.
set -uo pipefail
run_name="$1"; shift
cd /aider || exit 1
shopt -s nullglob
for d in /benchmarks/*--"$run_name"; do
  python3 /kit/purge_exceptions.py "$d"
done
python3 ./benchmark/benchmark.py "$run_name" "$@"
rc=$?
# Hand results back to the host user so they can be read and deleted without sudo.
if [[ -n "${HOST_UID:-}" ]]; then
  for d in /benchmarks/*--"$run_name"; do chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$d"; done
fi
exit "$rc"
