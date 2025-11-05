#!/bin/bash
# Versi: 3.2 (Full Auto IP Local + Idempotent Cron)
# Tanggal: 5 November 2025
#
# Fitur:
#  - Deteksi OS, Instalasi & Join ZeroTier
#  - Setup NAT, IP Forwarding, rp_filter
#  - Auto-install Moon Updater Script
#  - **Deteksi IP Lokal Controller Otomatis**
#

# ===============================
#  KONFIGURASI UTAMA
# ===============================
NETWORK_ID="72ff30f9733a82d9"      # <-- GANTI DENGAN ID 16-DIGIT NETWORK ANDA
SCRIPT_PATH="/usr/local/bin/zt-exitnode.sh"
SERVICE_FILE="/etc/systemd/system/zt-exitnode.service"
UPDATER_SCRIPT="/usr/local/bin/zt-moon-updater.sh"

# --- KONFIGURASI KRITIS UNTUK AUTO-UPDATE MOON ---
MOON_ID="72ff30f973"               # <-- GANTI DENGAN ID 10-DIGIT CONTROLLER ANDA
# ------------------------------------------------

# Timeout untuk menunggu interface ZeroTier aktif (detik)
ZT_WAIT_TIMEOUT=60
ZT_WAIT_INTERVAL=3
LOG_FILE="/var/log/zt-moon-updater.log"

# ===============================
#  FUNGSI LOGGER
# ===============================
log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }

# ===============================
#  DETEKSI OS
# ===============================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            debian|ubuntu)
                OS_TYPE="debian"
                PKG_INSTALL="apt-get install -y -qq"
                PKG_UPDATE="apt-get update -y -qq"
                ;;
            centos|rhel|rocky|almalinux|fedora)
                OS_TYPE="rhel"
                PKG_INSTALL="dnf install -y -q"
                PKG_UPDATE="dnf update -y -q"
                ;;
            alpine)
                OS_TYPE="alpine"
                PKG_INSTALL="apk add --no-cache -q"
                PKG_UPDATE="apk update -y -q"
                ;;
            *)
                log_error "OS tidak dikenali: $ID. Hanya mendukung Debian, RHEL, atau Alpine."
                exit 1
                ;;
        esac
        log_info "OS terdeteksi: $PRETTY_NAME ($OS_TYPE)"
    else
        log_error "Tidak dapat mendeteksi OS! File /etc/os-release tidak ditemukan."
        exit 1
    fi
}

# ===============================
#  INSTALL ZEROTIER
# ===============================
install_zerotier() {
    log_info "Menginstal ZeroTier dari https://install.zerotier.my.id..."
    
    # Install curl jika belum ada
    if ! command -v curl &>/dev/null; then
        log_info "Menginstal curl terlebih dahulu..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL curl >/dev/null 2>&1
    fi
    
    # Install ZeroTier via domain kustom Anda
    if curl -s https://install.zerotier.my.id 2>/dev/null | bash >/dev/null 2>&1; then
        log_ok "ZeroTier berhasil diinstal."
    else
        log_error "Gagal menginstal ZeroTier! Cek ketersediaan https://install.zerotier.my.id"
        exit 1
    fi
    
    # Enable & start service (silent)
    systemctl enable zerotier-one >/dev/null 2>&1
    systemctl start zerotier-one >/dev/null 2>&1
    sleep 3
}

# ===============================
#  VERIFIKASI SERVICE ZEROTIER
# ===============================
verify_zerotier_service() {
    log_info "Memverifikasi service ZeroTier..."
    
    if ! systemctl is-active --quiet zerotier-one; then
        log_warn "Service zerotier-one tidak aktif, mencoba start..."
        systemctl start zerotier-one >/dev/null 2>&1
        sleep 3
    fi
    
    # Cek status online
    local status_output=$(zerotier-cli info 2>/dev/null)
    if echo "$status_output" | grep -qE "ONLINE|TUNNELED"; then
        log_ok "ZeroTier service berjalan dan online."
        return 0
    else
        log_error "ZeroTier service tidak online! Status: $status_output"
        return 1
    fi
}

# ===============================
#  JOIN NETWORK
# ===============================
join_network() {
    log_info "Memeriksa status join ke network $NETWORK_ID..."
    
    local network_status=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID")
    
    if [ -z "$network_status" ]; then
        log_info "Belum tergabung, melakukan join..."
        if zerotier-cli join "$NETWORK_ID" >/dev/null 2>&1; then
            log_ok "Berhasil join ke network $NETWORK_ID"
        else
            log_error "Gagal join ke network!"
            exit 1
        fi
    else
        log_ok "Sudah tergabung ke network $NETWORK_ID"
    fi
}

# ===============================
#  CEK AUTHORIZATION STATUS
# ===============================
check_authorization() {
    log_info "Memeriksa status authorization..."
    
    local max_attempts=20
    local attempt=0
    local node_id=$(zerotier-cli info 2>/dev/null | awk '{print $3}')
    
    while [ $attempt -lt $max_attempts ]; do
        local network_status=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID")
        
        if echo "$network_status" | grep -q "OK"; then
            log_ok "Node sudah ter-authorize dan mendapat IP assignment."
            local zt_ip=$(echo "$network_status" | awk '{print $NF}')
            log_info "ZeroTier IP: $zt_ip"
            return 0
        elif echo "$network_status" | grep -q "ACCESS_DENIED"; then
            if [ $attempt -eq 0 ]; then
                log_warn "Node belum di-authorize di ZeroTier Central!"
                log_warn "Silakan authorize node ini di https://my.zerotier.my.id"
                log_info "Network ID: $NETWORK_ID"
                log_info "Node ID: $node_id"
            fi
            log_warn "Menunggu authorization... ($((attempt+1))/$max_attempts)"
        elif echo "$network_status" | grep -q "REQUESTING_CONFIGURATION"; then
            log_info "Sedang request konfigurasi dari controller... ($((attempt+1))/$max_attempts)"
        fi
        
        sleep 5
        attempt=$((attempt+1))
    done
    
    log_error "Node tidak mendapat authorization setelah $max_attempts percobaan!"
    log_error "PENTING: Anda harus authorize node ini secara manual di ZeroTier Central."
    return 1
}

# ===============================
#  TUNGGU INTERFACE ZEROTIER AKTIF
# ===============================
wait_for_zt_interface() {
    log_info "Menunggu interface ZeroTier aktif..."
    
    local elapsed=0
    while [ $elapsed -lt $ZT_WAIT_TIMEOUT ]; do
        local zt_iface=$(ip -o link show 2>/dev/null | awk -F': ' '/zt[a-z0-9]+/{print $2; exit}')
        
        if [ -n "$zt_iface" ]; then
            if ip link show "$zt_iface" 2>/dev/null | grep -q "state UP"; then
                log_ok "Interface ZeroTier aktif: $zt_iface"
                echo "$zt_iface"
                return 0
            fi
        fi
        
        sleep $ZT_WAIT_INTERVAL
        elapsed=$((elapsed + ZT_WAIT_INTERVAL))
    done
    
    log_error "Interface ZeroTier tidak terdeteksi setelah $ZT_WAIT_TIMEOUT detik!"
    return 1
}

# ===============================
#  IP FORWARDING
# ===============================
enable_ip_forwarding() {
    log_info "Mengecek IP forwarding..."
    
    local current_forward=$(sysctl net.ipv4.ip_forward 2>/dev/null | awk '{print $3}')
    
    if [ "$current_forward" = "1" ]; then
        log_ok "IP forwarding sudah aktif."
    else
        log_info "Mengaktifkan IP forwarding..."
        
        cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null
        
        if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
            sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null
        else
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null
        fi
        
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
        log_ok "IP forwarding diaktifkan."
    fi
}

# ===============================
#  RP_FILTER (untuk client Linux)
# ===============================
configure_rp_filter() {
    log_info "Mengkonfigurasi rp_filter untuk kompatibilitas routing..."
    
    local current_rp=$(sysctl net.ipv4.conf.all.rp_filter 2>/dev/null | awk '{print $3}')
    
    if [ "$current_rp" = "2" ]; then
        log_ok "rp_filter sudah diset ke mode loose (2)."
    else
        log_info "Mengubah rp_filter ke mode loose (2)..."
        
        if grep -q "^net.ipv4.conf.all.rp_filter" /etc/sysctl.conf; then
            sed -i 's/^#\?net.ipv4.conf.all.rp_filter=.*/net.ipv4.conf.all.rp_filter=2/' /etc/sysctl.conf 2>/dev/null
        else
            echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.conf 2>/dev/null
        fi
        
        sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
        log_ok "rp_filter dikonfigurasi."
    fi
    
    sysctl -p >/dev/null 2>&1
}

# ===============================
#  NAT (iptables)
# ===============================
setup_nat() {
    log_info "Mengkonfigurasi NAT dengan iptables..."
    
    local ZT_IFACE=$(wait_for_zt_interface)
    if [ -z "$ZT_IFACE" ]; then
        log_error "Tidak dapat melanjutkan tanpa interface ZeroTier!"
        return 1
    fi
    
    local WAN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+')
    
    if [ -z "$WAN_IFACE" ]; then
        log_error "Interface WAN tidak terdeteksi!"
        return 1
    fi
    
    log_info "Interface: ZT=$ZT_IFACE, WAN=$WAN_IFACE"
    
    if ! command -v iptables &>/dev/null; then
        log_info "Menginstal iptables..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL iptables >/dev/null 2>&1
    fi
    
    # Cek dan tambah rule MASQUERADE
    if ! iptables -t nat -C POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null; then
        log_info "Menambahkan rule MASQUERADE..."
        iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
    else
        log_ok "Rule NAT MASQUERADE sudah ada."
    fi
    
    # Cek dan tambah rule FORWARD (ESTABLISHED,RELATED)
    if ! iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        log_info "Menambahkan rule FORWARD untuk ESTABLISHED,RELATED..."
        iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    else
        log_ok "Rule FORWARD untuk ESTABLISHED,RELATED sudah ada."
    fi
    
    # Cek dan tambah rule FORWARD dari ZT ke WAN
    if ! iptables -C FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null; then
        log_info "Menambahkan rule FORWARD dari $ZT_IFACE ke $WAN_IFACE..."
        iptables -A FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
    else
        log_ok "Rule FORWARD dari $ZT_IFACE ke $WAN_IFACE sudah ada."
    fi
    
    save_iptables_rules
}

# ===============================
#  SIMPAN IPTABLES RULES
# ===============================
save_iptables_rules() {
    log_info "Menyimpan iptables rules untuk persistensi..."
    
    case "$OS_TYPE" in
        debian|rhel)
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save >/dev/null 2>&1
                log_ok "Rules disimpan via netfilter-persistent."
            else
                log_info "Menginstal netfilter-persistent dan iptables-persistent..."
                $PKG_UPDATE >/dev/null 2>&1
                if [ "$OS_TYPE" = "debian" ]; then
                    DEBIAN_FRONTEND=noninteractive $PKG_INSTALL netfilter-persistent iptables-persistent >/dev/null 2>&1
                else
                    $PKG_INSTALL iptables-services >/dev/null 2>&1
                    systemctl enable iptables >/dev/null 2>&1
                fi
                
                if command -v netfilter-persistent &>/dev/null; then
                    netfilter-persistent save >/dev/null 2>&1
                elif command -v service &>/dev/null && [ "$OS_TYPE" = "rhel" ]; then
                    service iptables save >/dev/null 2>&1
                fi
                log_ok "Rules disimpan."
            fi
            ;;
        alpine)
            mkdir -p /etc/iptables 2>/dev/null
            iptables-save > /etc/iptables/rules-save 2>/dev/null
            
            mkdir -p /etc/local.d 2>/dev/null
            cat > /etc/local.d/iptables.start <<'EOF'
#!/bin/sh
iptables-restore < /etc/iptables/rules-save
EOF
            chmod +x /etc/local.d/iptables.start 2>/dev/null
            
            if command -v rc-update &>/dev/null; then
                rc-update add local default >/dev/null 2>&1
            fi
            log_ok "Rules disimpan untuk Alpine Linux."
            ;;
    esac
}

# ===============================
#  CLIENT-SIDE SETTINGS
# ===============================
configure_client_settings() {
    log_info "Mengkonfigurasi client-side settings untuk exit node..."
    
    local allow_managed=$(zerotier-cli get "$NETWORK_ID" allowManaged 2>/dev/null)
    if [ "$allow_managed" != "1" ]; then
        log_info "Mengaktifkan allowManaged..."
        zerotier-cli set "$NETWORK_ID" allowManaged 1 >/dev/null 2>&1
    else
        log_ok "allowManaged sudah aktif."
    fi
    
    local allow_default=$(zerotier-cli get "$NETWORK_ID" allowDefault 2>/dev/null)
    if [ "$allow_default" != "1" ]; then
        log_info "Mengaktifkan allowDefault..."
        zerotier-cli set "$NETWORK_ID" allowDefault 1 >/dev/null 2>&1
    else
        log_ok "allowDefault sudah aktif."
    fi
    
    local allow_global=$(zerotier-cli get "$NETWORK_ID" allowGlobal 2>/dev/null)
    if [ "$allow_global" != "1" ]; then
        log_info "Mengaktifkan allowGlobal..."
        zerotier-cli set "$NETWORK_ID" allowGlobal 1 >/dev/null 2>&1
    else
        log_ok "allowGlobal sudah aktif."
    fi
    
    log_ok "Client-side settings dikonfigurasi."
}

# ===============================
#  SYSTEMD SERVICE
# ===============================
create_systemd_service() {
    if [ -f "$SERVICE_FILE" ]; then
        log_ok "Systemd service sudah ada: $SERVICE_FILE"
        return 0
    fi
    
    log_info "Membuat systemd service untuk auto-start..."
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ZeroTier Exit Node Auto Setup
After=network-online.target zerotier-one.service
Wants=network-online.target
Requires=zerotier-one.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable zt-exitnode.service >/dev/null 2>&1
    log_ok "Systemd service dibuat dan dienable."
}

# ------------------------------------------------------------------
# FUNGSI BARU: INSTALASI MOON UPDATER OTOMATIS (IDEMPOTENT & AUTO-IP)
# ------------------------------------------------------------------
install_moon_updater() {
    log_info "Menginstal Moon Updater Script..."

    # 1. Buat script updater (menimpa jika sudah ada untuk memastikan konfigurasi baru)
    cat > "$UPDATER_SCRIPT" <<EOF
#!/bin/bash
# Script Updater Moon Server ZeroTier (Client Side)
# Dijalankan via Cron Job

# --- KONFIGURASI OTOMATIS ---
ZT_HOME="/var/lib/zerotier-one"
MOON_ID="$MOON_ID"
NETWORK_ID="$NETWORK_ID"
# --------------------------
LOG_FILE="$LOG_FILE"

log() {
    echo "\$(date +'%Y-%m-%d %H:%M:%S') \$1" >> "\$LOG_FILE"
}

get_controller_zt_ip() {
    # Pastikan jq terinstal di sini (karena cron mungkin memiliki lingkungan terbatas)
    if ! command -v jq &>/dev/null; then
        return 1
    fi
    
    # Ambil konfigurasi jaringan ZeroTier dalam format JSON
    local zt_network_config=\$(/usr/sbin/zerotier-cli listnetworks -j 2>/dev/null | /usr/bin/jq -r ".[] | select(.nwid == \"\$NETWORK_ID\")")
    
    if [ -z "\$zt_network_config" ]; then
        return 1
    fi

    # Ekstrak managed IP range (misal 10.147.0.0/16)
    # Ambil IP pertama dari assignedAddresses yang mengandung subnet mask (/)
    local managed_range=\$(echo "\$zt_network_config" | /usr/bin/jq -r '.assignedAddresses[] | select(contains("/"))' | head -n 1 | cut -d '/' -f 1-2)

    # Controller (Node Master) selalu memiliki IP x.x.x.1
    if [ -n "\$managed_range" ]; then
        # Misal: 10.147.0
        local base_ip=\$(echo "\$managed_range" | cut -d '.' -f 1-3)
        echo "\$base_ip.1"
        return 0
    fi

    return 1
}

if ! systemctl is-active --quiet zerotier-one; then
    log "[INFO] ZeroTier tidak aktif. Melewatkan update."
    exit 0
fi

# 2. Cek dependensi (curl dan jq)
if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
    # Kita tidak mencoba menginstal di sini, hanya log error, karena instalasi harus dilakukan oleh script utama
    log "[ERROR] Dependensi (jq/curl) hilang. Cek instalasi di script utama."
    exit 1
fi

CONTROLLER_ZT_IP=\$(get_controller_zt_ip)

if [ -z "\$CONTROLLER_ZT_IP" ]; then
    log "[ERROR] Tidak dapat menentukan IP Controller ZT. Melewatkan pembaruan."
    exit 1
fi

CONFIG_URL="http://\$CONTROLLER_ZT_IP/latest_moon_config.json"
log "[INFO] IP Controller ZT Terdeteksi: \$CONTROLLER_ZT_IP. Mengunduh config..."

if ! /usr/bin/curl -s --max-time 10 "\$CONFIG_URL" -o /tmp/downloaded_moon.json; then
    log "[ERROR] Gagal mengunduh file dari Controller ZT IP (\$CONTROLLER_ZT_IP). Koneksi RELAY/LAN mungkin bermasalah."
    exit 1
fi

NEW_ENDPOINT=\$(grep -oP '"stableEndpoints": \[\s*"[^"]*"\s*\]' /tmp/downloaded_moon.json | grep -oP '"[^"]*"' | tr -d '"' | head -n 1)

if [ -z "\$NEW_ENDPOINT" ]; then
    log "[ERROR] Gagal mendapatkan Stable Endpoint. File config mungkin tidak valid."
    rm -f /tmp/downloaded_moon.json
    exit 1
fi

CURRENT_PEER_INFO=\$(/usr/sbin/zerotier-cli listpeers | grep "\$MOON_ID" | grep MOON)

if echo "\$CURRENT_PEER_INFO" | grep -q "\$NEW_ENDPOINT"; then
    log "[OK] Endpoint (\$NEW_ENDPOINT) sudah terdaftar. Tidak ada perubahan."
else
    log "[WARNING] Endpoint baru terdeteksi: \$NEW_ENDPOINT. Memulai proses Orbit ulang."

    /usr/sbin/zerotier-cli orbit "\$MOON_ID" "\$NEW_ENDPOINT"
    sleep 3
    systemctl restart zerotier-one
    
    log "[SUCCESS] Controller di-orbit ulang ke \$NEW_ENDPOINT dan ZeroTier di-restart."
fi

rm -f /tmp/downloaded_moon.json
exit 0
EOF

    # 2. Berikan izin eksekusi
    chmod +x "$UPDATER_SCRIPT"

    # 3. Setup Cron Job (Jalankan setiap 5 menit)
    if command -v crontab &>/dev/null; then
        # Cek apakah baris cron sudah ada
        if ! crontab -l 2>/dev/null | grep -q "$UPDATER_SCRIPT"; then
            (crontab -l 2>/dev/null; echo "*/5 * * * * $UPDATER_SCRIPT") | crontab -
            log_ok "Cron job untuk Moon Updater diinstal."
        else
            log_ok "Cron job untuk Moon Updater sudah ada. Melewati penambahan."
        fi
    else
        log_warn "Crontab tidak ditemukan."
    fi
    
    # Tambahan: Pastikan JQ terinstal (dibutuhkan untuk auto-deteksi IP)
    if ! command -v jq &>/dev/null; then
        log_info "Menginstal jq (JSON processor) untuk auto-deteksi IP ZT..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL jq >/dev/null 2>&1
        log_ok "jq berhasil diinstal."
    fi
}

# ===============================
#  DISPLAY SUMMARY
# ===============================
display_summary() {
    echo ""
    echo "========================================"
    echo "  KONFIGURASI SELESAI"
    echo "========================================"
    echo ""
    log_info "Node Name: $(hostname)"
    log_info "Network ID: $NETWORK_ID"
    log_info "Node ID: $(zerotier-cli info 2>/dev/null | awk '{print $3}')"
    
    local zt_ip=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID" | awk '{print $NF}')
    if [ -n "$zt_ip" ]; then
        log_info "ZeroTier IP: $zt_ip"
    fi
    
    echo ""
    echo "LANGKAH SELANJUTNYA:"
    echo "--------------------"
    echo "1. Pastikan node ini sudah di-authorize di:"
    echo "   https://my.zerotier.my.id"
    echo ""
    echo "2. Tambahkan Managed Route di ZeroTier Central:"
    echo "   Destination: 0.0.0.0/0"
    echo "   Via: <ZeroTier-IP-node-ini>"
    echo ""
    echo "[✅] Exit node siap digunakan!"
    echo "[🔁] Moon Config Update otomatis setiap 5 menit."
    echo ""
}

# ===============================
#  MAIN PROGRAM
# ===============================
main() {
    echo "========================================"
    echo "  ZeroTier Exit Node Setup v3.2"
    echo "  SILENT MODE: Instalasi di background"
    echo "========================================"
    echo ""
    
    if [ "$EUID" -ne 0 ]; then
        log_error "Script ini harus dijalankan sebagai root!"
        echo "Gunakan: bash $0"
        exit 1
    fi
    
    detect_os
    
    # 1. Install ZT
    if ! command -v zerotier-cli &>/dev/null; then
        install_zerotier
    else
        log_ok "ZeroTier sudah terinstal."
        systemctl enable zerotier-one >/dev/null 2>&1
        systemctl start zerotier-one >/dev/null 2>&1
    fi
    
    if ! verify_zerotier_service; then exit 1; fi
    
    # 2. Join Network
    join_network
    
    # 3. Check Authorization
    check_authorization
    auth_result=$?
    
    # 4. Instalasi Updater (dengan Auto-IP ZT)
    install_moon_updater
    
    # 5. Konfigurasi Sistem
    enable_ip_forwarding
    configure_rp_filter
    setup_nat
    
    # 6. Konfigurasi Client ZT
    if [ $auth_result -eq 0 ]; then
        configure_client_settings
    else
        log_warn "Client settings akan diatur setelah node di-authorize."
    fi
    
    # 7. Persistensi
    if [ ! -f "$SCRIPT_PATH" ]; then
        log_info "Menyimpan script ke $SCRIPT_PATH..."
        cp "$0" "$SCRIPT_PATH" 2>/dev/null
        chmod +x "$SCRIPT_PATH" 2>/dev/null
    else
        log_ok "Script sudah tersimpan di $SCRIPT_PATH"
    fi
    create_systemd_service
    
    display_summary
}

# Execute main program
main "$@"
