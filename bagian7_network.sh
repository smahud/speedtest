#!/bin/bash
# Versi: 3.5 (Full Dynamic IP Moon Updater - NO WAIT AUTH)
# Dibuat pada 6 November 2025
#
# KONFIGURASI:
#  - NETWORK_ID: Menggunakan ID Jaringan yang diinjeksikan
#  - MOON_ID: Menggunakan ID Moon yang diinjeksikan
#
# FITUR BARU: Moon Updater menggunakan brute-force deteksi IP di subnet, 
#            sehingga 100% self-healing jika IP Controller ZT berubah.
#

# ===============================
#  KONFIGURASI UTAMA
# ===============================
NETWORK_ID="72ff30f9733a82d9"      # <-- GANTI DENGAN ID 16-DIGIT NETWORK ANDA
SCRIPT_PATH="/usr/local/bin/zt-exitnode.sh"
SERVICE_FILE="/etc/systemd/system/zt-exitnode.service"
UPDATER_SCRIPT="/usr/local/bin/zt-moon-updater.sh"

# --- KONFIGURASI KRITIS UNTUK AUTO-UPDATE MOON ---
MOON_ID="72ff30f973"               
MOON_CONFIG_URL="https://moon.zerotier.my.id/moon.json" # <-- TAMBAH/GANTI INI
# ------------------------------------------------
# ...
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
    else
        log_error "Tidak dapat mendeteksi OS! File /etc/os-release tidak ditemukan."
        exit 1
    fi
}

# ===============================
#  INSTALL ZEROTIER
# ===============================
install_zerotier() {
    log_info "Menginstal ZeroTier dari repositori resmi (https://install.zerotier.com)..."
    
    # Install curl jika belum ada
    if ! command -v curl &>/dev/null; then
        log_info "Menginstal curl terlebih dahulu..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL curl >/dev/null 2>&1
    fi
    
    # Install ZeroTier via installer resmi
    if curl -s https://install.zerotier.com 2>/dev/null | bash >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1
        log_ok "ZeroTier berhasil diinstal."
    else
        log_error "Gagal menginstal ZeroTier! Cek koneksi internet."
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
    
    local status_output=$(zerotier-cli info 2>/dev/null)
    if echo "$status_output" | grep -qE "ONLINE|TUNNELED"; then
        log_ok "ZeroTier service berjalan dan online."
        return 0
    else
        local journal_log=$(journalctl -xeu zerotier-one.service | tail -n 5)
        log_error "ZeroTier service tidak online! Status: $status_output"
        log_error "LOG JURNAL TERAKHIR:\n$journal_log"
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
#  CEK AUTHORIZATION STATUS (MODIFIED: TANPA LOOP TUNGGU)
# ===============================
check_authorization() {
    log_info "Memeriksa status authorization (tanpa menunggu loop)..."
    
    local node_id=$(zerotier-cli info 2>/dev/null | awk '{print $3}')
    local network_status=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID")
    
    if echo "$network_status" | grep -q "OK"; then
        log_ok "Node sudah ter-authorize dan mendapat IP assignment."
        return 0 # Authorized
    elif echo "$network_status" | grep -qE "ACCESS_DENIED|REQUESTING_CONFIGURATION"; then
        log_warn "Node BELUM di-authorize/masih request konfigurasi di ZeroTier Central!"
        log_warn "LANJUTKAN instalasi Exit Node. Harap AUTHORIZE Node ID berikut secara manual:"
        log_warn "Node ID: $node_id"
        return 1 # Not Authorized, but continue
    else
        log_error "Status network tidak diketahui. Node ID: $node_id"
        return 1
    fi
}

# ===============================
#  TUNGGU INTERFACE ZT AKTIF
# ===============================
wait_for_zt_interface() {
    log_info "Menunggu interface ZeroTier aktif dan mendapatkan IP..."
    local start_time=$(date +%s)
    local elapsed_time=0
    
    while ! zerotier-cli listnetworks 2>/dev/null | grep -q "$NETWORK_ID.*OK"; do
        sleep "$ZT_WAIT_INTERVAL"
        elapsed_time=$(( $(date +%s) - start_time ))
        if [ "$elapsed_time" -ge "$ZT_WAIT_TIMEOUT" ]; then
            log_warn "Timeout ($ZT_WAIT_TIMEOUT detik) menunggu interface ZT. Lanjutkan tanpa IP ZT."
            return 1
        fi
        printf "\r[INFO] Menunggu IP ZT (%d/%d detik)..." "$elapsed_time" "$ZT_WAIT_TIMEOUT"
    done
    
    echo "" # Newline setelah progress
    log_ok "Interface ZeroTier aktif dan IP berhasil didapatkan."
    return 0
}

# ===============================
#  AKTIFKAN IP FORWARDING
# ===============================
enable_ip_forwarding() {
    log_info "Mengaktifkan IP Forwarding..."
    
    # Cek status sebelum mengganti
    local current_state=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    
    if [ "$current_state" -ne 1 ]; then
        if echo "net.ipv4.ip_forward=1" | tee /etc/sysctl.d/99-ipforward.conf > /dev/null; then
            sysctl -p /etc/sysctl.d/99-ipforward.conf > /dev/null
            log_ok "IP Forwarding diaktifkan."
        else
            log_error "Gagal mengaktifkan IP Forwarding."
        fi
    else
        log_ok "IP Forwarding sudah aktif."
    fi
}

# ===============================
#  KONFIGURASI RP_FILTER (Pencegahan Reverse Path Filtering)
# ===============================
configure_rp_filter() {
    log_info "Mengatur rp_filter agar Exit Node berfungsi..."

    # Menonaktifkan rp_filter untuk semua interface (mode 0)
    # Ini diperlukan agar ZeroTier dapat merutekan traffic
    if echo "net.ipv4.conf.all.rp_filter=0" | tee /etc/sysctl.d/99-rpfilter-zt.conf > /dev/null; then
        echo "net.ipv4.conf.default.rp_filter=0" | tee -a /etc/sysctl.d/99-rpfilter-zt.conf > /dev/null
        
        # Terapkan konfigurasi
        if sysctl -p /etc/sysctl.d/99-rpfilter-zt.conf > /dev/null; then
            log_ok "rp_filter diatur ke mode 0 (dinonaktifkan)."
        else
            log_error "Gagal menerapkan rp_filter. Coba atur manual: sysctl -w net.ipv4.conf.all.rp_filter=0"
        fi
    else
        log_error "Gagal menulis konfigurasi rp_filter."
    fi
}

# ===============================
#  SETUP NAT (iptables)
# ===============================
setup_nat() {
    log_info "Mengatur NAT (Masquerading) untuk Exit Node..."
    
    local ZT_INTERFACE=$(ip a | grep "zt" | grep "UP" | awk -F: '{print $2}' | tr -d ' ' | head -n 1)
    local PUBLIC_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
    
    if [ -z "$ZT_INTERFACE" ] || [ -z "$PUBLIC_INTERFACE" ]; then
        log_error "Gagal mendeteksi interface ZT atau Public. Lewati NAT."
        log_warn "ZT Interface: $ZT_INTERFACE, Public Interface: $PUBLIC_INTERFACE"
        return 1
    fi
    
    log_info "Interface ZT: $ZT_INTERFACE, Interface Publik: $PUBLIC_INTERFACE"
    
    # 1. Hapus semua aturan NAT Masquerade sebelumnya yang mungkin ada
    iptables -t nat -D POSTROUTING -o "$PUBLIC_INTERFACE" -j MASQUERADE 2>/dev/null
    
    # 2. Tambahkan aturan NAT Masquerade
    if iptables -t nat -A POSTROUTING -o "$PUBLIC_INTERFACE" -j MASQUERADE; then
        log_ok "NAT Masquerading berhasil diatur (Out: $PUBLIC_INTERFACE)."
    else
        log_error "Gagal mengatur NAT Masquerading!"
        return 1
    fi
    
    # 3. Izinkan Forwarding Traffic dari ZT ke Public (WAJIB)
    # Hapus dulu jika ada
    iptables -D FORWARD -i "$ZT_INTERFACE" -o "$PUBLIC_INTERFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$PUBLIC_INTERFACE" -o "$ZT_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

    # Tambahkan baru
    iptables -A FORWARD -i "$ZT_INTERFACE" -o "$PUBLIC_INTERFACE" -j ACCEPT
    iptables -A FORWARD -i "$PUBLIC_INTERFACE" -o "$ZT_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    log_ok "Aturan FORWARDING diatur."
    
    # Simpan aturan
    save_iptables_rules
    
    return 0
}

# ===============================
#  SIMPAN ATURAN IP TABLES
# ===============================
save_iptables_rules() {
    log_info "Menyimpan aturan iptables (persisten)..."
    
    if command -v iptables-save &>/dev/null; then
        # Coba simpan menggunakan iptables-persistent (Debian/Ubuntu)
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
            log_ok "Aturan iptables disimpan dengan netfilter-persistent."
        elif command -v iptables-restore &>/dev/null; then
            # Alternatif untuk RHEL/CentOS atau jika netfilter-persistent tidak ada
            if [ -f /etc/sysconfig/iptables ]; then
                iptables-save > /etc/sysconfig/iptables
                log_ok "Aturan iptables disimpan di /etc/sysconfig/iptables."
            else
                log_warn "Tool persistent iptables tidak ditemukan. Aturan mungkin hilang saat reboot."
            fi
        else
            log_warn "Tool persistent iptables tidak ditemukan. Aturan mungkin hilang saat reboot."
        fi
    else
        log_error "Perintah 'iptables-save' tidak ditemukan. Gagal menyimpan."
    fi
}

# ===============================
#  KONFIGURASI CLIENT ZT
# ===============================
configure_client_settings() {
    log_info "Mengkonfigurasi Moon Orbit..."
    
    # Menambahkan jeda singkat untuk stabilitas daemon ZT, mengurangi error format ID
    sleep 3
    log_info "Jeda 3 detik untuk memastikan ZeroTier stabil sebelum cek Moon..."

    # 1. Orbit Moon
    # Menambahkan 2>/dev/null pada zerotier-cli get untuk menekan error format ID.
    local MOON_FILE="\$(zerotier-cli get "\$MOON_ID" 2>/dev/null | grep MOON | awk '{print \$2}' | head -n 1)"
    
    if [ "\$MOON_FILE" == "null" ] || [ -z "\$MOON_FILE" ]; then
        log_info "Moon belum di-orbit. Mencoba orbit ulang via Updater Script..."
        # Panggil updater script secara manual untuk mendapatkan config Moon yang benar
        \$UPDATER_SCRIPT 
        log_ok "Proses Moon Orbit dilakukan via Moon Updater Script."
    else
        log_ok "Moon (\$MOON_ID) sudah di-orbit."
    fi
}

# ===============================
#  SYSTEMD SERVICE (IDEMPOTENT)
# ===============================
create_systemd_service() {
    log_info "Membuat service systemd untuk menjamin NAT tetap aktif..."
    
    cat > "$SERVICE_FILE" <<EOT3
[Unit]
Description=ZeroTier Exit Node Setup
After=network-online.target zerotier-one.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH -postboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOT3

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable zt-exitnode.service >/dev/null 2>&1
    
    # Jalankan service untuk menerapkan NAT jika belum berjalan
    if ! systemctl is-active --quiet zt-exitnode.service; then
        systemctl start zt-exitnode.service >/dev/null 2>&1
        log_ok "Service zt-exitnode diaktifkan dan dijalankan."
    else
        log_ok "Service zt-exitnode sudah aktif."
        systemctl restart zt-exitnode.service >/dev/null 2>&1
    fi
}

# ------------------------------------------------------------------
# FUNGSI MOON UPDATER OTOMATIS (V4.0 - DNS/HTTPS FIX)
# ------------------------------------------------------------------
install_moon_updater() {
    log_info "Menginstal Moon Updater Script (V4.0 - Stable DNS/HTTPS Fix)..."
    
    # 1. Pastikan dependensi terinstal (jq dan wget)
    if ! command -v jq &>/dev/null; then
        log_info "Menginstal jq (JSON processor)..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL jq >/dev/null 2>&1
        log_ok "jq berhasil diinstal."
    fi
    if ! command -v wget &>/dev/null; then
        log_info "Menginstal wget..."
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL wget >/dev/null 2>&1
        log_ok "wget berhasil diinstal."
    fi

    # 2. Tulis Script Updater (NEW LOGIC)
    cat > "$UPDATER_SCRIPT" <<EOT4
#!/bin/bash
# Script Updater Moon Server ZeroTier (Client Side)
# V4.0 - Menggunakan URL Publik Stabil (HTTPS/Cloudflare)
# Dijalankan via Cron Job

# --- KONFIGURASI OTOMATIS ---
MOON_ID="$MOON_ID"
MOON_CONFIG_URL="$MOON_CONFIG_URL" 
LOG_FILE="$LOG_FILE"
CONFIG_FILE="moon.json"
ZT_HOME="/var/lib/zerotier-one"
# --------------------------

log() { echo "\$(date +'%Y-%m-%d %H:%M:%S') \$1" >> "\$LOG_FILE"; }

# Check ZeroTier service
if ! systemctl is-active --quiet zerotier-one; then exit 0; fi

# Check dependencies
if ! command -v jq &>/dev/null || ! command -v wget &>/dev/null; then
    log "[ERROR] Dependensi (jq/wget) hilang."
    exit 1
fi

MOON_FILE="/tmp/downloaded_\$CONFIG_FILE"

# 1. Unduh Moon Config dari URL Publik Stabil
log "[INFO] Mengunduh Moon Config dari \$MOON_CONFIG_URL..."

# Menggunakan wget dengan no-check-certificate untuk kompatibilitas HTTPS
if ! /usr/bin/wget -q --no-check-certificate -O "\$MOON_FILE" "\$MOON_CONFIG_URL"; then
    log "[ERROR] Gagal mengunduh Moon Config dari \$MOON_CONFIG_URL."
    rm -f "\$MOON_FILE"
    exit 1
fi

# 2. Ekstrak Stable Endpoint Baru
NEW_ENDPOINT=\$(/usr/bin/jq -r '.roots[0].stableEndpoints[0]' "\$MOON_FILE" 2>/dev/null)

if [ -z "\$NEW_ENDPOINT" ] || [ "\$NEW_ENDPOINT" == "null" ]; then
    log "[ERROR] Gagal mendapatkan Stable Endpoint (menggunakan JQ). File config tidak valid."
    rm -f "\$MOON_FILE"
    exit 1
fi

# 3. Bandingkan dengan Endpoint Saat Ini (Mencegah restart yang tidak perlu)
CURRENT_PEER_INFO=\$(/usr/sbin/zerotier-cli listpeers | grep "\$MOON_ID" | grep MOON)

if echo "\$CURRENT_PEER_INFO" | grep -q "\$NEW_ENDPOINT"; then
    log "[OK] Endpoint (\$NEW_ENDPOINT) sudah terdaftar. Tidak ada perubahan."
else
    log "[WARNING] Endpoint baru terdeteksi: \$NEW_ENDPOINT. Memulai proses Orbit ulang."

    # Perintah utama ZeroTier: orbit <Moon ID> <Stable Endpoint>
    /usr/sbin/zerotier-cli orbit "\$MOON_ID" "\$NEW_ENDPOINT"
    sleep 3
    systemctl restart zerotier-one
    
    log "[SUCCESS] Controller di-orbit ulang ke \$NEW_ENDPOINT dan ZeroTier di-restart."
fi

rm -f "\$MOON_FILE"
exit 0
EOT4
    # 3. Berikan izin eksekusi
    chmod +x "$UPDATER_SCRIPT"

    # 4. Setup Cron Job
    if command -v crontab &>/dev/null; then
        if ! crontab -l 2>/dev/null | grep -q "$UPDATER_SCRIPT"; then
            (crontab -l 2>/dev/null; echo "*/5 * * * * $UPDATER_SCRIPT") | crontab -
            log_ok "Cron job untuk Moon Updater diinstal."
        else
            log_ok "Cron job untuk Moon Updater sudah ada."
        fi
    fi
}

# ------------------------------------------------------------------
# PROGRAM UTAMA CLIENT
# ------------------------------------------------------------------
main() {
    echo "========================================="
    echo "  ZERO TIER EXIT NODE: Instalasi di background"
    echo "========================================="
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
    
    # 4. Instalasi Updater (dengan FULL DYNAMIC IP FIX)
    install_moon_updater
    
    # 5. Konfigurasi Sistem
    enable_ip_forwarding
    configure_rp_filter
    setup_nat
    
    # 6. Konfigurasi Client ZT
    if [ $auth_result -eq 0 ]; then
        # Hanya tunggu interface aktif jika node sudah di-authorize
        wait_for_zt_interface
        configure_client_settings
    else
        log_warn "Client settings (rute Exit Node) akan diatur setelah node di-authorize. Silakan coba jalankan ulang script ini setelah authorize."
    fi
    
    # 7. Buat Systemd Service
    create_systemd_service
    
    log_ok "KONFIGURASI EXIT NODE SELESAI. Cek status ZeroTier dan log updater."
}

# Execute main program
if [ "$1" == "-postboot" ]; then
    # Jika dipanggil dari systemd, hanya jalankan NAT setup dan restart updater
    enable_ip_forwarding
    configure_rp_filter
    setup_nat
    save_iptables_rules
    /usr/local/bin/zt-moon-updater.sh
else
    main "$@"
fi
