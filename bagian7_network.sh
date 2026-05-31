#!/usr/bin/env bash
###############################################################################
# bagian7_network.sh — ZeroTier Exit Node + Moon Updater
# Versi: 4.0 (path-aware, non-interaktif, idempotent)
#
# Catatan path:
#   - Script sistem (zt-exitnode, zt-moon-updater) memang dipasang di
#     /usr/local/bin & /etc (lokasi sistem yang benar, BUKAN /root).
#   - Log default mengikuti /var/log, namun bila BASE_DIR tersedia kita
#     mencatat ringkasan tambahan ke $LOG_FILE.
###############################################################################
set -uo pipefail

SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR

# Source common_functions1.sh BILA tersedia. Saat dipanggil systemd dengan
# '-postboot' dari /usr/local/bin, common mungkin tidak ada di situ -> kita
# sediakan fallback minimal agar service boot TIDAK crash (fix bug boot).
if [ -f "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh" ]; then
    # shellcheck source=common_functions1.sh
    . "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"
elif [ -f /usr/local/lib/speedtest/common_functions1.sh ]; then
    # shellcheck source=/dev/null
    . /usr/local/lib/speedtest/common_functions1.sh
fi

# Fallback definisi minimal bila common belum ter-source (mode -postboot).
if ! command -v log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO] %s\n' "$1"; }
    log_ok()    { printf '[OK] %s\n' "$1"; }
    log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
    log_error() { printf '[ERROR] %s\n' "$1" >&2; }
    die()       { log_error "$1"; exit "${2:-1}"; }
    command_exists() { command -v "$1" >/dev/null 2>&1; }
fi
if ! command -v detect_os >/dev/null 2>&1; then
    detect_os() {
        OS_FAMILY="unknown"; PKG_INSTALL=""; PKG_UPDATE=""
        if command -v apt-get >/dev/null 2>&1; then
            PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"; PKG_UPDATE="apt-get update -y"; OS_FAMILY="debian"
        elif command -v dnf >/dev/null 2>&1; then
            PKG_INSTALL="dnf install -y"; PKG_UPDATE="dnf makecache -y"; OS_FAMILY="rhel"
        elif command -v yum >/dev/null 2>&1; then
            PKG_INSTALL="yum install -y"; PKG_UPDATE="yum makecache -y"; OS_FAMILY="rhel"
        elif command -v apk >/dev/null 2>&1; then
            PKG_INSTALL="apk add --no-cache"; PKG_UPDATE="apk update"; OS_FAMILY="alpine"
        fi
    }
    pkg_install() { eval "$PKG_INSTALL $*"; }
    pkg_update()  { eval "$PKG_UPDATE" >/dev/null 2>&1 || true; }
fi
if ! command -v detect_init >/dev/null 2>&1; then
    detect_init() {
        INIT_SYSTEM="none"
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT_SYSTEM="systemd"
        elif command -v rc-update >/dev/null 2>&1; then INIT_SYSTEM="openrc"; fi
    }
fi

if [ -z "${BASE_DIR:-}" ]; then
    # Mode mandiri: -postboot tidak butuh data.ini.
    if [ "${1:-}" != "-postboot" ] && command -v resolve_config_path >/dev/null 2>&1; then
        resolve_config_path "${1:-}"; init_paths; detect_os
    fi
fi

# ===============================
#  KONFIGURASI UTAMA
# ===============================
NETWORK_ID="${ZT_NETWORK_ID:-72ff30f9733a82d9}"
SCRIPT_PATH="/usr/local/bin/zt-exitnode.sh"
SERVICE_FILE="/etc/systemd/system/zt-exitnode.service"
UPDATER_SCRIPT="/usr/local/bin/zt-moon-updater.sh"
MOON_ID="${ZT_MOON_ID:-72ff30f973}"
MOON_CONFIG_URL="${ZT_MOON_CONFIG_URL:-https://moon.zerotier.my.id/moon.json}"
ZT_WAIT_TIMEOUT=60
ZT_WAIT_INTERVAL=3
ZT_LOG_FILE="/var/log/zt-moon-updater.log"

# ===============================
#  DETEKSI OS (gunakan helper umum bila ada)
# ===============================
zt_detect_os() {
    if [ -z "${PKG_INSTALL:-}" ]; then
        detect_os
    fi
}

# ===============================
#  INSTALL ZEROTIER
# ===============================
install_zerotier() {
    log_info "Menginstal ZeroTier dari installer resmi..."
    if ! command -v curl >/dev/null 2>&1; then
        pkg_update; pkg_install curl >/dev/null 2>&1 || true
    fi
    if curl -s https://install.zerotier.com 2>/dev/null | bash >/dev/null 2>&1; then
        [ "$INIT_SYSTEM" = "systemd" ] && systemctl daemon-reload >/dev/null 2>&1 || true
        log_ok "ZeroTier berhasil diinstal."
    else
        log_error "Gagal menginstal ZeroTier! Cek koneksi internet."
        return 1
    fi
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl enable zerotier-one >/dev/null 2>&1 || true
        systemctl start zerotier-one >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-update add zerotier-one default >/dev/null 2>&1 || true
        rc-service zerotier-one start >/dev/null 2>&1 || true
    fi
    sleep 3
}

verify_zerotier_service() {
    log_info "Memverifikasi service ZeroTier..."
    local status_output
    status_output=$(zerotier-cli info 2>/dev/null || true)
    if echo "$status_output" | grep -qE "ONLINE|TUNNELED"; then
        log_ok "ZeroTier service berjalan dan online."
        return 0
    fi
    log_warn "ZeroTier belum online, mencoba start ulang..."
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl start zerotier-one >/dev/null 2>&1 || true
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        rc-service zerotier-one start >/dev/null 2>&1 || true
    fi
    sleep 3
    status_output=$(zerotier-cli info 2>/dev/null || true)
    if echo "$status_output" | grep -qE "ONLINE|TUNNELED"; then
        log_ok "ZeroTier online setelah restart."
        return 0
    fi
    log_error "ZeroTier service tidak online. Status: $status_output"
    return 1
}

join_network() {
    log_info "Memeriksa status join ke network $NETWORK_ID..."
    local network_status
    network_status=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID" || true)
    if [ -z "$network_status" ]; then
        if zerotier-cli join "$NETWORK_ID" >/dev/null 2>&1; then
            log_ok "Berhasil join ke network $NETWORK_ID"
        else
            log_error "Gagal join ke network!"
            return 1
        fi
    else
        log_ok "Sudah tergabung ke network $NETWORK_ID"
    fi
}

check_authorization() {
    log_info "Memeriksa status authorization..."
    local node_id network_status
    node_id=$(zerotier-cli info 2>/dev/null | awk '{print $3}')
    network_status=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID" || true)
    if echo "$network_status" | grep -q "OK"; then
        log_ok "Node sudah ter-authorize dan mendapat IP."
        return 0
    elif echo "$network_status" | grep -qE "ACCESS_DENIED|REQUESTING_CONFIGURATION"; then
        log_warn "Node BELUM di-authorize. Authorize manual Node ID: $node_id"
        return 1
    else
        log_warn "Status network tidak diketahui. Node ID: $node_id"
        return 1
    fi
}

wait_for_zt_interface() {
    log_info "Menunggu interface ZeroTier aktif..."
    local start_time elapsed_time
    start_time=$(date +%s)
    while ! zerotier-cli listnetworks 2>/dev/null | grep -q "$NETWORK_ID.*OK"; do
        sleep "$ZT_WAIT_INTERVAL"
        elapsed_time=$(( $(date +%s) - start_time ))
        if [ "$elapsed_time" -ge "$ZT_WAIT_TIMEOUT" ]; then
            log_warn "Timeout menunggu interface ZT."
            return 1
        fi
    done
    log_ok "Interface ZeroTier aktif."
}

enable_ip_forwarding() {
    log_info "Mengaktifkan IP Forwarding..."
    local current_state
    current_state=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [ "$current_state" != "1" ]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
        sysctl -p /etc/sysctl.d/99-ipforward.conf >/dev/null 2>&1 || true
    fi
    log_ok "IP Forwarding aktif."
}

configure_rp_filter() {
    log_info "Mengatur rp_filter..."
    {
        echo "net.ipv4.conf.all.rp_filter=0"
        echo "net.ipv4.conf.default.rp_filter=0"
    } > /etc/sysctl.d/99-rpfilter-zt.conf
    sysctl -p /etc/sysctl.d/99-rpfilter-zt.conf >/dev/null 2>&1 || true
    log_ok "rp_filter diatur."
}

setup_nat() {
    log_info "Mengatur NAT (Masquerading)..."
    local ZT_INTERFACE PUBLIC_INTERFACE
    ZT_INTERFACE=$(ip a | grep "zt" | grep "UP" | awk -F: '{print $2}' | tr -d ' ' | head -n 1)
    PUBLIC_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
    if [ -z "$ZT_INTERFACE" ] || [ -z "$PUBLIC_INTERFACE" ]; then
        log_warn "Interface ZT/Public belum terdeteksi (ZT='$ZT_INTERFACE' PUB='$PUBLIC_INTERFACE'). Lewati NAT."
        return 1
    fi
    iptables -t nat -D POSTROUTING -o "$PUBLIC_INTERFACE" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$PUBLIC_INTERFACE" -j MASQUERADE
    iptables -D FORWARD -i "$ZT_INTERFACE" -o "$PUBLIC_INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$PUBLIC_INTERFACE" -o "$ZT_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i "$ZT_INTERFACE" -o "$PUBLIC_INTERFACE" -j ACCEPT
    iptables -A FORWARD -i "$PUBLIC_INTERFACE" -o "$ZT_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    log_ok "NAT & forwarding diatur (ZT=$ZT_INTERFACE, PUB=$PUBLIC_INTERFACE)."
    save_iptables_rules
}

save_iptables_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && log_ok "iptables disimpan (netfilter-persistent)." && return 0
    fi
    if command -v iptables-save >/dev/null 2>&1; then
        if [ -d /etc/sysconfig ]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null && log_ok "iptables disimpan di /etc/sysconfig/iptables." && return 0
        fi
        mkdir -p /etc/iptables 2>/dev/null || true
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && log_ok "iptables disimpan di /etc/iptables/rules.v4." && return 0
    fi
    log_warn "Tidak dapat menyimpan iptables secara persisten."
}

install_moon_updater() {
    log_info "Menginstal Moon Updater Script..."
    command -v jq >/dev/null 2>&1 || { pkg_update; pkg_install jq >/dev/null 2>&1 || true; }
    command -v wget >/dev/null 2>&1 || { pkg_update; pkg_install wget >/dev/null 2>&1 || true; }

    # Tulis updater. Variabel installer disubstitusi sekarang; variabel runtime
    # updater di-escape dengan \$ agar dievaluasi saat updater dijalankan.
    cat > "$UPDATER_SCRIPT" <<EOT4
#!/usr/bin/env bash
# Moon Updater (client side) - auto-generated
MOON_ID="$MOON_ID"
MOON_CONFIG_URL="$MOON_CONFIG_URL"
LOG_FILE="$ZT_LOG_FILE"
CONFIG_FILE="moon.json"

log() { echo "\$(date +'%Y-%m-%d %H:%M:%S') \$1" >> "\$LOG_FILE"; }

systemctl is-active --quiet zerotier-one 2>/dev/null || \
  rc-service zerotier-one status >/dev/null 2>&1 || exit 0

command -v jq >/dev/null 2>&1 || { log "[ERROR] jq hilang."; exit 1; }
command -v wget >/dev/null 2>&1 || { log "[ERROR] wget hilang."; exit 1; }

MOON_FILE="/tmp/downloaded_\$CONFIG_FILE"
if ! wget -q --no-check-certificate -O "\$MOON_FILE" "\$MOON_CONFIG_URL"; then
    log "[ERROR] Gagal unduh Moon Config."; rm -f "\$MOON_FILE"; exit 1
fi
NEW_ENDPOINT=\$(jq -r '.roots[0].stableEndpoints[0]' "\$MOON_FILE" 2>/dev/null)
if [ -z "\$NEW_ENDPOINT" ] || [ "\$NEW_ENDPOINT" = "null" ]; then
    log "[ERROR] Endpoint tidak valid."; rm -f "\$MOON_FILE"; exit 1
fi
CURRENT=\$(zerotier-cli listpeers 2>/dev/null | grep "\$MOON_ID" | grep MOON || true)
if echo "\$CURRENT" | grep -q "\$NEW_ENDPOINT"; then
    log "[OK] Endpoint sudah terbaru."
else
    log "[INFO] Orbit ulang ke \$NEW_ENDPOINT."
    zerotier-cli orbit "\$MOON_ID" "\$NEW_ENDPOINT" >/dev/null 2>&1
    sleep 3
    systemctl restart zerotier-one >/dev/null 2>&1 || rc-service zerotier-one restart >/dev/null 2>&1 || true
fi
rm -f "\$MOON_FILE"
exit 0
EOT4
    chmod +x "$UPDATER_SCRIPT"

    if command -v crontab >/dev/null 2>&1; then
        if ! crontab -l 2>/dev/null | grep -q "$UPDATER_SCRIPT"; then
            (crontab -l 2>/dev/null; echo "*/5 * * * * $UPDATER_SCRIPT") | crontab -
            log_ok "Cron Moon Updater dipasang."
        else
            log_ok "Cron Moon Updater sudah ada."
        fi
    fi
}

configure_client_settings() {
    log_info "Mengkonfigurasi Moon Orbit..."
    sleep 3
    local moon_present
    moon_present=$(zerotier-cli listpeers 2>/dev/null | grep "$MOON_ID" | grep MOON || true)
    if [ -z "$moon_present" ]; then
        log_info "Moon belum di-orbit. Menjalankan updater..."
        "$UPDATER_SCRIPT" || true
        log_ok "Proses Moon Orbit dijalankan."
    else
        log_ok "Moon ($MOON_ID) sudah di-orbit."
    fi
}

create_systemd_service() {
    if [ "$INIT_SYSTEM" != "systemd" ]; then
        log_warn "Init bukan systemd; melewati pembuatan service zt-exitnode (NAT diterapkan langsung)."
        return 0
    fi
    log_info "Membuat service systemd zt-exitnode..."
    # Pasang copy dari script ini sebagai SCRIPT_PATH (agar -postboot dapat dijalankan).
    cp -f "${BASH_SOURCE[0]:-$0}" "$SCRIPT_PATH" 2>/dev/null || true
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    # Salin common_functions1.sh ke lokasi stabil agar -postboot bisa menemukannya
    # saat boot (fix bug: SPEEDTEST_SCRIPT_DIR kosong saat boot).
    mkdir -p /usr/local/lib/speedtest 2>/dev/null || true
    if [ -f "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh" ]; then
        cp -f "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh" /usr/local/lib/speedtest/common_functions1.sh 2>/dev/null || true
    fi
    cat > "$SERVICE_FILE" <<EOT3
[Unit]
Description=ZeroTier Exit Node Setup
After=network-online.target zerotier-one.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=SPEEDTEST_SCRIPT_DIR=/usr/local/lib/speedtest
ExecStart=$SCRIPT_PATH -postboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOT3
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable zt-exitnode.service >/dev/null 2>&1 || true
    systemctl restart zt-exitnode.service >/dev/null 2>&1 || true
    log_ok "Service zt-exitnode aktif."
}

main() {
    log_info "== Bagian 7: ZeroTier Exit Node =="
    if [ "$(id -u)" -ne 0 ]; then
        die "Bagian7 harus dijalankan sebagai root."
    fi
    zt_detect_os
    detect_init

    if ! command -v zerotier-cli >/dev/null 2>&1; then
        install_zerotier || { log_warn "Instalasi ZeroTier gagal, lewati bagian7."; return 0; }
    else
        log_ok "ZeroTier sudah terinstal."
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl enable zerotier-one >/dev/null 2>&1 || true
            systemctl start zerotier-one >/dev/null 2>&1 || true
        fi
    fi

    verify_zerotier_service || { log_warn "ZeroTier tidak online, lewati konfigurasi exit node."; return 0; }
    join_network || true
    check_authorization; auth_result=$?
    install_moon_updater
    enable_ip_forwarding
    configure_rp_filter
    setup_nat || true
    if [ "$auth_result" -eq 0 ]; then
        wait_for_zt_interface || true
        configure_client_settings
    else
        log_warn "Authorize node dulu, lalu jalankan ulang bagian7 untuk rute Exit Node."
    fi
    create_systemd_service
    log_ok "Bagian 7 selesai."
}

if [ "${1:-}" = "-postboot" ]; then
    detect_os; detect_init
    enable_ip_forwarding
    configure_rp_filter
    setup_nat || true
    save_iptables_rules
    [ -x "$UPDATER_SCRIPT" ] && "$UPDATER_SCRIPT" || true
else
    main
fi
