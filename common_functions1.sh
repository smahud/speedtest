#!/usr/bin/env bash
###############################################################################
# common_functions1.sh
#
# Pustaka fungsi bersama untuk installer Speedtest OoklaServer.
#
# Tanggung jawab utama:
#   - Menentukan CONFIG_PATH (lokasi data.ini) dan BASE_DIR secara dinamis.
#   - Mem-parsing & memvalidasi data.ini (tanpa "source" liar).
#   - Mendeteksi OS, package manager, dan init system.
#   - Menyediakan helper logging, masking token, dan path.
#
# CATATAN PENTING:
#   - Tidak ada satu pun path yang di-hardcode ke /root/.
#   - Semua path relatif aplikasi mengikuti $BASE_DIR (lokasi data.ini).
#   - File ini didesain agar aman di-"source" berkali-kali (idempotent).
###############################################################################

# Hindari double-init bila di-source berkali-kali.
if [ -n "${SPEEDTEST_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
SPEEDTEST_COMMON_LOADED=1

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
# Warna hanya dipakai bila output adalah terminal interaktif.
if [ -t 1 ]; then
    C_RESET="\033[0m"; C_INFO="\033[0;36m"; C_OK="\033[0;32m"
    C_WARN="\033[0;33m"; C_ERR="\033[0;31m"
else
    C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

# File log opsional. Akan di-set oleh init_paths() ke $BASE_DIR/install.log.
LOG_FILE="${LOG_FILE:-}"

_log_write() {
    # $1 = pesan lengkap sudah berisi prefix
    if [ -n "$LOG_FILE" ]; then
        # Jangan biarkan kegagalan menulis log menghentikan script.
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info()  { printf "${C_INFO}[INFO]${C_RESET} %s\n" "$1"; _log_write "[INFO] $1"; }
log_ok()    { printf "${C_OK}[OK]${C_RESET} %s\n" "$1";    _log_write "[OK] $1"; }
log_warn()  { printf "${C_WARN}[WARN]${C_RESET} %s\n" "$1" >&2; _log_write "[WARN] $1"; }
log_error() { printf "${C_ERR}[ERROR]${C_RESET} %s\n" "$1" >&2; _log_write "[ERROR] $1"; }

# Keluar dengan pesan error yang jelas.
die() {
    log_error "$1"
    exit "${2:-1}"
}

# Garis pemisah ringan (pengganti print_hash lama yang berisi sleep).
print_hash() {
    # Mempertahankan nama fungsi lama untuk kompatibilitas, tapi TANPA sleep
    # agar instalasi berjalan cepat & non-interaktif.
    local count="${1:-30}"
    local line=""
    local i=1
    while [ "$i" -le "$count" ]; do
        line="${line}#"
        i=$((i + 1))
    done
    printf '%s\n' "$line"
}

# -----------------------------------------------------------------------------
# Masking token (keamanan)
# -----------------------------------------------------------------------------
# Menyamarkan token Cloudflare agar tidak pernah tercetak penuh ke log/output.
mask_secret() {
    local s="$1"
    local n=${#s}
    if [ "$n" -le 8 ]; then
        printf '********'
    else
        printf '%s********%s' "${s:0:4}" "${s: -4}"
    fi
}

# -----------------------------------------------------------------------------
# Penentuan CONFIG_PATH & BASE_DIR
# -----------------------------------------------------------------------------
# Mengembalikan path absolut dari direktori tempat file berada.
_abs_dir() {
    ( cd "$(dirname "$1")" >/dev/null 2>&1 && pwd )
}

# Direktori tempat install.sh / script utama berada (bukan CWD).
# Memakai variabel SPEEDTEST_SCRIPT_DIR bila sudah di-export oleh install.sh.
script_dir() {
    if [ -n "${SPEEDTEST_SCRIPT_DIR:-}" ]; then
        printf '%s' "$SPEEDTEST_SCRIPT_DIR"
        return 0
    fi
    # Fallback: lokasi file common ini.
    _abs_dir "${BASH_SOURCE[0]:-$0}"
}

# Mencari data.ini dengan prioritas:
#   1) argumen pertama (jika diberikan)
#   2) current working directory (tempat user menjalankan command)
#   3) direktori tempat install.sh berada
# Hasil disimpan ke variabel global CONFIG_PATH & BASE_DIR.
resolve_config_path() {
    local arg="${1:-}"
    local candidate=""

    if [ -n "$arg" ]; then
        if [ -d "$arg" ]; then
            candidate="$arg/data.ini"
        else
            candidate="$arg"
        fi
        if [ ! -f "$candidate" ]; then
            die "data.ini tidak ditemukan pada path yang diberikan: '$arg'"
        fi
    else
        local sdir
        sdir="$(script_dir)"
        if [ -f "$PWD/data.ini" ]; then
            candidate="$PWD/data.ini"
        elif [ -f "$sdir/data.ini" ]; then
            candidate="$sdir/data.ini"
        else
            log_error "data.ini tidak ditemukan."
            log_error "Cari prioritas: (1) argumen, (2) CWD '$PWD', (3) '$sdir'."
            log_error "Contoh penggunaan: ./install.sh /path/ke/data.ini"
            exit 1
        fi
    fi

    # Normalisasi ke path absolut.
    CONFIG_PATH="$(_abs_dir "$candidate")/$(basename "$candidate")"
    BASE_DIR="$(_abs_dir "$candidate")"
    export CONFIG_PATH BASE_DIR
}

# Menetapkan seluruh path turunan berdasarkan BASE_DIR.
# Dipanggil setelah resolve_config_path().
init_paths() {
    [ -n "${BASE_DIR:-}" ] || die "init_paths() dipanggil sebelum BASE_DIR diset."

    # File log instalasi.
    LOG_FILE="$BASE_DIR/install.log"
    export LOG_FILE

    # Lokasi instalasi OoklaServer & script-nya (mengikuti BASE_DIR).
    OOKLA_DIR="$BASE_DIR"
    OOKLA_SCRIPT="$BASE_DIR/ooklaserver.sh"
    OOKLA_BIN="$BASE_DIR/OoklaServer"
    OOKLA_PROPERTIES="$BASE_DIR/OoklaServer.properties"
    OOKLA_PIDFILE="$BASE_DIR/OoklaServer.pid"

    # File temporer aplikasi (mengikuti BASE_DIR, bukan /tmp global bila bisa).
    TMP_DIR="$BASE_DIR/tmp"

    # Direktori source script (lokasi bagianX.sh).
    SCRIPT_DIR="$(script_dir)"

    # Direktori state untuk menyimpan info instalasi (BASE_DIR).
    STATE_FILE="$BASE_DIR/.speedtest-install.state"

    export OOKLA_DIR OOKLA_SCRIPT OOKLA_BIN OOKLA_PROPERTIES OOKLA_PIDFILE
    export TMP_DIR SCRIPT_DIR STATE_FILE

    mkdir -p "$TMP_DIR" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Parsing & validasi data.ini
# -----------------------------------------------------------------------------
# Membaca key=value dari data.ini secara AMAN (tanpa eval/source).
# Hanya key yang dikenal yang diambil. Komentar (#) & baris kosong diabaikan.
ini_get() {
    local key="$1"
    local file="${2:-$CONFIG_PATH}"
    # Selalu kembalikan 0 (nilai kosong = key tidak ada) supaya aman dipakai
    # dalam command substitution di bawah 'set -e'.
    [ -f "$file" ] || { printf ''; return 0; }
    # Ambil baris key=... terakhir, buang spasi & tanda kutip.
    local raw
    raw="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n1)"
    [ -n "$raw" ] || { printf ''; return 0; }
    # Hilangkan bagian sebelum '=' pertama.
    local val="${raw#*=}"
    # Trim spasi depan/belakang.
    val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$val" in
        \"*)
            # Value diawali kutip ganda: ambil isi di antara kutip pertama & kedua.
            val="${val#\"}"          # buang kutip pembuka
            val="${val%%\"*}"        # ambil sampai kutip penutup pertama
            ;;
        \'*)
            val="${val#\'}"
            val="${val%%\'*}"
            ;;
        *)
            # Tanpa kutip: buang inline comment (#...) lalu trim.
            val="${val%%#*}"
            val="$(printf '%s' "$val" | sed -e 's/[[:space:]]*$//')"
            ;;
    esac
    printf '%s' "$val"
}

# Normalisasi jawaban Ya/Tidak -> "Ya" atau "Tidak".
normalize_yesno() {
    local v
    v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$v" in
        ya|yes|y|true|1)  printf 'Ya' ;;
        tidak|no|n|false|0|"") printf 'Tidak' ;;
        *) printf '%s' "$1" ;;  # nilai tak dikenal dikembalikan apa adanya utk divalidasi
    esac
}

# Validasi format domain sederhana (label.label, alfanumerik + tanda hubung).
is_valid_domain() {
    printf '%s' "$1" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}

# Membaca & memvalidasi seluruh data.ini, lalu meng-export variabel global.
load_and_validate_config() {
    [ -f "$CONFIG_PATH" ] || die "data.ini tidak ditemukan di: $CONFIG_PATH"

    log_info "Membaca konfigurasi dari: $CONFIG_PATH"

    ApakahDomainWildcard="$(normalize_yesno "$(ini_get ApakahDomainWildcard)")"
    ApakahPakaiCloudflare="$(normalize_yesno "$(ini_get ApakahPakaiCloudflare)")"
    Domain="$(ini_get Domain)"
    APICloudFlare="$(ini_get APICloudFlare)"
    EmailCloudFlare="$(ini_get EmailCloudFlare)"
    RegisteredSpeedtestURL="$(ini_get RegisteredSpeedtestURL)"

    # --- ZeroTier Config ---
    ZeroTierNetworkID="$(ini_get ZeroTierNetworkID)"
    ZeroTierMoonID="$(ini_get ZeroTierMoonID)"
    ZeroTierMoonConfigURL="$(ini_get ZeroTierMoonConfigURL)"

    # Opsional: kontrol fitur ZeroTier dari data.ini (default mengikuti perilaku lama: Ya).
    local _zt_raw
    _zt_raw="$(ini_get AktifkanZeroTier)"
    if [ -z "$_zt_raw" ]; then
        AktifkanZeroTier="Ya"   # key tidak ada -> default Ya
    else
        AktifkanZeroTier="$(normalize_yesno "$_zt_raw")"
    fi

    local errors=0

    # --- Validasi field wajib umum ---
    if [ -z "$Domain" ]; then
        log_error "Field 'Domain' wajib diisi di data.ini."
        errors=$((errors + 1))
    elif ! is_valid_domain "$Domain"; then
        log_error "Format 'Domain' tidak valid: '$Domain' (contoh: example.com)."
        errors=$((errors + 1))
    fi

    if [ -z "$RegisteredSpeedtestURL" ]; then
        log_error "Field 'RegisteredSpeedtestURL' wajib diisi di data.ini."
        errors=$((errors + 1))
    elif ! is_valid_domain "$RegisteredSpeedtestURL"; then
        log_error "Format 'RegisteredSpeedtestURL' tidak valid: '$RegisteredSpeedtestURL' (contoh: speedtest.example.com)."
        errors=$((errors + 1))
    fi

    case "$ApakahDomainWildcard" in
        Ya|Tidak) : ;;
        *) log_error "Field 'ApakahDomainWildcard' harus 'Ya' atau 'Tidak' (sekarang: '$ApakahDomainWildcard')."; errors=$((errors + 1)) ;;
    esac

    case "$ApakahPakaiCloudflare" in
        Ya|Tidak) : ;;
        *) log_error "Field 'ApakahPakaiCloudflare' harus 'Ya' atau 'Tidak' (sekarang: '$ApakahPakaiCloudflare')."; errors=$((errors + 1)) ;;
    esac

    # --- Validasi khusus Cloudflare ---
    if [ "$ApakahPakaiCloudflare" = "Ya" ]; then
        if [ -z "$APICloudFlare" ] || [ "$APICloudFlare" = "ISI_TOKEN_CLOUDFLARE_DI_SINI" ]; then
            log_error "Field 'APICloudFlare' wajib diisi token Cloudflare yang valid saat ApakahPakaiCloudflare=Ya."
            errors=$((errors + 1))
        elif [ ${#APICloudFlare} -lt 20 ]; then
            log_error "Token Cloudflare terlihat terlalu pendek (panjang: ${#APICloudFlare}). Periksa kembali."
            errors=$((errors + 1))
        fi
    fi

    if [ "$errors" -gt 0 ]; then
        die "Ditemukan $errors error pada data.ini. Perbaiki dulu sebelum melanjutkan."
    fi

    export ApakahDomainWildcard ApakahPakaiCloudflare Domain APICloudFlare \
           EmailCloudFlare RegisteredSpeedtestURL AktifkanZeroTier \
           ZeroTierNetworkID ZeroTierMoonID ZeroTierMoonConfigURL

    # Ringkasan konfigurasi (token DISAMARKAN).
    log_ok "Konfigurasi valid:"
    log_info "  Domain                 : $Domain"
    log_info "  RegisteredSpeedtestURL : $RegisteredSpeedtestURL"
    log_info "  Wildcard               : $ApakahDomainWildcard"
    log_info "  Cloudflare             : $ApakahPakaiCloudflare"
    if [ "$ApakahPakaiCloudflare" = "Ya" ]; then
        log_info "  Token Cloudflare       : $(mask_secret "$APICloudFlare")"
    fi
    log_info "  ZeroTier Exit Node     : $AktifkanZeroTier"
}

# -----------------------------------------------------------------------------
# Deteksi OS / package manager / init system
# -----------------------------------------------------------------------------
detect_os() {
    OS_ID=""; OS_FAMILY=""; PKG_MGR=""
    PKG_UPDATE=""; PKG_INSTALL=""

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        local like="${ID_LIKE:-}"

        if printf '%s %s' "$OS_ID" "$like" | grep -qiE 'debian|ubuntu'; then
            OS_FAMILY="debian"
        elif printf '%s %s' "$OS_ID" "$like" | grep -qiE 'rhel|fedora|centos|rocky|almalinux'; then
            OS_FAMILY="rhel"
        elif printf '%s %s' "$OS_ID" "$like" | grep -qiE 'alpine'; then
            OS_FAMILY="alpine"
        elif printf '%s %s' "$OS_ID" "$like" | grep -qiE 'suse'; then
            OS_FAMILY="suse"
        fi
    fi

    # Fallback berbasis file penanda.
    if [ -z "$OS_FAMILY" ]; then
        if [ -f /etc/alpine-release ]; then OS_FAMILY="alpine"
        elif [ -f /etc/debian_version ]; then OS_FAMILY="debian"
        elif [ -f /etc/redhat-release ]; then OS_FAMILY="rhel"
        fi
    fi

    # Pilih package manager nyata yang tersedia.
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        PKG_UPDATE="apt-get update -y"
        PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"
        PKG_UPDATE="dnf makecache -y"
        PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"
        PKG_UPDATE="yum makecache -y"
        PKG_INSTALL="yum install -y"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add --no-cache"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"
        PKG_UPDATE="zypper refresh"
        PKG_INSTALL="zypper install -y"
    fi

    [ -n "$OS_FAMILY" ] || OS_FAMILY="unknown"
    [ -n "$PKG_MGR" ] || die "Tidak dapat menemukan package manager yang didukung (apt/dnf/yum/apk/zypper)."

    export OS_ID OS_FAMILY PKG_MGR PKG_UPDATE PKG_INSTALL
    log_info "OS terdeteksi: family='$OS_FAMILY' id='$OS_ID' pkg='$PKG_MGR'"
}

# Wrapper instalasi paket non-interaktif lintas distro.
pkg_install() {
    # $@ = daftar paket
    eval "$PKG_INSTALL $*"
}

pkg_update() {
    eval "$PKG_UPDATE" >/dev/null 2>&1 || log_warn "Gagal memperbarui index paket (lanjut)."
}

# Deteksi init system.
detect_init() {
    INIT_SYSTEM="none"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    fi
    export INIT_SYSTEM
    log_info "Init system terdeteksi: $INIT_SYSTEM"
}

# -----------------------------------------------------------------------------
# System Checks
# -----------------------------------------------------------------------------
check_resources() {
    log_info "Memeriksa sumber daya sistem..."
    # Minimal RAM 512MB disarankan untuk kelancaran.
    local mem_total
    mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    if [ "$mem_total" -gt 0 ] && [ "$mem_total" -lt 480 ]; then
        log_warn "RAM sistem rendah ($mem_total MB). OoklaServer mungkin tidak stabil."
    fi

    # Cek sisa disk di BASE_DIR.
    local disk_free
    disk_free=$(df -m "$BASE_DIR" | awk 'NR==2 {print $4}' || echo 0)
    if [ "$disk_free" -gt 0 ] && [ "$disk_free" -lt 100 ]; then
        log_error "Sisa penyimpanan terlalu sedikit ($disk_free MB). Butuh minimal 100MB."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Firewall Helpers
# -----------------------------------------------------------------------------
open_ports() {
    log_info "Membuka port 80, 443, 8080, 5060 (TCP/UDP)..."
    if command_exists ufw; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 8080/tcp >/dev/null 2>&1 || true
        ufw allow 5060/tcp >/dev/null 2>&1 || true
        ufw allow 8080/udp >/dev/null 2>&1 || true
        ufw allow 5060/udp >/dev/null 2>&1 || true
    elif command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port={80/tcp,443/tcp,8080/tcp,5060/tcp,8080/udp,5060/udp} >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command_exists iptables; then
        iptables -I INPUT -p tcp --match multiport --dports 80,443,8080,5060 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --match multiport --dports 8080,5060 -j ACCEPT 2>/dev/null || true
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
