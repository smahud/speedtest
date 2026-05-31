#!/usr/bin/env bash
###############################################################################
# bagian8_cek_konfigurasi.sh
#   - Membuat service auto-start sesuai init system (systemd/openrc/fallback).
#   - Menambah cron auto-restart harian.
#   - Memeriksa status OoklaServer.
#   - Semua path mengikuti $BASE_DIR (TIDAK ada /root/ hardcoded).
###############################################################################
set -uo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi
detect_init

log_info "== Bagian 8: Service Auto-Start & Verifikasi =="

# Generate management tool (speedtestctl.sh) di BASE_DIR.
generate_ctl() {
    cat > "$BASE_DIR/speedtestctl.sh" <<EOF
#!/usr/bin/env bash
# speedtestctl.sh — management OoklaServer (auto-generated)
# Bisa dijalankan dari direktori mana pun.
set -euo pipefail
STATE_FILE="$STATE_FILE"
[ -f "\$STATE_FILE" ] || { echo "State instalasi tidak ditemukan: \$STATE_FILE"; exit 1; }
# shellcheck source=/dev/null
. "\$STATE_FILE"

usage() { echo "Usage: \$0 {start|stop|restart|status|uninstall}"; }

cmd="\${1:-status}"
case "\$cmd" in
    start)   ( cd "\$BASE_DIR" && "\$OOKLA_SCRIPT" start ) ;;
    stop)    ( cd "\$BASE_DIR" && "\$OOKLA_SCRIPT" stop ) ;;
    restart) ( cd "\$BASE_DIR" && "\$OOKLA_SCRIPT" restart ) ;;
    status)
        if pgrep -x OoklaServer >/dev/null 2>&1; then
            echo "OoklaServer: RUNNING (BASE_DIR=\$BASE_DIR, domain=\$DOMAIN)"
        else
            echo "OoklaServer: STOPPED (BASE_DIR=\$BASE_DIR)"
        fi
        ;;
    uninstall)
        echo "Menghentikan & menghapus service OoklaServer..."
        ( cd "\$BASE_DIR" && "\$OOKLA_SCRIPT" stop ) >/dev/null 2>&1 || true
        pkill -f "\$OOKLA_BIN" 2>/dev/null || true
        if [ "\$INIT_SYSTEM" = "systemd" ]; then
            systemctl disable --now ooklaserver.service >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/ooklaserver.service
            systemctl daemon-reload >/dev/null 2>&1 || true
        elif [ "\$INIT_SYSTEM" = "openrc" ]; then
            rc-service ooklaserver stop >/dev/null 2>&1 || true
            rc-update del ooklaserver default >/dev/null 2>&1 || true
            rm -f /etc/init.d/ooklaserver
        fi
        crontab -l 2>/dev/null | grep -v 'OoklaServer' | grep -v 'speedtest -o ' | crontab - 2>/dev/null || true
        echo "Service & cron dihapus. File di \$BASE_DIR tidak dihapus (hapus manual bila perlu)."
        ;;
    *) usage; exit 1 ;;
esac
EOF
    chmod a+x "$BASE_DIR/speedtestctl.sh"
    log_ok "Management tool dibuat: $BASE_DIR/speedtestctl.sh"
}
generate_ctl

# --- Buat service auto-start sesuai init system -------------------------------
setup_systemd() {
    log_info "Membuat service systemd ooklaserver..."
    cat > /etc/systemd/system/ooklaserver.service <<EOF
[Unit]
Description=Ookla Speedtest Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=$BASE_DIR
ExecStart=$OOKLA_SCRIPT start
ExecStop=$OOKLA_SCRIPT stop
PIDFile=$OOKLA_PIDFILE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ooklaserver.service >/dev/null 2>&1 || true
    systemctl restart ooklaserver.service >/dev/null 2>&1 || \
        ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || true
    log_ok "Service systemd ooklaserver aktif."
}

setup_openrc() {
    log_info "Membuat service OpenRC ooklaserver..."
    if ! command_exists crond; then
        pkg_install cronie >/dev/null 2>&1 || true
    fi
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true

    # Biner OoklaServer melakukan self-daemonize & menulis pidfile sendiri.
    # Karena itu JANGAN pakai command_background (akan double-daemonize &
    # membuat pid kacau). Gunakan start()/stop() yang memanggil ooklaserver.sh
    # (konsisten dengan systemd & management tool).
    cat > /etc/init.d/ooklaserver <<EOF
#!/sbin/openrc-run
name="OoklaServer"
description="Ookla Speedtest Server"
pidfile="$OOKLA_PIDFILE"

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

status() {
    if [ -f "$OOKLA_PIDFILE" ] && kill -0 "\$(cat "$OOKLA_PIDFILE" 2>/dev/null)" 2>/dev/null; then
        einfo "OoklaServer is running"
        return 0
    fi
    einfo "OoklaServer is stopped"
    return 1
}
EOF
    chmod +x /etc/init.d/ooklaserver
    rc-update add ooklaserver default >/dev/null 2>&1 || true
    rc-service ooklaserver restart >/dev/null 2>&1 || rc-service ooklaserver start >/dev/null 2>&1 || \
        ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || true
    log_ok "Service OpenRC ooklaserver aktif."
}

setup_fallback() {
    log_warn "Init system tidak tersedia. Memakai fallback: cron @reboot + start manual."
    if command_exists crontab; then
        local tmp_cron="$TMP_DIR/crontab.reboot.tmp"
        crontab -l 2>/dev/null | grep -vF "@reboot cd $BASE_DIR" > "$tmp_cron" || true
        echo "@reboot cd $BASE_DIR && $OOKLA_SCRIPT start" >> "$tmp_cron"
        crontab "$tmp_cron" 2>/dev/null || true
        rm -f "$tmp_cron"
    fi
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || true
}

case "$INIT_SYSTEM" in
    systemd) setup_systemd ;;
    openrc)  setup_openrc ;;
    *)       setup_fallback ;;
esac

# --- Cron auto-restart harian (idempotent, TANPA merusak urutan crontab) ------
# Gunakan tag unik untuk dedup hanya baris milik kita; baris lain dipertahankan.
if command_exists crontab; then
    CRON_TAG="# ookla-daily-restart (managed)"
    tmp_cron="$TMP_DIR/crontab.restart.tmp"
    # Buang baris lama milik kita (tag DAN pola restart kita).
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | grep -vF "$OOKLA_SCRIPT restart" > "$tmp_cron" || true
    # Tag sebagai baris komentar TERPISAH (aman untuk busybox crond di Alpine).
    {
        echo "$CRON_TAG"
        echo "0 0 * * * cd $BASE_DIR && $OOKLA_SCRIPT restart"
    } >> "$tmp_cron"
    crontab "$tmp_cron" 2>/dev/null || log_warn "Gagal memasang cron auto-restart."
    rm -f "$tmp_cron"
    log_ok "Cron auto-restart harian dipasang."
fi

# --- Verifikasi status --------------------------------------------------------
log_info "Memeriksa status OoklaServer..."
sleep 2
if pgrep -x "OoklaServer" >/dev/null 2>&1; then
    log_ok "OoklaServer BERJALAN."
    # Deteksi IP publik: coba IPv4 dulu, lalu IPv6 (host IPv6-only didukung).
    public_ip="$(curl -4 -s --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
    [ -n "$public_ip" ] || public_ip="$(curl -6 -s --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
    if [ -n "$public_ip" ]; then
        log_info "IP publik terdeteksi: $public_ip"
        if curl -s --max-time 10 "http://$public_ip:8080" 2>/dev/null | grep -qi "OoklaServer"; then
            log_ok "OoklaServer dapat diakses di $public_ip:8080."
        else
            log_warn "OoklaServer berjalan; port 8080 belum terverifikasi dari luar (normal jika di balik firewall/NAT)."
        fi
    else
        log_info "IP publik tidak terdeteksi (lewati verifikasi eksternal)."
    fi
else
    log_warn "OoklaServer belum terdeteksi berjalan. Mencoba start ulang..."
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || true
    sleep 2
    pgrep -x "OoklaServer" >/dev/null 2>&1 && log_ok "OoklaServer berjalan setelah restart." \
        || log_error "OoklaServer masih belum berjalan. Cek log: $LOG_FILE"
fi

print_hash 50
log_ok "Instalasi OoklaServer selesai!"
log_info "BASE_DIR        : $BASE_DIR"
log_info "Properties      : $OOKLA_PROPERTIES"
log_info "Management tool : $BASE_DIR/speedtestctl.sh"
print_hash 50
