#!/usr/bin/env bash
# One-time setup for Part 1: clone aider + polyglot-benchmark, build the docker image.
# Safe to re-run. Does not touch any model or llama-server.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

"${DOCKER_CMD[@]}" info >/dev/null 2>&1 || die "docker not reachable; run ./00-check.sh"
mkdir -p "$WORK_DIR"

if [[ ! -d "$AIDER_DIR/.git" ]]; then
  log "cloning Aider-AI/aider into $AIDER_DIR"
  git clone https://github.com/Aider-AI/aider.git "$AIDER_DIR"
fi
git -C "$AIDER_DIR" fetch --quiet origin
git -C "$AIDER_DIR" checkout --quiet "$AIDER_REF"
if [[ "$AIDER_REF" == "main" ]]; then git -C "$AIDER_DIR" pull --quiet --ff-only origin main; fi
AIDER_COMMIT="$(git -C "$AIDER_DIR" rev-parse --short HEAD)"
log "aider at $AIDER_COMMIT"

mkdir -p "$AIDER_DIR/tmp.benchmarks"
PG="$AIDER_DIR/tmp.benchmarks/polyglot-benchmark"
if [[ ! -d "$PG/.git" ]]; then
  log "cloning Aider-AI/polyglot-benchmark"
  git clone https://github.com/Aider-AI/polyglot-benchmark "$PG"
fi
PG_COMMIT="$(git -C "$PG" rev-parse --short HEAD)"
count=$(find "$PG" -mindepth 4 -maxdepth 4 -path '*/exercises/practice/*' -type d | wc -l)
log "polyglot-benchmark at $PG_COMMIT with $count exercises"

log "building docker image $AIDER_IMAGE (several GB, 10-30 min the first time)"
(cd "$AIDER_DIR" && "${DOCKER_CMD[@]}" build --file benchmark/Dockerfile -t "$AIDER_IMAGE" .)

{
  echo "aider_commit=$AIDER_COMMIT"
  echo "polyglot_commit=$PG_COMMIT"
  echo "exercises=$count"
  echo "image_id=$("${DOCKER_CMD[@]}" image inspect -f '{{.Id}}' "$AIDER_IMAGE")"
  echo "date=$(date -Is)"
} >"$RESULTS_DIR/aider-setup.txt"
log "setup done; versions in results/aider-setup.txt"
