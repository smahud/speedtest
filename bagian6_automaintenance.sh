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
CRON_WRAPPER2="$BASE_DIR/cron-speedtest5.sh"
REPORT_HOURLY_ENABLED="${REPORT_HOURLY_ENABLED:-Ya}"
REPORT_FAST_ENABLED="${REPORT_FAST_ENABLED:-Ya}"
REPORT_FAST_SCHEDULE="${REPORT_FAST_SCHEDULE:-*/5 * * * *}"

entries=()

# --- Laporan tiap jam ---
if [ "$REPORT_HOURLY_ENABLED" = "Ya" ]; then
  cat > "$CRON_WRAPPER" <<CRONEOF
#!/bin/sh
# Wrapper script untuk cron speedtest reporting (dikelola bagian6_automaintenance.sh)
sleep ${JITTER_MIN}m
speedtest -o "$REGISTERED_URL"
CRONEOF
  chmod +x "$CRON_WRAPPER"
  entries+=("0 * * * * $CRON_WRAPPER")
else
  log_info "REPORT_HOURLY_ENABLED=Tidak → laporan per jam dilewati."
fi

# --- Laporan cepat (default tiap 5 menit) ---
# Dibatasi CPU lewat systemd-run bila tersedia supaya tidak mengganggu
# OoklaServer di server kecil.
if [ "$REPORT_FAST_ENABLED" = "Ya" ]; then
  cat > "$CRON_WRAPPER2" <<CRONEOF
#!/bin/sh
# Wrapper script untuk cron speedtest reporting cepat (dikelola bagian6_automaintenance.sh)
if command -v systemd-run >/dev/null 2>&1; then
  systemd-run --scope -p CPUQuota=10% speedtest -o "$REGISTERED_URL"
else
  speedtest -o "$REGISTERED_URL"
fi
CRONEOF
  chmod +x "$CRON_WRAPPER2"
  entries+=("$REPORT_FAST_SCHEDULE $CRON_WRAPPER2")
else
  log_info "REPORT_FAST_ENABLED=Tidak → laporan cepat ($REPORT_FAST_SCHEDULE) dilewati/dihapus."
fi

# Idempotensi ditangani cron_apply() (common_functions1.sh). Path kedua wrapper
# selalu di-purge agar jadwal yang dimatikan benar-benar hilang dari crontab.
if [ "${#entries[@]}" -gt 0 ]; then
  if cron_apply "$CRON_TAG" --purge "$CRON_WRAPPER" --purge "$CRON_WRAPPER2" --purge "speedtest -o " "${entries[@]}"; then
    log_ok "Cron reporting diperbarui (idempotent, tanpa duplikasi): $REGISTERED_URL"
  else
    log_warn "Gagal memasang cron reporting."
  fi
else
  if cron_apply "$CRON_TAG" --purge "$CRON_WRAPPER" --purge "$CRON_WRAPPER2" --purge "speedtest -o "; then
    log_ok "Reporting dinonaktifkan: seluruh entri laporan dibersihkan dari crontab."
  else
    log_warn "Gagal membersihkan entri cron reporting."
  fi
fi

log_ok "Bagian 6 selesai."
