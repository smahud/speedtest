#!/usr/bin/env bash
###############################################################################
# bagian8_cek_konfigurasi.sh
# - Membuat service auto-start (Systemd/OpenRC/Cron Fallback).
# - Menambah cron auto-restart harian.
# - Verifikasi status runtime (Process + Port Check).
# Versi: 7.0 (Fix: tambah set -e)
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
  resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi
detect_init

log_info "== Bagian 8: Konfigurasi Service & Verifikasi Akhir =="

CRON_PATH_RESOLVED="${CRON_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
REPORT_LOG="$BASE_DIR/report.log"

# Generate management tool (speedtestctl.sh) di BASE_DIR.
generate_ctl() {
  cat > "$BASE_DIR/speedtestctl.sh" <<'CTLEOF'
#!/usr/bin/env bash
# speedtestctl.sh — Management tool untuk OoklaServer + laporan speedtest.
# Dibaca dari state file, jadi bisa dijalankan dari mana saja.

# PATH eksplisit: tool ini bisa dipanggil dari cron/otomasi dengan PATH minimal.
PATH="__CRON_PATH__"
export PATH

STATE_FILE="__STATE_FILE__"
OOKLA_SCRIPT="__OOKLA_SCRIPT__"
BASE_DIR="__BASE_DIR__"
OOKLA_BIN="__OOKLA_BIN__"
INIT_SYSTEM="__INIT_SYSTEM__"
REPORT_LOG="__REPORT_LOG__"
OOKLA_PROPERTIES="__OOKLA_PROPERTIES__"

[ -f "$STATE_FILE" ] || { echo "State file tidak ditemukan: $STATE_FILE. Jalankan instalasi dulu."; exit 1; }

# Port yang dibuka OoklaServer (dari properties; fallback 8080).
tcp_ports() {
  local p
  p="$(grep -E '^[[:space:]]*OoklaServer[.]tcpPorts[[:space:]]*=' "$OOKLA_PROPERTIES" 2>/dev/null \
       | tail -n1 | sed 's/.*=[[:space:]]*//' | tr ',' ' ')"
  [ -n "$p" ] || p="8080"
  printf '%s' "$p"
}

usage() {
  echo "Usage: $0 {start|stop|restart|status|report|logs|report-log|uninstall}"
  echo "  start       - Start OoklaServer"
  echo "  stop        - Stop OoklaServer"
  echo "  restart     - Restart OoklaServer"
  echo "  status      - Cek status OoklaServer"
  echo "  report      - Jalankan 1x laporan speedtest sekarang (tanpa tunggu cron)"
  echo "  logs        - Tampilkan log instalasi"
  echo "  report-log  - Tampilkan 50 baris terakhir log laporan"
  echo "  nperf-status  - Status nPerf Server (layanan speedtest kedua)"
  echo "  nperf-restart - Restart service nPerf"
  echo "  nperf-logs    - Tampilkan log instalasi nPerf"
  echo "  verify        - Verifikasi integritas semua file (checksums.sha256)"
  echo "  uninstall   - Hapus service OoklaServer"
}

case "${1:-}" in
  start)
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" start )
    ;;
  stop)
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" stop )
    ;;
  restart)
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart )
    ;;
  logs)
    if [ -f "$BASE_DIR/install.log" ]; then tail -50 "$BASE_DIR/install.log"; else echo "Log tidak ditemukan."; fi
    ;;
  report-log)
    if [ -f "$REPORT_LOG" ]; then tail -50 "$REPORT_LOG"; else echo "Log laporan belum ada: $REPORT_LOG"; fi
    ;;
  report)
    # Jalankan wrapper laporan per jam SEKARANG (tanpa menunggu jadwal cron).
    if [ -x "$BASE_DIR/cron-speedtest.sh" ]; then
      "$BASE_DIR/cron-speedtest.sh"
      echo "Selesai. Lihat hasil: $0 report-log"
    else
      echo "Wrapper laporan tidak ada ($BASE_DIR/cron-speedtest.sh)."
      echo "Jalankan dulu: bash $BASE_DIR/bagian6_automaintenance.sh"
      exit 1
    fi
    ;;
  status)
    running=0
    if command -v pgrep >/dev/null 2>&1 && pgrep -x OoklaServer >/dev/null 2>&1; then
      running=1
    else
      for port in $(tcp_ports); do
        if command -v ss >/dev/null 2>&1; then
          ss -tln 2>/dev/null | grep -q ":$port " && { running=1; break; }
        elif command -v netstat >/dev/null 2>&1; then
          netstat -tln 2>/dev/null | grep -q ":$port " && { running=1; break; }
        fi
      done
    fi
    if [ "$running" -eq 1 ]; then
      echo "OoklaServer: RUNNING (BASE_DIR=$BASE_DIR, port: $(tcp_ports))"
    else
      echo "OoklaServer: STOPPED"
      exit 1
    fi
    ;;
  verify)
    # Verifikasi integritas file terkelola tanpa menyentuh sistem.
    if [ -f "$BASE_DIR/install.sh" ]; then
      bash "$BASE_DIR/install.sh" --verify-only
    else
      echo "install.sh tidak ada di $BASE_DIR."
      exit 1
    fi
    ;;
  nperf-status|nperf-restart|nperf-logs)
    if [ ! -x "$BASE_DIR/bagian12_nperf_server.sh" ]; then
      echo "Modul nPerf tidak ada ($BASE_DIR/bagian12_nperf_server.sh)."
      exit 1
    fi
    case "$1" in
      nperf-status)  "$BASE_DIR/bagian12_nperf_server.sh" --status ;;
      nperf-restart)
        if command -v systemctl >/dev/null 2>&1; then
          systemctl restart nperf-server && echo "nPerf direstart."
        elif [ -x /etc/init.d/nperf-server ]; then
          /etc/init.d/nperf-server restart && echo "nPerf direstart (init.d)."
        else
          echo "Service nPerf tidak ditemukan (systemd & init.d tidak ada)."
          echo "Pasang/tegakkan ulang: bash $BASE_DIR/bagian12_nperf_server.sh"
          exit 1
        fi
        ;;
      nperf-logs)
        if [ -f "$BASE_DIR/nperf/install-nperf.log" ]; then
          tail -50 "$BASE_DIR/nperf/install-nperf.log"
        else
          echo "Log nPerf belum ada: $BASE_DIR/nperf/install-nperf.log"
        fi
        ;;
    esac
    ;;
  uninstall)
    echo "Menghapus service OoklaServer..."
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" stop ) >/dev/null 2>&1 || true
    if [ "$INIT_SYSTEM" = "systemd" ]; then
      systemctl disable --now ooklaserver.service >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/ooklaserver.service
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
      rc-service ooklaserver stop >/dev/null 2>&1 || true
      rc-update del ooklaserver default >/dev/null 2>&1 || true
      rm -f /etc/init.d/ooklaserver
    fi
    crontab -l 2>/dev/null | grep -v 'OoklaServer' | crontab - 2>/dev/null || true
    echo "Selesai."
    ;;
  *) usage; exit 1 ;;
esac
CTLEOF

  # Substitusi placeholder
  sed -i "s|__STATE_FILE__|$(sed_escape_repl "${STATE_FILE}")|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__OOKLA_SCRIPT__|$(sed_escape_repl "${OOKLA_SCRIPT}")|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__BASE_DIR__|$(sed_escape_repl "${BASE_DIR}")|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__OOKLA_BIN__|$(sed_escape_repl "${OOKLA_BIN}")|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__INIT_SYSTEM__|$(sed_escape_repl "${INIT_SYSTEM}")|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__CRON_PATH__|$(sed_escape_repl "${CRON_PATH_RESOLVED}")|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__REPORT_LOG__|$(sed_escape_repl "${REPORT_LOG}")|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__OOKLA_PROPERTIES__|$(sed_escape_repl "${OOKLA_PROPERTIES}")|" "$BASE_DIR/speedtestctl.sh"
  chmod a+x "$BASE_DIR/speedtestctl.sh"
  log_ok "Tool management siap: $BASE_DIR/speedtestctl.sh (start|stop|restart|status|report|logs|report-log|nperf-status|nperf-restart|nperf-logs)"
}
generate_ctl

# --- Buat service auto-start --------------------------------------------------
setup_systemd() {
  log_info "Instalasi service Systemd..."
  cat > /etc/systemd/system/ooklaserver.service <<SYSTEMDEOF
[Unit]
Description=Ookla Speedtest Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=$BASE_DIR
ExecStart=$OOKLA_SCRIPT start
ExecStop=$OOKLA_SCRIPT stop
ExecReload=$OOKLA_SCRIPT restart
PIDFile=$OOKLA_PIDFILE
Restart=on-failure
RestartSec=30
Environment=SPEEDTEST_SCRIPT_DIR=$BASE_DIR

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable ooklaserver.service >/dev/null 2>&1 || true
  systemctl restart ooklaserver.service >/dev/null 2>&1 || ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart )
  log_ok "Service Systemd aktif."
}

setup_openrc() {
  log_info "Instalasi service OpenRC..."
  cat > /etc/init.d/ooklaserver <<OPENRCEOF
#!/sbin/openrc-run
description="Ookla Speedtest Server"
command="$OOKLA_BIN"
command_args="--daemon --pidfile=$OOKLA_PIDFILE"
pidfile="$OOKLA_PIDFILE"
directory="$BASE_DIR"

depend() {
  need net
  after firewall
}

start() {
  ebegin "Starting OoklaServer"
  ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" start ) >/dev/null 2>&1
  eend \$?
}

stop() {
  ebegin "Stopping OoklaServer"
  ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" stop ) >/dev/null 2>&1
  eend \$?
}
OPENRCEOF
  chmod +x /etc/init.d/ooklaserver
  rc-update add ooklaserver default >/dev/null 2>&1 || true
  rc-service ooklaserver restart >/dev/null 2>&1 || ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart )
  log_ok "Service OpenRC aktif."
}

setup_fallback() {
  log_warn "Init system tidak terdeteksi. Menggunakan Cron @reboot."
  if ! command_exists crontab; then
    log_warn "crontab tidak tersedia — fallback @reboot dilewati."
    return 0
  fi
  if cron_apply "# speedtest-boot-fallback (managed)" \
       "@reboot cd $BASE_DIR && $OOKLA_SCRIPT start"; then
    log_ok "Cron @reboot fallback terpasang (idempotent)."
  else
    log_warn "Gagal memasang cron @reboot fallback."
  fi
}

case "$INIT_SYSTEM" in
  systemd) setup_systemd ;;
  openrc)   setup_openrc ;;
  *)        setup_fallback ;;
esac

# --- Cron Daily Restart ---
if ! command_exists crontab; then
  log_warn "crontab tidak tersedia — daily restart dilewati."
else
  if cron_apply "# ookla-daily-restart" \
       "0 0 * * * cd $BASE_DIR && $OOKLA_SCRIPT restart"; then
    log_ok "Cron daily restart aktif (idempotent)."
  else
    log_warn "Gagal memasang cron daily restart."
  fi
fi

# --- Konfigurasi Firewall ---
open_ports

# --- Verifikasi Status ---
log_info "Verifikasi runtime server..."
sleep 10 # Waktu booting RAM rendah

is_running() {
  local port
  if command -v pgrep >/dev/null 2>&1 && pgrep -x "OoklaServer" >/dev/null 2>&1; then return 0; fi
  for port in $(ookla_props_ports "$OOKLA_PROPERTIES" || printf '8080'); do
    if command -v netstat >/dev/null 2>&1; then
      netstat -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v ss >/dev/null 2>&1; then
      ss -tuln 2>/dev/null | grep -q ":$port " && return 0
    fi
  done
  return 1
}

if is_running; then
  log_ok "OoklaServer BERJALAN NORMAL."
else
  log_warn "Server belum merespon. Mencoba restart paksa..."
  ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || true
  sleep 10
  if is_running; then
    log_ok "OoklaServer BERJALAN."
  else
    log_error "Gagal start otomatis. Periksa log: $LOG_FILE"
  fi
fi

print_hash 50
log_ok "PROSES SELESAI."
log_info "BASE_DIR : $BASE_DIR"
log_info "Control  : ./speedtestctl.sh {status|restart|logs}"
print_hash 50
