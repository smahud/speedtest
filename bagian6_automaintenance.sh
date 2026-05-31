#!/usr/bin/env bash
###############################################################################
# bagian6_automaintenance.sh
#   - Memasang/memperbarui cron job reporting speedtest (idempotent).
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 6: Penjadwalan (crontab) Speedtest =="

REGISTERED_URL="${RegisteredSpeedtestURL:-$(ini_get RegisteredSpeedtestURL)}"
[ -n "$REGISTERED_URL" ] || die "RegisteredSpeedtestURL kosong; tidak bisa membuat cron."

if ! command_exists crontab; then
    log_warn "crontab tidak tersedia; melewati penjadwalan reporting."
    exit 0
fi

# Tag baris (baris komentar TERPISAH) untuk dedup yang aman lintas crond.
# CATATAN: jangan menaruh komentar '#' di belakang perintah cron — busybox
# crond (Alpine) tidak memperlakukannya sebagai komentar.
CRON_TAG="# speedtest-report (managed)"

# Randomisasi jeda DITENTUKAN SAAT INSTALL (bukan saat cron jalan) agar portabel.
# cron berjalan di /bin/sh -> $RANDOM tidak tersedia, dan '%' bermasalah di crontab.
# Pilih offset menit 0-50 sekali di sini sehingga tiap server berbeda jadwalnya.
if [ -n "${RANDOM:-}" ]; then
    JITTER_MIN=$(( RANDOM % 50 ))
else
    JITTER_MIN=$(( $(date +%s) % 50 ))
fi
CRON1="0 * * * * sleep ${JITTER_MIN}m && speedtest -o $REGISTERED_URL"
# systemd-run hanya tersedia di systemd; gunakan varian sederhana bila tidak ada.
# CPUQuota memakai '%': di crontab harus di-escape menjadi '\%'.
if command_exists systemd-run; then
    CRON2="*/5 * * * * systemd-run --scope -p CPUQuota=10\\% speedtest -o $REGISTERED_URL"
else
    CRON2="*/5 * * * * speedtest -o $REGISTERED_URL"
fi

tmp_cron="$TMP_DIR/crontab.report.tmp"
# Buang baris speedtest report lama + tag lama, lalu tambahkan yang baru.
crontab -l 2>/dev/null | grep -v 'speedtest -o ' | grep -vF "$CRON_TAG" > "$tmp_cron" || true
{
    echo "$CRON_TAG"
    echo "$CRON1"
    echo "$CRON2"
} >> "$tmp_cron"
crontab "$tmp_cron" 2>/dev/null || log_warn "Gagal memasang cron reporting."
rm -f "$tmp_cron"

log_ok "Cron reporting diperbarui untuk URL: $REGISTERED_URL"
log_ok "Bagian 6 selesai."
