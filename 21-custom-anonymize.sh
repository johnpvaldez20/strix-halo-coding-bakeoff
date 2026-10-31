#!/usr/bin/env bash
# Part 2 step 2: shuffle the extracted projects into results/custom-blind/A, B, C.
# The letter -> model mapping is written to results/custom-mapping.json, outside the blind folder.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
select_models "$@"
python3 "$KIT_DIR/lib/anonymize.py" "$KIT_DIR" "${SELECTED_MODELS[@]}"
log "Next: ./22-custom-check.sh"
