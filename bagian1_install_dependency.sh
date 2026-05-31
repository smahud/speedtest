#!/usr/bin/env bash
###############################################################################
# bagian0.sh — Banner pembuka.
# Bisa dijalankan mandiri: ./bagian0.sh [/path/ke/data.ini]
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

# Bila dijalankan mandiri, tetap bisa resolve path (opsional).
if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"
    init_paths
fi

print_hash 50
log_info "Menjalankan Auto Install Speedtest OoklaServer (mode non-interaktif)"
print_hash 50
