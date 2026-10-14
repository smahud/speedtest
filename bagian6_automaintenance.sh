#!/usr/bin/env bash
###############################################################################
# bagian6_automaintenance.sh — Penjadwalan laporan speedtest (cron).
#
#   - Memasang/memperbarui cron reporting speedtest secara IDEMPOTENT.
#   - Wrapper cron dibuat di $BASE_DIR dan memuat eksplisit:
#       * PATH=$CRON_PATH          → /usr/local/bin & /usr/sbin terlihat oleh cron
#       * path absolut CLI Ookla    → tidak bergantung pada PATH cron
#       * $SPEEDTEST_CLI_LICENSE_FLAGS → CLI Ookla MENOLAK jalan tanpa TTY bila
#         lisensi belum diterima; flag ini wajib di konteks cron (bug v8.1.0)
#       * log + rotasi              → kegagalan tidak lagi senyap (bug v8.1.0)
#
# Pemakaian:
#   bash bagian6_automaintenance.sh [data.ini]
#
# Versi: 8.1.1
###############################################################################
set -uo pipefail
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
# cron berjalan di /bin/sh → $RANDOM tidak tersedia, dan '%' bermasalah di crontab.
JITTER_MAX="${REPORT_JITTER_MIN_MAX:-50}"
case "$JITTER_MAX" in ''|*[!0-9]*) JITTER_MAX=50 ;; esac
if [ "$JITTER_MAX" -eq 0 ]; then
  JITTER_MIN=0
  JITTER_SLEEP_LINE=""
elif [ -n "${RANDOM:-}" ]; then
  JITTER_MIN=$(( RANDOM % JITTER_MAX ))
  JITTER_SLEEP_LINE="sleep ${JITTER_MIN}m"
else
  JITTER_MIN=$(( $(date +%s) % JITTER_MAX ))
  JITTER_SLEEP_LINE="sleep ${JITTER_MIN}m"
fi

# --- Wrapper script untuk cron -------------------------------------------------
CRON_WRAPPER="$BASE_DIR/cron-speedtest.sh"
CRON_WRAPPER2="$BASE_DIR/cron-speedtest5.sh"
REPORT_LOG="$BASE_DIR/report.log"
REPORT_HOURLY_ENABLED="${REPORT_HOURLY_ENABLED:-Ya}"
REPORT_FAST_ENABLED="${REPORT_FAST_ENABLED:-Ya}"
REPORT_FAST_SCHEDULE="${REPORT_FAST_SCHEDULE:-*/5 * * * *}"
REPORT_LOG_MAX_KB="${REPORT_LOG_MAX_KB:-512}"
CRON_PATH_RESOLVED="${CRON_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
CLI_FLAGS="${SPEEDTEST_CLI_LICENSE_FLAGS:---accept-license --accept-gdpr}"
SMOKE_TIMEOUT="${SPEEDTEST_SMOKE_TIMEOUT:-150}"
entries=()

# Path CLI: pakai yang terdeteksi saat instalasi; wrapper tetap punya fallback
# 'command -v' bila lokasinya berubah.
CLI_PATH="$BASE_DIR/__none__"
if [ -x "${SPEEDTEST_CLI_PATH:-/usr/local/bin/speedtest}" ]; then
  CLI_PATH="${SPEEDTEST_CLI_PATH:-/usr/local/bin/speedtest}"
elif command_exists speedtest; then
  CLI_PATH="$(command -v speedtest)"
fi

# Validasi jadwal cepat: HARUS 5 field; '%' harus di-escape untuk crontab.
case "$REPORT_FAST_SCHEDULE" in
  *%*) REPORT_FAST_SCHEDULE="$(printf '%s' "$REPORT_FAST_SCHEDULE" | sed 's/%/\\%/g')" ;;
esac
if [ "$(printf '%s' "$REPORT_FAST_SCHEDULE" | awk '{print NF}')" -ne 5 ]; then
  log_warn "REPORT_FAST_SCHEDULE tidak valid ('$REPORT_FAST_SCHEDULE') → memakai default '*/5 * * * *'."
  REPORT_FAST_SCHEDULE="*/5 * * * *"
fi

# Header bersama kedua wrapper (ditulis dalam satu sumber agar tidak menyimpang).
write_wrapper_header() {
  local dest="$1" purpose="$2"
  cat > "$dest" <<WRAPEOF
#!/bin/sh
# Wrapper cron speedtest reporting ($purpose) — dikelola otomatis bagian6.
# JANGAN diedit manual: perubahan akan ditimpa saat instalasi/self-update.
#
# PATH eksplisit: cron (Debian/Ubuntu/Alpine) hanya memberi PATH=/usr/bin:/bin,
# sehingga /usr/local/bin (CLI Ookla) & /usr/sbin (iptables dll) tidak terlihat.
PATH="$CRON_PATH_RESOLVED"
export PATH

SPEEDTEST_BIN="$CLI_PATH"
[ -x "\$SPEEDTEST_BIN" ] || SPEEDTEST_BIN="\$(command -v speedtest 2>/dev/null)"
# Flag lisensi WAJIB di konteks non-interaktif (cron tidak punya TTY).
SPEEDTEST_FLAGS="$CLI_FLAGS"
URL="$REGISTERED_URL"
LOG="$REPORT_LOG"
MAX_KB="$REPORT_LOG_MAX_KB"

log_line() { printf '%s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" >> "\$LOG" 2>/dev/null || true; }

rotate_log() {
  [ -f "\$LOG" ] || return 0
  sz="\$(wc -c < "\$LOG" 2>/dev/null | awk '{print \$1}')"
  case "\$sz" in ''|*[!0-9]*) sz=0 ;; esac
  [ "\$sz" -gt \$(( MAX_KB * 1024 )) ] && mv -f "\$LOG" "\$LOG.1" 2>/dev/null
  return 0
}
WRAPEOF
}

# --- Laporan tiap jam ---------------------------------------------------------
if [ "$REPORT_HOURLY_ENABLED" = "Ya" ]; then
  write_wrapper_header "$CRON_WRAPPER" "laporan per jam"
  cat >> "$CRON_WRAPPER" <<WRAPEOF

if [ -z "\$SPEEDTEST_BIN" ]; then
  log_line "[report] GAGAL: CLI Ookla tidak ditemukan (PATH=\$PATH, cek SPEEDTEST_CLI_PATH)."
  exit 127
fi

rotate_log
${JITTER_SLEEP_LINE}
# \$SPEEDTEST_FLAGS sengaja TANPA kutip agar terpecah menjadi beberapa argumen.
"\$SPEEDTEST_BIN" \$SPEEDTEST_FLAGS -o "\$URL" >> "\$LOG" 2>&1
rc=\$?
log_line "[report] url=\$URL rc=\$rc (hourly)"
exit \$rc
WRAPEOF
  chmod +x "$CRON_WRAPPER"
  entries+=("0 * * * * $CRON_WRAPPER")
else
  log_info "REPORT_HOURLY_ENABLED=Tidak → laporan per jam dilewati."
fi

# --- Laporan cepat (default tiap 5 menit) -------------------------------------
# Melapor ke server lokal; dibatasi CPU lewat systemd-run hanya bila systemd
# benar-benar aktif sebagai init (systemd-run gagal senyap di container).
if [ "$REPORT_FAST_ENABLED" = "Ya" ]; then
  write_wrapper_header "$CRON_WRAPPER2" "laporan cepat"
  cat >> "$CRON_WRAPPER2" <<WRAPEOF

if [ -z "\$SPEEDTEST_BIN" ]; then
  log_line "[report] GAGAL: CLI Ookla tidak ditemukan (PATH=\$PATH, cek SPEEDTEST_CLI_PATH)."
  exit 127
fi

rotate_log
if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1; then
  systemd-run --scope -p CPUQuota=10% "\$SPEEDTEST_BIN" \$SPEEDTEST_FLAGS -o "\$URL" >> "\$LOG" 2>&1
  rc=\$?
  if [ "\$rc" -eq 1 ] || [ "\$rc" -eq 127 ]; then
    # systemd-run bisa ada tetapi bus systemd tidak tersedia (container).
    "\$SPEEDTEST_BIN" \$SPEEDTEST_FLAGS -o "\$URL" >> "\$LOG" 2>&1
    rc=\$?
  fi
else
  "\$SPEEDTEST_BIN" \$SPEEDTEST_FLAGS -o "\$URL" >> "\$LOG" 2>&1
  rc=\$?
fi
log_line "[report] url=\$URL rc=\$rc (fast)"
exit \$rc
WRAPEOF
  chmod +x "$CRON_WRAPPER2"
  entries+=("$REPORT_FAST_SCHEDULE $CRON_WRAPPER2")
else
  log_info "REPORT_FAST_ENABLED=Tidak → laporan cepat ($REPORT_FAST_SCHEDULE) dilewati/dihapus."
fi

# Idempotensi ditangani cron_apply() (common_functions1.sh). Path kedua wrapper
# selalu di-purge agar jadwal yang dimatikan benar-benar hilang dari crontab.
if [ "${#entries[@]}" -gt 0 ]; then
  if cron_apply "$CRON_TAG" --purge "$CRON_WRAPPER" --purge "$CRON_WRAPPER2" --purge "speedtest -o " "${entries[@]}"; then
    log_ok "Cron reporting diperbarui (idempotent): $REGISTERED_URL"
  else
    log_warn "Gagal memasang cron reporting. Log laporan: $REPORT_LOG"
  fi
else
  if cron_apply "$CRON_TAG" --purge "$CRON_WRAPPER" --purge "$CRON_WRAPPER2" --purge "speedtest -o "; then
    log_ok "Reporting dinonaktifkan: seluruh entri laporan dibersihkan dari crontab."
  else
    log_warn "Gagal membersihkan entri cron reporting."
  fi
fi

# Ringkasan kondisi yang mudah diaudit operator.
if [ -n "$(ookla_cli_path)" ]; then
  log_info "CLI Ookla: $(ookla_cli_path)"
else
  log_warn "CLI Ookla belum terdeteksi — jalankan bagian1 dulu (laporan tidak akan jalan)."
fi
if ookla_license_accepted; then
  log_info "Lisensi Ookla sudah tersimpan ($(ookla_license_file))."
else
  log_info "Lisensi Ookla belum tersimpan — flag lisensi tetap dibawa setiap pemanggilan cron."
fi
log_ok "Bagian 6 selesai (log laporan: $REPORT_LOG, rotasi > ${REPORT_LOG_MAX_KB} KB)."
