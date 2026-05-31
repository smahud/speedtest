#!/usr/bin/env bash
###############################################################################
# bagian6_automaintenance.sh
# - Memasang/memperbarui cron job reporting speedtest (idempotent).
# Versi: 7.0 (Fix: escape % untuk busybox crond + random seed)
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

# --- Buat wrapper script untuk cron agar lebih portabel ---
CRON_WRAPPER="$BASE_DIR/cron-speedtest.sh"
cat > "$CRON_WRAPPER" <<CRONEOF
#!/bin/sh
# Wrapper script untuk cron speedtest reporting
# Dikelola oleh bagian6_automaintenance.sh
sleep ${JITTER_MIN}m
speedtest -o "$REGISTERED_URL"
CRONEOF
chmod +x "$CRON_WRAPPER"

CRON_WRAPPER2="$BASE_DIR/cron-speedtest5.sh"
cat > "$CRON_WRAPPER2" <<CRONEOF
#!/bin/sh
# Wrapper script untuk cron speedtest reporting (setiap 5 menit)
# Dikelola oleh bagian6_automaintenance.sh
if command -v systemd-run >/dev/null 2>&1; then
  systemd-run --scope -p CPUQuota=10% speedtest -o "$REGISTERED_URL"
else
  speedtest -o "$REGISTERED_URL"
fi
CRONEOF
chmod +x "$CRON_WRAPPER2"

CRON1="0 * * * * $CRON_WRAPPER"
CRON2="*/5 * * * * $CRON_WRAPPER2"

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
