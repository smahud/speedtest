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

# Generate management tool (speedtestctl.sh) di BASE_DIR.
generate_ctl() {
  cat > "$BASE_DIR/speedtestctl.sh" <<'CTLEOF'
#!/usr/bin/env bash
# speedtestctl.sh — Management tool untuk OoklaServer
# Dibaca dari state file, jadi bisa dijalankan dari mana saja.

STATE_FILE="__STATE_FILE__"
OOKLA_SCRIPT="__OOKLA_SCRIPT__"
BASE_DIR="__BASE_DIR__"
OOKLA_BIN="__OOKLA_BIN__"
INIT_SYSTEM="__INIT_SYSTEM__"

[ -f "$STATE_FILE" ] || { echo "State file tidak ditemukan: $STATE_FILE. Jalankan instalasi dulu."; exit 1; }

usage() {
  echo "Usage: $0 {start|stop|restart|status|logs|uninstall}"
  echo "  start      - Start OoklaServer"
  echo "  stop       - Stop OoklaServer"
  echo "  restart    - Restart OoklaServer"
  echo "  status     - Cek status OoklaServer"
  echo "  logs       - Tampilkan log instalasi"
  echo "  uninstall  - Hapus service OoklaServer"
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
    [ -f "$BASE_DIR/install.log" ] && tail -50 "$BASE_DIR/install.log" || echo "Log tidak ditemukan."
    ;;
  status)
    if pgrep -x OoklaServer >/dev/null 2>&1; then
      echo "OoklaServer: RUNNING (BASE_DIR=$BASE_DIR)"
    else
      echo "OoklaServer: STOPPED"
    fi
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
  sed -i "s|__STATE_FILE__|$STATE_FILE|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__OOKLA_SCRIPT__|$OOKLA_SCRIPT|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__BASE_DIR__|$BASE_DIR|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__OOKLA_BIN__|$OOKLA_BIN|" "$BASE_DIR/speedtestctl.sh"
  sed -i "s|__INIT_SYSTEM__|$INIT_SYSTEM|" "$BASE_DIR/speedtestctl.sh"
  chmod a+x "$BASE_DIR/speedtestctl.sh"
  log_ok "Tool management siap: $BASE_DIR/speedtestctl.sh"
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
  (crontab -l 2>/dev/null | grep -v "$OOKLA_SCRIPT"; echo "@reboot cd $BASE_DIR && $OOKLA_SCRIPT start") | crontab -
}

case "$INIT_SYSTEM" in
  systemd) setup_systemd ;;
  openrc)   setup_openrc ;;
  *)        setup_fallback ;;
esac

# --- Cron Daily Restart ---
CRON_TAG="# ookla-daily-restart"
(crontab -l 2>/dev/null | grep -v "$CRON_TAG" | grep -v "$OOKLA_SCRIPT restart"; echo "$CRON_TAG"; echo "0 0 * * * cd $BASE_DIR && $OOKLA_SCRIPT restart") | crontab - 2>/dev/null
log_ok "Cron daily restart aktif."

# --- Konfigurasi Firewall ---
open_ports

# --- Verifikasi Status ---
log_info "Verifikasi runtime server..."
sleep 10 # Waktu booting RAM rendah

is_running() {
  if pgrep -x "OoklaServer" >/dev/null 2>&1; then return 0; fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | grep -q ":8080 " && return 0
  elif command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -q ":8080 " && return 0
  fi
  return 1
}

if is_running; then
  log_ok "OoklaServer BERJALAN NORMAL."
else
  log_warn "Server belum merespon. Mencoba restart paksa..."
  ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || true
  sleep 10
  is_running && log_ok "OoklaServer BERJALAN." || log_error "Gagal start otomatis. Periksa log: $LOG_FILE"
fi

print_hash 50
log_ok "PROSES SELESAI."
log_info "BASE_DIR : $BASE_DIR"
log_info "Control  : ./speedtestctl.sh {status|restart|logs}"
print_hash 50
