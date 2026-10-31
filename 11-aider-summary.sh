#!/usr/bin/env bash
# Rebuild results/summary.md + summary.csv from results/*/stats.json.
# Optional: ./11-aider-summary.sh --refresh  re-reads the aider run dirs first (works mid-run).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
if [[ "${1:-}" == "--refresh" ]]; then
  for f in "$RESULTS_DIR"/*/stats.json; do
    [[ -f "$f" ]] || continue
    m="$(basename "$(dirname "$f")")"
    run_dir="$(jq -r '.aider_run_dir // empty' "$f")"
    [[ -d "$run_dir" ]] || continue
    python3 "$KIT_DIR/lib/aider_stats.py" run "$run_dir" --model "$m" --out "$RESULTS_DIR/$m" \
      --languages "$(jq -r 'if .languages == "all" then "" else .languages end' "$f")" --tries "$TRIES" \
      --meta "desc=$(jq -r .desc "$f")" --meta "edit_format=$(jq -r .edit_format "$f")" --meta "ctx=$(jq -r .ctx "$f")" \
      --meta "sampling=$(jq -r .sampling "$f")" --meta "threads=$(jq -r .threads "$f")" --meta "aider_run_dir=$run_dir" || true
  done
fi
python3 "$KIT_DIR/lib/aider_stats.py" summary "$RESULTS_DIR"
