#!/usr/bin/env bash
# Part 2 step 3: fmt / clippy / build / own tests / hidden tests for every blind entry.
#   ./22-custom-check.sh            docker sandbox, no network (default)
#   ./22-custom-check.sh --native   host cargo (runs model-written code on this machine)
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
blind="$RESULTS_DIR/custom-blind"
[[ -x "$blind/run-checks.sh" ]] || die "run ./21-custom-anonymize.sh first"
CHECKS_IMAGE="$CHECKS_IMAGE" DOCKER_CMD_OVERRIDE="${DOCKER_CMD[*]}" "$blind/run-checks.sh" "$@"
log "Checks written to results/custom-blind/checks/SUMMARY.md. Next: give the judge results/custom-blind (see README)."
