#!/usr/bin/env bash
###############################################################################
# common_functions1.sh
#
# Pustaka fungsi bersama untuk installer Speedtest OoklaServer.
# Versi: 7.0 (Massive Final Optimization)
###############################################################################

if [ -n "${SPEEDTEST_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
SPEEDTEST_COMMON_LOADED=1

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET="\033[0m"; C_INFO="\033[0;36m"; C_OK="\033[0;32m"
    C_WARN="\033[0;33m"; C_ERR="\033[0;31m"
else
    C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

LOG_FILE="${LOG_FILE:-}"

_log_write() {
    if [ -n "$LOG_FILE" ]; then
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info()  { printf "${C_INFO}[INFO]${C_RESET} %s\n" "$1"; _log_write "[INFO] $1"; }
log_ok()    { printf "${C_OK}[OK]${C_RESET} %s\n" "$1";    _log_write "[OK] $1"; }
log_warn()  { printf "${C_WARN}[WARN]${C_RESET} %s\n" "$1" >&2; _log_write "[WARN] $1"; }
log_error() { printf "${C_ERR}[ERROR]${C_RESET} %s\n" "$1" >&2; _log_write "[ERROR] $1"; }

die() {
    log_error "$1"
    exit "${2:-1}"
}

print_hash() {
    local count="${1:-30}"
    local line=""
    local i=1
    while [ "$i" -le "$count" ]; do
        line="${line}#"
        i=$((i + 1))
    done
    printf '%s\n' "$line"
}

mask_secret() {
    local s="$1"
    local n=${#s}
    if [ "$n" -le 8 ]; then
        printf '********'
    else
        printf '%s********%s' "${s:0:4}" "${s: -4}"
    fi
}

_abs_dir() {
    ( cd "$(dirname "$1")" >/dev/null 2>&1 && pwd )
}

script_dir() {
    if [ -n "${SPEEDTEST_SCRIPT_DIR:-}" ]; then
        printf '%s' "$SPEEDTEST_SCRIPT_DIR"
        return 0
    fi
    _abs_dir "${BASH_SOURCE[0]:-$0}"
}

resolve_config_path() {
    local arg="${1:-}"
    local candidate=""
    if [ -n "$arg" ]; then
        [ -d "$arg" ] && candidate="$arg/data.ini" || candidate="$arg"
        [ -f "$candidate" ] || die "data.ini tidak ditemukan: '$arg'"
    else
        local sdir="$(script_dir)"
        if [ -f "$PWD/data.ini" ]; then candidate="$PWD/data.ini"
        elif [ -f "$sdir/data.ini" ]; then candidate="$sdir/data.ini"
        else die "data.ini tidak ditemukan. Gunakan: ./install.sh /path/ke/data.ini"; fi
    fi
    CONFIG_PATH="$(_abs_dir "$candidate")/$(basename "$candidate")"
    BASE_DIR="$(_abs_dir "$candidate")"
    export CONFIG_PATH BASE_DIR
}

init_paths() {
    [ -n "${BASE_DIR:-}" ] || die "init_paths() gagal: BASE_DIR belum diset."
    LOG_FILE="$BASE_DIR/install.log"
    OOKLA_DIR="$BASE_DIR"
    OOKLA_SCRIPT="$BASE_DIR/ooklaserver.sh"
    OOKLA_BIN="$BASE_DIR/OoklaServer"
    OOKLA_PROPERTIES="$BASE_DIR/OoklaServer.properties"
    OOKLA_PIDFILE="$BASE_DIR/OoklaServer.pid"
    TMP_DIR="$BASE_DIR/tmp"
    SCRIPT_DIR="$(script_dir)"
    STATE_FILE="$BASE_DIR/.speedtest-install.state"
    export LOG_FILE OOKLA_DIR OOKLA_SCRIPT OOKLA_BIN OOKLA_PROPERTIES OOKLA_PIDFILE TMP_DIR SCRIPT_DIR STATE_FILE
    mkdir -p "$TMP_DIR" 2>/dev/null || true
}

ini_get() {
    local key="$1"
    local file="${2:-$CONFIG_PATH}"
    [ -f "$file" ] || return 0
    local raw="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n1)"
    [ -n "$raw" ] || return 0
    local val="${raw#*=}"
    val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$val" in
        \"*) val="${val#\"}"; val="${val%%\"*}" ;;
        \'*) val="${val#\'}"; val="${val%%\'*}" ;;
        *) val="${val%%#*}"; val="$(printf '%s' "$val" | sed -e 's/[[:space:]]*$//')" ;;
    esac
    printf '%s' "$val"
}

normalize_yesno() {
    local v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$v" in
        ya|yes|y|true|1) printf 'Ya' ;;
        *) printf 'Tidak' ;;
    esac
}

load_and_validate_config() {
    [ -f "$CONFIG_PATH" ] || die "data.ini hilang: $CONFIG_PATH"
    log_info "Memvalidasi konfigurasi..."
    
    ApakahDomainWildcard="$(normalize_yesno "$(ini_get ApakahDomainWildcard)")"
    ApakahPakaiCloudflare="$(normalize_yesno "$(ini_get ApakahPakaiCloudflare)")"
    Domain="$(ini_get Domain)"
    APICloudFlare="$(ini_get APICloudFlare)"
    EmailCloudFlare="$(ini_get EmailCloudFlare)"
    RegisteredSpeedtestURL="$(ini_get RegisteredSpeedtestURL)"
    ZeroTierNetworkID="$(ini_get ZeroTierNetworkID)"
    ZeroTierMoonID="$(ini_get ZeroTierMoonID)"
    ZeroTierMoonConfigURL="$(ini_get ZeroTierMoonConfigURL)"
    AktifkanZeroTier="$(normalize_yesno "$(ini_get AktifkanZeroTier)")"

    # Set Defaults for ZeroTier if empty
    [ -z "$ZeroTierNetworkID" ] && ZeroTierNetworkID="72ff30f9733a82d9"
    [ -z "$ZeroTierMoonID" ] && ZeroTierMoonID="72ff30f973"
    [ -z "$ZeroTierMoonConfigURL" ] && ZeroTierMoonConfigURL="https://moon.zerotier.my.id/moon.json"

    [ -z "$Domain" ] && die "Domain wajib diisi di data.ini."
    [ -z "$RegisteredSpeedtestURL" ] && die "RegisteredSpeedtestURL wajib diisi di data.ini."
    
    export ApakahDomainWildcard ApakahPakaiCloudflare Domain APICloudFlare \
           EmailCloudFlare RegisteredSpeedtestURL ZeroTierNetworkID \
           ZeroTierMoonID ZeroTierMoonConfigURL AktifkanZeroTier

    log_ok "Konfigurasi valid (Domain: $Domain, ZeroTier: $AktifkanZeroTier)"
}

detect_os() {
    OS_ID=""; OS_FAMILY="unknown"; PKG_MGR=""; PKG_UPDATE=""; PKG_INSTALL=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        local like="${ID_LIKE:-}"
        if printf '%s %s' "$OS_ID" "$like" | grep -qiE 'debian|ubuntu'; then OS_FAMILY="debian"
        elif printf '%s %s' "$OS_ID" "$like" | grep -qiE 'rhel|fedora|centos|rocky|almalinux'; then OS_FAMILY="rhel"
        elif [ "$OS_ID" = "alpine" ]; then OS_FAMILY="alpine"
        fi
    fi
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"; PKG_UPDATE="apt-get update -y"; PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"; PKG_UPDATE="dnf makecache -y"; PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"; PKG_UPDATE="yum makecache -y"; PKG_INSTALL="yum install -y"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"; PKG_UPDATE="apk update"; PKG_INSTALL="apk add --no-cache"
    fi
    export OS_ID OS_FAMILY PKG_MGR PKG_UPDATE PKG_INSTALL
    log_info "Terdeteksi: OS=$OS_FAMILY ($OS_ID), PKG=$PKG_MGR"
}

pkg_install() { eval "$PKG_INSTALL $*"; }
pkg_update()  { eval "$PKG_UPDATE" >/dev/null 2>&1 || true; }

detect_init() {
    INIT_SYSTEM="none"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then INIT_SYSTEM="systemd"
    elif command -v rc-update >/dev/null 2>&1; then INIT_SYSTEM="openrc"; fi
    export INIT_SYSTEM
    log_info "Init System: $INIT_SYSTEM"
}

check_resources() {
    log_info "Memeriksa kapasitas sistem..."
    local mem=0
    if [ -f /proc/meminfo ]; then
        mem=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    else
        mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 0)
    fi
    
    if [ "$mem" -gt 0 ] && [ "$mem" -lt 120 ]; then
        log_warn "RAM sangat rendah ($mem MB). Potensi gagal booting OoklaServer."
    elif [ "$mem" -lt 400 ]; then
        log_info "RAM $mem MB (Cukup untuk lingkungan minimal)."
    fi

    local disk=$(df -m "$BASE_DIR" | awk 'END{print $4}' || echo 0)
    if [ "$disk" -gt 0 ] && [ "$disk" -lt 30 ]; then
        log_error "Disk space kritis ($disk MB). Butuh minimal 30MB."
        return 1
    fi
    return 0
}

open_ports() {
    log_info "Konfigurasi Firewall (Port 80, 443, 8080, 5060)..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 8080/tcp >/dev/null 2>&1; ufw allow 5060/tcp >/dev/null 2>&1
        ufw allow 8080/udp >/dev/null 2>&1; ufw allow 5060/udp >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port={80/tcp,443/tcp,8080/tcp,5060/tcp,8080/udp,5060/udp} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --match multiport --dports 80,443,8080,5060 -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p udp --match multiport --dports 8080,5060 -j ACCEPT 2>/dev/null || true
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
