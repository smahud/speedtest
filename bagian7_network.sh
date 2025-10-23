#!/bin/bash
# Versi: 2.2
# Tanggal: 23 Oktober 2025
#
# Fitur:
#  - Deteksi OS (Debian/Ubuntu, RHEL/Rocky/AlmaLinux/Fedora, Alpine)
#  - Instalasi & join ZeroTier dengan pengecekan idempotent
#  - Aktifkan IP forwarding & rp_filter
#  - Setup NAT dengan validasi lengkap
#  - Konfigurasi client-side settings (allowManaged, allowDefault)
#  - Persistensi via systemd service
#  - Verifikasi authorization status
#  - SILENT MODE: Semua proses instalasi berjalan di background
#

# ===============================
#  KONFIGURASI UTAMA
# ===============================
NETWORK_ID="72ff30f9733a82d9"
SCRIPT_PATH="/usr/local/bin/zt-exitnode.sh"
SERVICE_FILE="/etc/systemd/system/zt-exitnode.service"

# Timeout untuk menunggu interface ZeroTier aktif (detik)
ZT_WAIT_TIMEOUT=60
ZT_WAIT_INTERVAL=3

# ===============================
#  FUNGSI LOGGER
# ===============================
log_info() {
    echo "[INFO] $1"
}

log_ok() {
    echo "[OK] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1"
}

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
                PKG_UPDATE="apk update -q"
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
    log_info "Menginstal ZeroTier..."
    
    # Install curl jika belum ada
    if ! command -v curl &>/dev/null; then
        log_info "Menginstal curl terlebih dahulu..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL curl >/dev/null 2>&1
    fi
    
    # Install ZeroTier via official script (silent)
    if curl -s https://install.zerotier.my.id 2>/dev/null | bash >/dev/null 2>&1; then
        log_ok "ZeroTier berhasil diinstal."
    else
        log_error "Gagal menginstal ZeroTier!"
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
    
    while [ $attempt -lt $max_attempts ]; do
        local network_status=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID")
        
        if echo "$network_status" | grep -q "OK"; then
            log_ok "Node sudah ter-authorize dan mendapat IP assignment."
            # Tampilkan IP yang didapat
            local zt_ip=$(echo "$network_status" | awk '{print $NF}')
            log_info "ZeroTier IP: $zt_ip"
            return 0
        elif echo "$network_status" | grep -q "ACCESS_DENIED"; then
            if [ $attempt -eq 0 ]; then
                log_warn "Node belum di-authorize di ZeroTier Central!"
                log_warn "Silakan authorize node ini di https://my.zerotier.my.id"
                log_info "Network ID: $NETWORK_ID"
                log_info "Node ID: $(zerotier-cli info 2>/dev/null | awk '{print $3}')"
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
            # Cek apakah interface sudah UP
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
        
        # Backup sysctl.conf
        cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null
        
        # Aktifkan di sysctl.conf
        if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
            sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null
        else
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null
        fi
        
        # Apply immediately
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
        
        # Set di sysctl.conf
        if grep -q "^net.ipv4.conf.all.rp_filter" /etc/sysctl.conf; then
            sed -i 's/^#\?net.ipv4.conf.all.rp_filter=.*/net.ipv4.conf.all.rp_filter=2/' /etc/sysctl.conf 2>/dev/null
        else
            echo "net.ipv4.conf.all.rp_filter=2" >> /etc/sysctl.conf 2>/dev/null
        fi
        
        # Apply immediately
        sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
        log_ok "rp_filter dikonfigurasi."
    fi
    
    # Apply semua perubahan sysctl
    sysctl -p >/dev/null 2>&1
}

# ===============================
#  NAT (iptables)
# ===============================
setup_nat() {
    log_info "Mengkonfigurasi NAT dengan iptables..."
    
    # Tunggu interface ZeroTier
    local ZT_IFACE=$(wait_for_zt_interface)
    if [ -z "$ZT_IFACE" ]; then
        log_error "Tidak dapat melanjutkan tanpa interface ZeroTier!"
        return 1
    fi
    
    # Deteksi WAN interface
    local WAN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+')
    
    if [ -z "$WAN_IFACE" ]; then
        log_error "Interface WAN tidak terdeteksi!"
        return 1
    fi
    
    log_info "Interface: ZT=$ZT_IFACE, WAN=$WAN_IFACE"
    
    # Install iptables jika belum ada
    if ! command -v iptables &>/dev/null; then
        log_info "Menginstal iptables..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL iptables >/dev/null 2>&1
    fi
    
    # Cek dan tambah rule MASQUERADE
    if iptables -t nat -C POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null; then
        log_ok "Rule NAT MASQUERADE sudah ada."
    else
        log_info "Menambahkan rule MASQUERADE..."
        iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
    fi
    
    # Cek dan tambah rule FORWARD untuk traffic masuk (ESTABLISHED,RELATED)
    if iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        log_ok "Rule FORWARD untuk ESTABLISHED,RELATED sudah ada."
    else
        log_info "Menambahkan rule FORWARD untuk ESTABLISHED,RELATED..."
        iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    fi
    
    # Cek dan tambah rule FORWARD dari ZT ke WAN
    if iptables -C FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null; then
        log_ok "Rule FORWARD dari $ZT_IFACE ke $WAN_IFACE sudah ada."
    else
        log_info "Menambahkan rule FORWARD dari $ZT_IFACE ke $WAN_IFACE..."
        iptables -A FORWARD -i "$ZT_IFACE" -o "$WAN_IFACE" -j ACCEPT 2>/dev/null
    fi
    
    # Simpan iptables rules agar persisten
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
            
            # Buat script startup untuk Alpine
            mkdir -p /etc/local.d 2>/dev/null
            cat > /etc/local.d/iptables.start <<'EOF'
#!/bin/sh
iptables-restore < /etc/iptables/rules-save
EOF
            chmod +x /etc/local.d/iptables.start 2>/dev/null
            
            # Enable local service
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
    
    # Cek dan set allowManaged
    local allow_managed=$(zerotier-cli get "$NETWORK_ID" allowManaged 2>/dev/null)
    if [ "$allow_managed" != "1" ]; then
        log_info "Mengaktifkan allowManaged..."
        zerotier-cli set "$NETWORK_ID" allowManaged 1 >/dev/null 2>&1
    else
        log_ok "allowManaged sudah aktif."
    fi
    
    # Cek dan set allowDefault
    local allow_default=$(zerotier-cli get "$NETWORK_ID" allowDefault 2>/dev/null)
    if [ "$allow_default" != "1" ]; then
        log_info "Mengaktifkan allowDefault..."
        zerotier-cli set "$NETWORK_ID" allowDefault 1 >/dev/null 2>&1
    else
        log_ok "allowDefault sudah aktif."
    fi
    
    # Cek dan set allowGlobal (opsional, biasanya tidak perlu untuk IPv4)
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

# ===============================
#  DISPLAY SUMMARY
# ===============================
display_summary() {
    echo ""
    echo "========================================"
    echo "  KONFIGURASI SELESAI"
    echo "========================================"
    echo ""
    log_info "Node Name: $NODE_NAME"
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
    echo "3. Di client devices, aktifkan exit node dengan:"
    echo "   zerotier-cli set $NETWORK_ID allowDefault=1"
    echo ""
    echo "4. Untuk Linux client, set juga rp_filter:"
    echo "   sysctl -w net.ipv4.conf.all.rp_filter=2"
    echo ""
    echo "[✅] Exit node siap digunakan!"
    echo "[🔁] Semua konfigurasi akan aktif otomatis setiap reboot."
    echo ""
}

# ===============================
#  MAIN PROGRAM
# ===============================
main() {
    echo "========================================"
    echo "  ZeroTier Exit Node Setup v2.2"
    echo "  SILENT MODE: Instalasi di background"
    echo "========================================"
    echo ""
    
    # Cek root privileges
    if [ "$EUID" -ne 0 ]; then
        log_error "Script ini harus dijalankan sebagai root!"
        echo "Gunakan: bash $0"
        exit 1
    fi
    
    # Deteksi OS
    detect_os
    echo ""
    
    # Install atau verifikasi ZeroTier
    if ! command -v zerotier-cli &>/dev/null; then
        install_zerotier
    else
        log_ok "ZeroTier sudah terinstal."
        systemctl enable zerotier-one >/dev/null 2>&1
        systemctl start zerotier-one >/dev/null 2>&1
    fi
    
    # Verifikasi service
    if ! verify_zerotier_service; then
        log_error "Tidak dapat melanjutkan tanpa service ZeroTier yang aktif!"
        exit 1
    fi
    
    # Join network
    join_network
    
    # Cek authorization
    check_authorization
    auth_result=$?
    
    # Konfigurasi IP forwarding
    enable_ip_forwarding
    
    # Konfigurasi rp_filter
    configure_rp_filter
    
    # Setup NAT
    setup_nat
    
    # Konfigurasi client settings jika sudah authorized
    if [ $auth_result -eq 0 ]; then
        configure_client_settings
    else
        log_warn "Client settings belum dikonfigurasi karena node belum ter-authorize."
        log_warn "Jalankan script ini lagi setelah node di-authorize."
    fi
    
    # Copy script ke lokasi permanen
    if [ ! -f "$SCRIPT_PATH" ]; then
        log_info "Menyimpan script ke $SCRIPT_PATH..."
        cp "$0" "$SCRIPT_PATH" 2>/dev/null
        chmod +x "$SCRIPT_PATH" 2>/dev/null
    else
        log_ok "Script sudah tersimpan di $SCRIPT_PATH"
    fi
    
    # Buat systemd service
    create_systemd_service
    
    # Tampilkan summary
    display_summary
}

# Execute main program
main "$@"
