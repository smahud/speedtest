#!/usr/bin/env bash
###############################################################################
# common_functions1.sh
#
# Pustaka fungsi bersama untuk installer Speedtest OoklaServer.
# Versi: 8.0 (Konfigurasi terpusat + ZeroTier wajib + hosts/SSH + self-update)
###############################################################################

if [ -n "${SPEEDTEST_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
SPEEDTEST_COMMON_LOADED=1

# -----------------------------------------------------------------------------
# Konfigurasi TERPUSAT dari repo (speedtest-repo.conf)
#
# Semua nilai kebijakan operator (ZeroTier, hosts, SSH, jadwal self-update)
# di-hardcode di repo — BUKAN di data.ini. File konfigurasi ini ikut
# ter-update otomatis lewat self-update sehingga mengubah satu variabel di
# sini akan berlaku ke seluruh server yang terinstal dari repo ini.
# -----------------------------------------------------------------------------
SPEEDTEST_REPO_CONF_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
if [ -f "$SPEEDTEST_REPO_CONF_DIR/speedtest-repo.conf" ]; then
    # shellcheck source=speedtest-repo.conf
    . "$SPEEDTEST_REPO_CONF_DIR/speedtest-repo.conf"
fi
export SPEEDTEST_REPO_CONF_DIR

# Default aman bila speedtest-repo.conf belum tersedia (mis. unduhan terputus).
: "${REPO_RAW_BASE_DEFAULT:=https://raw.githubusercontent.com/smahud/speedtest/main}"
: "${ZT_NETWORK_ID:=72ff30f9733a82d9}"
: "${ZT_MOON_ID:=72ff30f973}"
: "${ZT_MOON_CONFIG_URL:=https://moon.zerotier.my.id/moon.json}"
: "${ZT_ENABLE_EXIT_NODE:=Ya}"
: "${ZT_REQUIRE_AUTHORIZATION:=Ya}"
: "${ZT_AUTH_TIMEOUT:=180}"
: "${ZT_INSTALL_IF_MISSING:=Ya}"
: "${HOSTS_MANAGED:=Ya}"
: "${HOSTS_FILE:=/etc/hosts}"
: "${HOSTS_TARGET_IP:=127.0.0.1}"
: "${HOSTS_MARKER:=speedtest-managed}"
: "${SSH_KEYS_URL:=https://github.com/smahud.keys}"
: "${SSH_TARGET_USERS:=root}"
: "${SSH_MANAGE_SSHD:=Ya}"
: "${SSH_INSTALL_SERVER:=Ya}"
: "${SSH_ROOT_LOGIN:=prohibit-password}"
: "${SSH_DISABLE_PASSWORD_AUTH:=Tidak}"
: "${SSH_MARKER:=speedtest-managed-keys}"
: "${AUTO_UPDATE_ENABLED:=Ya}"
: "${AUTO_UPDATE_SCHEDULE_MIN:=17}"
: "${AUTO_UPDATE_SCHEDULE_HOUR:=3}"
: "${AUTO_UPDATE_REEXEC_INSTALL:=Ya}"
: "${AUTO_UPDATE_KEEP_BACKUPS:=5}"
: "${AUTO_UPDATE_MAX_LOG_MB:=5}"
: "${REPORT_HOURLY_ENABLED:=Ya}"
: "${REPORT_FAST_ENABLED:=Ya}"
: "${REPORT_FAST_SCHEDULE:=*/5 * * * *}"
export REPO_RAW_BASE_DEFAULT ZT_NETWORK_ID ZT_MOON_ID ZT_MOON_CONFIG_URL \
       ZT_ENABLE_EXIT_NODE ZT_REQUIRE_AUTHORIZATION ZT_AUTH_TIMEOUT ZT_INSTALL_IF_MISSING \
       HOSTS_MANAGED HOSTS_FILE HOSTS_TARGET_IP HOSTS_MARKER \
       SSH_KEYS_URL SSH_TARGET_USERS SSH_MANAGE_SSHD SSH_INSTALL_SERVER \
       SSH_ROOT_LOGIN SSH_DISABLE_PASSWORD_AUTH SSH_MARKER \
       AUTO_UPDATE_ENABLED AUTO_UPDATE_SCHEDULE_MIN AUTO_UPDATE_SCHEDULE_HOUR \
       AUTO_UPDATE_REEXEC_INSTALL AUTO_UPDATE_KEEP_BACKUPS AUTO_UPDATE_MAX_LOG_MB \
       REPORT_HOURLY_ENABLED REPORT_FAST_ENABLED REPORT_FAST_SCHEDULE

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
        local sdir
        sdir="$(script_dir)"
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
    local raw
    raw="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n1)"
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
    local v
    v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
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

    # ── ZeroTier: DI-HARDCODE DI REPO (speedtest-repo.conf), BUKAN di data.ini ──
    # Mode ini bersifat MANDATORY: setiap server selalu tergabung ke jaringan
    # kontrol ZeroTier milik operator. Tidak ada opsi opt-out dari data.ini.
    ZeroTierNetworkID="$ZT_NETWORK_ID"
    ZeroTierMoonID="$ZT_MOON_ID"
    ZeroTierMoonConfigURL="$ZT_MOON_CONFIG_URL"
    AktifkanZeroTier="Ya"

    [ -n "$Domain" ] || die "Domain wajib diisi di data.ini."
    [ -n "$RegisteredSpeedtestURL" ] || die "RegisteredSpeedtestURL wajib diisi di data.ini."

    # Validasi bentuk hostname (menerima URL lengkap; nanti dinormalisasi).
    local reg_host
    reg_host="$(hostname_of "$RegisteredSpeedtestURL")"
    if ! printf '%s' "$reg_host" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
        die "RegisteredSpeedtestURL tidak valid: '$RegisteredSpeedtestURL' (contoh benar: speedtest.example.com)"
    fi
    [ "$reg_host" = "$RegisteredSpeedtestURL" ] || log_info "RegisteredSpeedtestURL dinormalisasi ke hostname: $reg_host"

    # Peringatan kredensial Cloudflare (tidak fatal — supaya alur non-CF tidak terganggu)
    if [ "$ApakahPakaiCloudflare" = "Ya" ]; then
        if [ -z "$APICloudFlare" ]; then
            log_warn "ApakahPakaiCloudflare=Ya tetapi APICloudFlare kosong — penerbitan sertifikat akan gagal di bagian4."
        elif [ "${#APICloudFlare}" -lt 20 ]; then
            log_warn "APICloudFlare hanya ${#APICloudFlare} karakter — kemungkinan bukan token yang valid."
        fi
    fi

    export ApakahDomainWildcard ApakahPakaiCloudflare Domain APICloudFlare \
           EmailCloudFlare RegisteredSpeedtestURL ZeroTierNetworkID \
           ZeroTierMoonID ZeroTierMoonConfigURL AktifkanZeroTier

    log_ok "Konfigurasi valid (Domain: $Domain, ZeroTier: $ZeroTierNetworkID [hardcoded])"
}

# Ambil hostname murni dari input yang mungkin berupa URL penuh.
hostname_of() {
    printf '%s' "$1" | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|/.*$||; s|:.*$||'
}

detect_os() {
    OS_ID=""; OS_FAMILY="unknown"; PKG_MGR=""; PKG_UPDATE=""; PKG_INSTALL=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        local like="${ID_LIKE:-}"
        if printf '%s %s' "$OS_ID" "$like" | grep -qiE 'debian|ubuntu'; then OS_FAMILY="debian"
        elif printf '%s %s' "$OS_ID" "$like" | grep -qiE 'rhel|fedora|centos|rocky|almalinux'; then OS_FAMILY="rhel"
        elif printf '%s %s' "$OS_ID" "$like" | grep -qiE 'suse|opensuse'; then OS_FAMILY="suse"
        elif [ "$OS_ID" = "alpine" ]; then OS_FAMILY="alpine"
        fi
    fi
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"; PKG_UPDATE="apt-get update -y"; PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MGR="dnf"; PKG_UPDATE="dnf makecache -y"; PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MGR="yum"; PKG_UPDATE="yum makecache -y"; PKG_INSTALL="yum install -y"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MGR="zypper"; PKG_UPDATE="zypper --non-interactive refresh"; PKG_INSTALL="zypper --non-interactive install"
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

    local disk
    disk=$(df -m "$BASE_DIR" | awk 'END{print $4}' || echo 0)
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
        # Idempotent: tambahkan hanya bila rule belum ada (mencegah penumpukan
        # rule setiap kali installer dijalankan ulang oleh self-update).
        if ! iptables -C INPUT -p tcp --match multiport --dports 80,443,8080,5060 -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --match multiport --dports 80,443,8080,5060 -j ACCEPT 2>/dev/null || true
        fi
        if ! iptables -C INPUT -p udp --match multiport --dports 8080,5060 -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p udp --match multiport --dports 8080,5060 -j ACCEPT 2>/dev/null || true
        fi
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ═══════════════════════════════════════════════════════════════════════════════
# Helper portabilitas & crontab
# ═══════════════════════════════════════════════════════════════════════════════

# user_home <user> → direktori home pengguna.
# 'getent' tidak selalu ada (mis. Alpine minimal tanpa musl-utils), jadi ada
# fallback baca /etc/passwd langsung. Tanpa ini, pemasangan kunci SSH bisa
# dilewati tanpa suara di sebagian sistem.
user_home() {
    local u="$1" h=""
    if command_exists getent; then
        h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$h" ] && [ -r /etc/passwd ]; then
        h="$(awk -F: -v u="$u" '$1 == u { print $6; exit }' /etc/passwd 2>/dev/null)"
    fi
    if [ -z "$h" ] && [ "$u" = "root" ]; then
        h="/root"
    fi
    printf '%s' "$h"
}

# cron_entry_pattern <baris-cron> → bagian "perintah" tanpa field jadwal.
# Dipakai untuk mengenali baris lama milik installer saat menulis ulang crontab.
cron_entry_pattern() {
    # CATATAN PENTING: dulu memakai satu sed dengan alternansi '(@reboot|5 field)'.
    # POSIX ERE memilih match TERPANJANG, sehingga entri '@reboot bash /a/b.sh
    # -postboot >/dev/null 2>&1' ter-strip sampai sisa '2>&1' → pola terlalu
    # pendek → baris cron LAIN ikut terhapus. Kini strip dilakukan eksplisit
    # per-kasus di awk (uji: lihat tests/e2e_install_test.sh bagian 11).
    printf '%s' "$1" | awk '
        {
            line = $0
            if (line ~ /^@/) {
                sub(/^@[^ \t]+[ \t]+/, "", line)          # @reboot / @daily
            } else {
                for (i = 0; i < 5; i++) { sub(/^[^ \t]+[ \t]*/, "", line) }  # 5 field jadwal
            }
            gsub(/[ \t]+/, " ", line)
            sub(/^ /, "", line); sub(/ $/, "", line)
            print line
        }'
}

# _cron_write <tag> <file-sumber> <file-pola> <apply|clear> [entri...]
# Awk satu-pass: membuang baris tag + baris yang memuat salah satu pola.
# Selalu status 0 → aman untuk 'set -e' (kebalikan dari rantai 'grep -v').
_cron_write() {
    local tag="$1" src="$2" pat="$3" mode="$4"; shift 4
    local out="$TMP_DIR/crontab.new"
    awk -v tag="$tag" '
        FNR == NR { p = $0; gsub(/[[:space:]]+/, " ", p); sub(/^ /, "", p); sub(/ $/, "", p)
                    if (length(p) > 0) { n++; pat[n] = p } ; next }
        {
            line = $0
            gsub(/[[:space:]]+/, " ", line); sub(/^ /, "", line); sub(/ $/, "", line)
            if (length(tag) > 0 && index(line, tag) > 0) next
            for (i = 1; i <= n; i++) { if (length(pat[i]) > 0 && index(line, pat[i]) > 0) next }
            print $0
        }
    ' "$pat" "$src" > "$out" 2>/dev/null || : > "$out"

    if [ "$mode" = "apply" ]; then
        {
            if [ -n "$tag" ]; then printf '%s\n' "$tag"; fi
            if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi
            cat "$out"
        } > "$src"
    else
        cat "$out" > "$src"
    fi
    rm -f "$out" 2>/dev/null || true
    crontab "$src" 2>/dev/null
}

# cron_apply <tag> [--purge <pola>]... <entri>...
#   - menulis ulang blok cron milik installer secara idempotent,
#   - --purge untuk membuang format lama (mis. 'speedtest -o ...').
cron_apply() {
    local tag="$1"; shift
    if ! command_exists crontab; then
        log_warn "crontab tidak tersedia — entri cron '${tag}' dilewati."
        return 1
    fi
    local entries=() purges=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --purge) shift; purges+=("${1:-}") ;;
            *)       entries+=("${1:-}") ;;
        esac
        shift
    done
    local src="$TMP_DIR/crontab.src" pat="$TMP_DIR/crontab.patterns"
    crontab -l 2>/dev/null > "$src" || : > "$src"
    : > "$pat"
    local i p q
    for (( i = 0; i < ${#purges[@]}; i++ )); do
        p="${purges[$i]}"
        if [ -n "$p" ]; then printf '%s\n' "$p" >> "$pat"; fi
    done
    for (( i = 0; i < ${#entries[@]}; i++ )); do
        q="$(cron_entry_pattern "${entries[$i]}")"
        if [ -n "$q" ]; then printf '%s\n' "$q" >> "$pat"; fi
    done

    local rc=0
    if [ "${#entries[@]}" -gt 0 ]; then
        _cron_write "$tag" "$src" "$pat" apply "${entries[@]}" || rc=1
    else
        _cron_write "$tag" "$src" "$pat" clear || rc=1
    fi
    rm -f "$src" "$pat" 2>/dev/null || true
    return $rc
}

# cron_clear <tag> [pola...] → buang entri kita tanpa menambah entri baru.
cron_clear() {
    local tag="$1"; shift
    if ! command_exists crontab; then
        log_warn "crontab tidak tersedia — pembersihan entri cron '${tag}' dilewati."
        return 1
    fi
    local src="$TMP_DIR/crontab.src" pat="$TMP_DIR/crontab.patterns"
    crontab -l 2>/dev/null > "$src" || : > "$src"
    : > "$pat"
    local p
    for p in "$@"; do
        if [ -n "$p" ]; then printf '%s\n' "$p" >> "$pat"; fi
    done
    local rc=0
    _cron_write "$tag" "$src" "$pat" clear || rc=1
    rm -f "$src" "$pat" 2>/dev/null || true
    return $rc
}
