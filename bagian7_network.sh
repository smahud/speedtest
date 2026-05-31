#!/usr/bin/env bash
###############################################################################
# bagian7_network.sh — ZeroTier Exit Node + Moon Updater
# Versi: 5.0 (Alpine Fallback Support)
###############################################################################
set -uo pipefail

SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR

# Source common_functions1.sh BILA tersedia.
if [ -f "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh" ]; then
    . "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"
fi

# Fallback definisi minimal
if ! command -v log_info >/dev/null 2>&1; then
    log_info()  { printf '[INFO] %s\n' "$1"; }
    log_ok()    { printf '[OK] %s\n' "$1"; }
    log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
    log_error() { printf '[ERROR] %s\n' "$1" >&2; }
    die()       { log_error "$1"; exit "${2:-1}"; }
    command_exists() { command -v "$1" >/dev/null 2>&1; }
fi

if [ -z "${BASE_DIR:-}" ]; then
    if [ "${1:-}" != "-postboot" ] && command -v resolve_config_path >/dev/null 2>&1; then
        resolve_config_path "${1:-}"; init_paths; detect_os
    fi
fi

# ===============================
#  KONFIGURASI UTAMA
# ===============================
NETWORK_ID="${ZeroTierNetworkID:-72ff30f9733a82d9}"
SCRIPT_PATH="/usr/local/bin/zt-exitnode.sh"
SERVICE_FILE="/etc/systemd/system/zt-exitnode.service"
UPDATER_SCRIPT="/usr/local/bin/zt-moon-updater.sh"
MOON_ID="${ZeroTierMoonID:-72ff30f973}"
MOON_CONFIG_URL="${ZeroTierMoonConfigURL:-https://moon.zerotier.my.id/moon.json}"
ZT_WAIT_TIMEOUT=60
ZT_WAIT_INTERVAL=3
ZT_LOG_FILE="/var/log/zt-moon-updater.log"

# ===============================
#  INSTALL ZEROTIER
# ===============================
install_zerotier() {
    log_info "Menginstal ZeroTier..."
    
    if [ "${OS_FAMILY:-}" = "alpine" ]; then
        local alpine_ver
        alpine_ver=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo "latest-stable")
        
        if [ -f /etc/apk/repositories ]; then
            local repo_added=0
            for repo_url in \
                "https://dl-cdn.alpinelinux.org/alpine/v$alpine_ver/community" \
                "https://dl-cdn.alpinelinux.org/alpine/edge/community"; do
                if ! grep -q "$repo_url" /etc/apk/repositories; then
                    echo "$repo_url" >> /etc/apk/repositories
                    repo_added=1
                fi
            done
            [ "$repo_added" -eq 1 ] && apk update >/dev/null 2>&1
        fi
        
        if apk add --no-cache zerotier-one; then
            log_ok "ZeroTier berhasil diinstal via apk."
        else
            log_warn "APK gagal. Mencoba menggunakan biner dari repository..."
            local arch=$(uname -m)
            local raw_url="${REPO_RAW_BASE:-https://raw.githubusercontent.com/smahud/speedtest/main}"
            local remote_bin="$raw_url/zerotier/zerotier-one-$arch-alpine"
            local local_bin="/usr/sbin/zerotier-one"

            if wget -q -O "$local_bin" "$remote_bin"; then
                chmod +x "$local_bin"
                [ -L /usr/sbin/zerotier-cli ] || ln -sf "$local_bin" /usr/sbin/zerotier-cli
                [ -L /usr/sbin/zerotier-idtool ] || ln -sf "$local_bin" /usr/sbin/zerotier-idtool
                mkdir -p /var/lib/zerotier-one
                log_ok "ZeroTier terpasang via biner statis ($arch)."
            else
                log_error "Gagal menginstal ZeroTier. Paket tidak tersedia dan biner fallback tidak ditemukan."
                return 1
            fi
        fi
    else
        log_info "Menggunakan installer resmi ZeroTier..."
        if curl -s https://install.zerotier.com | bash >/dev/null 2>&1; then
            log_ok "ZeroTier berhasil diinstal via installer resmi."
        else
            log_error "Gagal via script! Mencoba via package manager..."
            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y zerotier-one
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y zerotier-one
            elif command -v yum >/dev/null 2>&1; then
                yum install -y zerotier-one
            fi
        fi
    fi
    
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable zerotier-one >/dev/null 2>&1 || true
        systemctl start zerotier-one >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        if [ ! -f /etc/init.d/zerotier-one ]; then
            cat > /etc/init.d/zerotier-one <<'EOF'
#!/sbin/openrc-run
description="ZeroTier One"
command="/usr/sbin/zerotier-one"
command_args="-d"
pidfile="/run/zerotier-one.pid"
depend() {
	need net
	after bootmisc
}
EOF
            chmod +x /etc/init.d/zerotier-one
        fi
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
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl start zerotier-one >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
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
    if zerotier-cli listnetworks 2>/dev/null | grep -q "$NETWORK_ID"; then
        log_ok "Sudah tergabung ke network $NETWORK_ID"
    else
        if zerotier-cli join "$NETWORK_ID" >/dev/null 2>&1; then
            log_ok "Berhasil join ke network $NETWORK_ID"
        else
            log_error "Gagal join ke network!"
            return 1
        fi
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
    else
        log_warn "Node BELUM di-authorize. Authorize manual Node ID: $node_id"
        return 1
    fi
}

enable_ip_forwarding() {
    log_info "Mengaktifkan IP Forwarding..."
    if [ -f /etc/sysctl.d/99-ipforward.conf ]; then
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
        sysctl -p /etc/sysctl.d/99-ipforward.conf >/dev/null 2>&1 || true
    else
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    fi
    log_ok "IP Forwarding aktif."
}

setup_nat() {
    log_info "Mengatur NAT (Masquerading)..."
    local ZT_INTERFACE PUBLIC_INTERFACE
    ZT_INTERFACE=$(ip a | grep "zt" | grep "UP" | awk -F: '{print $2}' | tr -d ' ' | head -n 1)
    PUBLIC_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
    if [ -z "$ZT_INTERFACE" ] || [ -z "$PUBLIC_INTERFACE" ]; then
        log_warn "Interface belum lengkap. Lewati NAT."
        return 1
    fi
    iptables -t nat -A POSTROUTING -o "$PUBLIC_INTERFACE" -j MASQUERADE 2>/dev/null || true
    iptables -A FORWARD -i "$ZT_INTERFACE" -o "$PUBLIC_INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i "$PUBLIC_INTERFACE" -o "$ZT_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    log_ok "NAT diatur."
}

install_moon_updater() {
    log_info "Menginstal Moon Updater..."
    cat > "$UPDATER_SCRIPT" <<EOF
#!/usr/bin/env bash
MOON_ID="$MOON_ID"
MOON_CONFIG_URL="$MOON_CONFIG_URL"
LOG_FILE="$ZT_LOG_FILE"
log() { echo "\$(date) \$1" >> "\$LOG_FILE"; }
if ! command -v jq >/dev/null 2>&1; then exit 1; fi
MOON_FILE="/tmp/moon.json"
if wget -q -O "\$MOON_FILE" "\$MOON_CONFIG_URL"; then
    ENDPOINT=\$(jq -r '.roots[0].stableEndpoints[0]' "\$MOON_FILE")
    zerotier-cli orbit "\$MOON_ID" "\$ENDPOINT" >/dev/null 2>&1
    log "Orbit to \$ENDPOINT"
fi
EOF
    chmod +x "$UPDATER_SCRIPT"
    (crontab -l 2>/dev/null; echo "*/15 * * * * $UPDATER_SCRIPT") | crontab - 2>/dev/null || true
}

main() {
    log_info "== Bagian 7: ZeroTier Exit Node =="
    install_zerotier || return 0
    verify_zerotier_service || return 0
    join_network || true
    check_authorization
    enable_ip_forwarding
    setup_nat || true
    install_moon_updater
    log_ok "Bagian 7 selesai."
}

if [ "${1:-}" = "-postboot" ]; then
    enable_ip_forwarding
    setup_nat || true
else
    main
fi
