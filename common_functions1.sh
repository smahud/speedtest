#!/usr/bin/env bash
###############################################################################
# common_functions1.sh
#
# Pustaka fungsi bersama untuk installer Speedtest OoklaServer.
# Versi: 8.0 (Konfigurasi terpusat + ZeroTier wajib + hosts/SSH + self-update)
###############################################################################

if [ -n "${SPEEDTEST_COMMON_LOADED:-}" ]; then
    # Guard anti double-source. '|| true' hanya terpakai bila file ini
    # dieksekusi langsung (bukan di-source) sehingga 'return' gagal.
    # shellcheck disable=SC2317
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
: "${REPORT_LOG_MAX_KB:=512}"
: "${REPORT_JITTER_MIN_MAX:=50}"
: "${SPEEDTEST_CLI_PATH:=/usr/local/bin/speedtest}"
: "${SPEEDTEST_CLI_LICENSE_FLAGS:=--accept-license --accept-gdpr}"
: "${SPEEDTEST_SMOKE_TEST:=Ya}"
: "${SPEEDTEST_SMOKE_TIMEOUT:=150}"
: "${CRON_PATH:=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
: "${TLS_VERIFY_ENABLED:=Ya}"
: "${TLS_VERIFY_STRICT:=Tidak}"
: "${CERT_MIN_VALID_DAYS:=10}"
export REPO_RAW_BASE_DEFAULT ZT_NETWORK_ID ZT_MOON_ID ZT_MOON_CONFIG_URL \
       ZT_ENABLE_EXIT_NODE ZT_REQUIRE_AUTHORIZATION ZT_AUTH_TIMEOUT ZT_INSTALL_IF_MISSING \
       HOSTS_MANAGED HOSTS_FILE HOSTS_TARGET_IP HOSTS_MARKER \
       SSH_KEYS_URL SSH_TARGET_USERS SSH_MANAGE_SSHD SSH_INSTALL_SERVER \
       SSH_ROOT_LOGIN SSH_DISABLE_PASSWORD_AUTH SSH_MARKER \
       AUTO_UPDATE_ENABLED AUTO_UPDATE_SCHEDULE_MIN AUTO_UPDATE_SCHEDULE_HOUR \
       AUTO_UPDATE_REEXEC_INSTALL AUTO_UPDATE_KEEP_BACKUPS AUTO_UPDATE_MAX_LOG_MB \
       REPORT_HOURLY_ENABLED REPORT_FAST_ENABLED REPORT_FAST_SCHEDULE REPORT_LOG_MAX_KB REPORT_JITTER_MIN_MAX \
       SPEEDTEST_CLI_PATH SPEEDTEST_CLI_LICENSE_FLAGS SPEEDTEST_SMOKE_TEST SPEEDTEST_SMOKE_TIMEOUT \
       CRON_PATH TLS_VERIFY_ENABLED TLS_VERIFY_STRICT CERT_MIN_VALID_DAYS

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
    # PENTING (C5): simpan hasil normalisasi ke variabelnya. Tanpa ini,
    # /etc/hosts (bagian10) dan wrapper cron (bagian6) bisa memakai URL mentah
    # ("https://speedtest.example.com/") sehingga mapping localhost TIDAK
    # pernah cocok dengan yang dipakai CLI Ookla.
    if [ "$reg_host" != "$RegisteredSpeedtestURL" ]; then
        log_info "RegisteredSpeedtestURL dinormalisasi: '$RegisteredSpeedtestURL' → '$reg_host'"
        RegisteredSpeedtestURL="$reg_host"
    fi

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

pkg_install() {
    # PKG_INSTALL memuat prefiks env (mis. DEBIAN_FRONTEND=noninteractive) yang
    # tidak bisa dinyatakan lewat word-splitting biasa → tetap memakai eval,
    # tetapi setiap argumen dikutip dengan '%q' agar nama paket tidak bisa
    # diinterpretasikan sebagai perintah tambahan.
    local q="" a
    for a in "$@"; do q="$q $(printf '%q' "$a")"; done
    # shellcheck disable=SC2086  # $q memang harus dipecah menjadi kata
    eval "$PKG_INSTALL$q"
}
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
    # Port yang dibuka: 80/443 (ACME/certbot & HTTPS) + port yang benar-benar
    # dipakai OoklaServer menurut OoklaServer.properties (bukan hardcode 8080/
    # 5060 saja — operator bisa mengubahnya).
    local zt_ports tcp_list udp_list
    zt_ports="$(ookla_props_ports "${OOKLA_PROPERTIES:-}")"
    if [ -z "$zt_ports" ]; then zt_ports="8080 5060"; fi
    tcp_list="80,443"
    udp_list=""
    local p
    for p in $zt_ports; do
        tcp_list="$tcp_list,$p"
        udp_list="${udp_list:+$udp_list,}$p"
    done

    log_info "Konfigurasi Firewall (TCP: $tcp_list; UDP: ${udp_list:-$zt_ports})..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1; ufw allow 443/tcp >/dev/null 2>&1
        for p in $zt_ports; do
            ufw allow "$p"/tcp >/dev/null 2>&1 || true
            ufw allow "$p"/udp >/dev/null 2>&1 || true
        done
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port={80/tcp,443/tcp} >/dev/null 2>&1
        for p in $zt_ports; do
            firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-port="$p"/udp >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1
    else
        # iptables dipakai via path absolut: 'iptables' ada di /usr/sbin yang
        # TIDAK ada di PATH cron / shell minimal.
        local ipt
        ipt="$(network_bin iptables /usr/sbin/iptables /sbin/iptables)"
        if [ -n "$ipt" ]; then
            # Idempotent: tambahkan hanya bila rule belum ada (mencegah
            # penumpukan rule setiap installer dijalankan ulang).
            if ! "$ipt" -C INPUT -p tcp --match multiport --dports "$tcp_list" -j ACCEPT 2>/dev/null; then
                if ! "$ipt" -I INPUT -p tcp --match multiport --dports "$tcp_list" -j ACCEPT 2>/dev/null; then
                    log_warn "Gagal membuka port TCP $tcp_list via iptables (buka manual bila perlu)."
                fi
            fi
            if ! "$ipt" -C INPUT -p udp --match multiport --dports "${udp_list:-$zt_ports}" -j ACCEPT 2>/dev/null; then
                # Bila daftar UDP memakai koma hasil olahan, ubah ke bentuk koma.
                if ! "$ipt" -I INPUT -p udp --match multiport --dports "${udp_list:-$zt_ports}" -j ACCEPT 2>/dev/null; then
                    log_warn "Gagal membuka port UDP ${udp_list:-$zt_ports} via iptables (buka manual bila perlu)."
                fi
            fi
        else
            log_info "Tidak ada ufw/firewalld/iptables — pengaturan firewall dilewati."
        fi
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Tambahkan direktori dari $CRON_PATH yang BELUM ada di PATH. TIDAK menghapus
# entri apa pun — berbeda dengan PATH="$CRON_PATH" yang menimpa PATH operator
# (dan pada uji/mock bisa menghilangkan shim sehingga tool asli terpanggil).
path_augment_from_cron_path() {
    local d old="$PATH"
    local IFS=':'
    # shellcheck disable=SC2086  # pemisah ':' lewat IFS
    for d in ${CRON_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}; do
        [ -n "$d" ] || continue
        case ":$PATH:" in *":$d:"*) ;; *) PATH="${PATH:+$PATH:}$d" ;; esac
    done
    PATH="${PATH:-$old}"
    export PATH
    return 0
}

# Resolusi path absolut untuk tool jaringan (iptables/sysctl/ip berada di
# /usr/sbin yang TIDAK ada di PATH cron minimal). Cetak '' bila tidak ada.
network_bin() {
    # $1 = nama perintah; $2.. = kandidat path absolut yang dikenal.
    # Path absolut didahulukan: artefak cron (dan @reboot) sering berjalan
    # dengan PATH minimal sehingga /usr/sbin dan /sbin tidak terlihat —
    # akibatnya iptables/ip "tidak ditemukan" dan NAT gagal senyap.
    local name="$1" cand p=""
    shift
    for cand in "$@"; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then p="$cand"; break; fi
    done
    if [ -z "$p" ]; then
        p="$(command -v "$name" 2>/dev/null || true)"
    fi
    printf '%s' "$p"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Ookla CLI: path absolut, lisensi, & uji end-to-end
#
# LATAR (bug yang diperbaiki di v8.1.1):
#   B13 — CLI Ookla MENOLAK berjalan tanpa TTY bila lisensi belum diterima
#         ("Please run speedtest interactively or use --accept-license").
#         Cron selalu tanpa TTY → setiap laporan gagal rc=1 dan senyap.
#   B14 — cron Debian/Ubuntu/Alpine hanya PATH=/usr/bin:/bin, sedangkan biner
#         Ookla dipasang di /usr/local/bin → 'speedtest: not found'.
# Aturan tetap: setiap pemanggilan dari jalur cron memakai path absolut hasil
# ookla_cli_path(), membawa $SPEEDTEST_CLI_LICENSE_FLAGS, dan PATH=$CRON_PATH.
# ═══════════════════════════════════════════════════════════════════════════════

# Path biner CLI Ookla (konfigurasi → /usr/local/bin → PATH).
ookla_cli_path() {
    local p="${SPEEDTEST_CLI_PATH:-/usr/local/bin/speedtest}"
    if [ -n "$p" ] && [ -x "$p" ]; then
        printf '%s' "$p"
        return 0
    fi
    p="$(command -v speedtest 2>/dev/null || true)"
    printf '%s' "$p"
}

# Benar hanya bila biner yang dipanggil adalah CLI RESMI Ookla
# (bukan 'speedtest-cli' Python/sivel yang tidak punya opsi -o).
ookla_cli_is_official() {
    local bin="${1:-}"
    if [ -z "$bin" ]; then bin="$(ookla_cli_path)"; fi
    [ -n "$bin" ] || return 1
    "$bin" --version 2>/dev/null | grep -qi 'ookla'
}

ookla_license_file() { printf '%s' "${HOME:-/root}/.config/ookla/speedtest-cli.json"; }
ookla_license_accepted() { [ -s "$(ookla_license_file)" ]; }

# Uji cepat (tanpa uji bandwidth) bahwa CLI menerima flag lisensi non-interaktif.
ookla_license_probe() {
    local bin="${1:-}"
    if [ -z "$bin" ]; then bin="$(ookla_cli_path)"; fi
    [ -n "$bin" ] || return 127
    # shellcheck disable=SC2086  # $SPEEDTEST_CLI_LICENSE_FLAGS sengaja dipecah jadi kata
    "$bin" $SPEEDTEST_CLI_LICENSE_FLAGS -L >/dev/null 2>&1
}

# Rotasi log sederhana berbasis ukuran (KB). Selalu aman untuk 'set -e'.
rotate_log_kb() {
    local f="$1" max_kb="${2:-512}" sz
    [ -f "$f" ] || return 0
    sz="$(wc -c < "$f" 2>/dev/null | awk '{print $1}')"
    case "${sz:-}" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$sz" -gt $(( max_kb * 1024 )) ]; then
        mv -f "$f" "$f.1" 2>/dev/null || true
        : > "$f" 2>/dev/null || true
    fi
    return 0
}

# Jalankan satu uji speedtest ke server yang didaftarkan (lewat /etc/hosts =
# 127.0.0.1 sehingga TIDAK memakai kuota internet).
#   $1 = RegisteredSpeedtestURL   $2 = file log (opsional)   $3 = timeout detik
# Hasil terakhir tersedia di $LAST_REPORT_OUTPUT dan $LAST_REPORT_RC.
ookla_report_once() {
    local url="$1" log="${2:-}" to="${3:-${SPEEDTEST_SMOKE_TIMEOUT:-150}}"
    local bin out rc=0
    local -a t=()
    bin="$(ookla_cli_path)"
    if [ -z "$bin" ]; then
        LAST_REPORT_OUTPUT="CLI Ookla tidak ditemukan (${SPEEDTEST_CLI_PATH:-/usr/local/bin/speedtest})."
        LAST_REPORT_RC=127
        return 127
    fi
    if command_exists timeout; then t=(timeout "$to"); fi
    # shellcheck disable=SC2086  # $SPEEDTEST_CLI_LICENSE_FLAGS sengaja dipecah jadi kata
    out="$("${t[@]+"${t[@]}"}" "$bin" $SPEEDTEST_CLI_LICENSE_FLAGS -o "$url" 2>&1)" || rc=$?
    LAST_REPORT_OUTPUT="$out"
    LAST_REPORT_RC="$rc"
    if [ -n "$log" ]; then
        rotate_log_kb "$log" "${REPORT_LOG_MAX_KB:-512}"
        {
            printf '%s [report] url=%s rc=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$url" "$rc"
            printf '%s\n' "$out" | sed 's/^/    /'
        } >> "$log" 2>/dev/null || true
    fi
    return "$rc"
}

# Port TCP yang dibuka OoklaServer menurut OoklaServer.properties.
ookla_props_ports() {
    local f="${1:-${OOKLA_PROPERTIES:-}}"
    if [ -z "$f" ] || [ ! -f "$f" ]; then return 0; fi
    grep -E '^[[:space:]]*OoklaServer\.tcpPorts[[:space:]]*=' "$f" 2>/dev/null \
        | tail -n1 | sed 's/.*=[[:space:]]*//' | tr ',' ' '
}

# Uji HTTP ke server lokal. Sukses (rc=0) → kode HTTP dicetak ke stdout.
endpoint_http_probe() {
    local port="$1" code=""
    if command_exists curl; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$port/" 2>/dev/null || true)"
    elif command_exists wget; then
        code="$(wget -q -S -O /dev/null --timeout=5 "http://127.0.0.1:$port/" 2>&1 \
                | awk '/HTTP\//{print $2}' | tail -n1 || true)"
    else
        return 2
    fi
    case "$code" in
        ''|000) return 1 ;;
        *) printf '%s' "$code"; return 0 ;;
    esac
}

# Uji TLS end-to-end ke port lokal memakai SNI domain (0 = rantai sertifikat valid).
endpoint_tls_probe() {
    local dom="$1" port="$2" out=""
    local -a t=()
    command_exists openssl || return 2
    if command_exists timeout; then t=(timeout 8); fi
    out="$("${t[@]+"${t[@]}"}" openssl s_client -connect "127.0.0.1:$port" -servername "$dom" \
            -verify_return_error </dev/null 2>&1 || true)"
    printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'
}

# ═══════════════════════════════════════════════════════════════════════════════
# Sertifikat Let's Encrypt: masa berlaku & kelayakan pakai
#
# BUG v8.1.0 (B17): cert_valid_for() hanya menjalankan
#   `certbot certificates --domain X | grep -i "Expiry Date"`
# sehingga sertifikat KEDALUWARSA pun dianggap "masih berlaku" → instalasi ulang
# menolak menerbitkan ulang dan pesan yang dicetak menyesatkan.
# Sekarang: cek nyata via `openssl x509 -checkend` (minimal CERT_MIN_VALID_DAYS).
# ═══════════════════════════════════════════════════════════════════════════════

# Direktori live Let's Encrypt (di-override di uji).
: "${CERT_LIVE_DIR:=/etc/letsencrypt/live}"
export CERT_LIVE_DIR

# Sisa hari masa berlaku sertifikat untuk domain $1 (kosong bila tak terbaca).
cert_days_left() {
    local pem="${CERT_LIVE_DIR:-/etc/letsencrypt/live}/$1/fullchain.pem" end end_epoch
    [ -f "$pem" ] || return 0
    if command_exists openssl; then
        end="$(openssl x509 -enddate -noout -in "$pem" 2>/dev/null | cut -d= -f2)"
        if [ -n "$end" ]; then
            end_epoch="$(date -d "$end" +%s 2>/dev/null \
                         || date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || true)"
            if [ -n "$end_epoch" ]; then
                printf '%s' "$(( (end_epoch - $(date +%s)) / 86400 ))"
            fi
        fi
    fi
    return 0
}

# Sertifikat layak dipakai hanya bila: file ada, TIDAK kedaluwarsa, dan sisa
# masa berlaku >= CERT_MIN_VALID_DAYS hari.
cert_valid_for() {
    local dom="$1" pem min="${CERT_MIN_VALID_DAYS:-10}" days
    pem="${CERT_LIVE_DIR:-/etc/letsencrypt/live}/$dom/fullchain.pem"
    [ -f "$pem" ] || return 1
    if command_exists openssl; then
        if openssl x509 -checkend $(( min * 86400 )) -noout -in "$pem" >/dev/null 2>&1; then
            return 0
        fi
        days="$(cert_days_left "$dom")"
        log_warn "Sertifikat '$dom' kedaluwarsa / sisa < $min hari (sisa: ${days:-tidak terbaca}) → perlu diterbitkan ulang."
        return 1
    fi
    # Fallback tanpa openssl: baca 'VALID: N days' dari certbot.
    days="$(certbot certificates --domain "$dom" 2>/dev/null \
            | sed -n 's/.*VALID: *\([0-9]\{1,\}\) *days.*/\1/p' | head -n1)"
    case "$days" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$days" -ge "$min" ]; then return 0; fi
    log_warn "Sertifikat '$dom' sisa $days hari (< $min) → perlu diterbitkan ulang."
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# SSH: kunci publik GitHub + konfigurasi sshd terkelola.
# SATU implementasi untuk bagian9 dan bagian10 (dulu keduanya punya salinan
# sendiri yang bisa berbeda perilaku — sumber bug diam-diam).
# ═══════════════════════════════════════════════════════════════════════════════

# Jumlah baris kunci publik OpenSSH yang valid di sebuah file.
ssh_keys_valid_count() {
    local n
    n="$(grep -cE '^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+' "$1" 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# Unduh + validasi daftar kunci dari SSH_KEYS_URL ke $1. 0 = berhasil.
ssh_keys_fetch() {
    local dest="$1" url="${SSH_KEYS_URL:-https://github.com/smahud.keys}" rc=0
    if [ -z "$dest" ]; then return 1; fi
    rm -f "$dest.tmp" 2>/dev/null || true
    if command_exists curl; then
        curl -fsSL --max-time 60 -H 'Accept: application/vnd.github.raw' -o "$dest.tmp" "$url" || rc=$?
    elif command_exists wget; then
        wget -q -T 60 --header='Accept: application/vnd.github.raw' -O "$dest.tmp" "$url" || rc=$?
    elif command_exists busybox; then
        busybox wget -q -O "$dest.tmp" "$url" || rc=$?
    else
        return 127
    fi
    if [ "$rc" -ne 0 ] || [ ! -s "$dest.tmp" ]; then
        rm -f "$dest.tmp" 2>/dev/null || true
        return 1
    fi
    if [ "$(ssh_keys_valid_count "$dest.tmp")" -lt 1 ]; then
        rm -f "$dest.tmp" 2>/dev/null || true
        return 1
    fi
    mv -f "$dest.tmp" "$dest" || return 1
    chmod 600 "$dest" 2>/dev/null || true
    return 0
}

# Pasang kunci ke authorized_keys user target (blok terkelola, idempotent).
ssh_keys_install_for_user() {
    local u="$1" keyfile="$2" home h tmpak mark="${SSH_MARKER:-speedtest-managed-keys}"
    home="$(user_home "$u")"
    if [ -z "$home" ]; then log_warn "Home user '$u' tidak diketahui — dilewati."; return 1; fi
    h="$home/.ssh"
    mkdir -p "$h" 2>/dev/null || { log_warn "Tidak bisa membuat $h"; return 1; }
    touch "$h/authorized_keys" 2>/dev/null || { log_warn "Tidak bisa menulis $h/authorized_keys"; return 1; }
    tmpak="$h/authorized_keys.speedtesttmp.$$"
    if ! awk -v begin="# BEGIN $mark" -v end="# END $mark" '
            $0 == begin { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip { print }
        ' "$h/authorized_keys" > "$tmpak" 2>/dev/null; then
        cp -f "$h/authorized_keys" "$tmpak" 2>/dev/null || : > "$tmpak"
    fi
    {
        printf '# BEGIN %s\n' "$mark"
        printf '# Dikelola otomatis oleh speedtest installer — jangan diedit manual.\n'
        printf '# Sumber: %s (disinkronkan %s)\n' "${SSH_KEYS_URL:-}" "$(date -Iseconds 2>/dev/null || date)"
        grep -vE '^[[:space:]]*(#|$)' "$keyfile"
        printf '# END %s\n' "$mark"
    } >> "$tmpak" 2>/dev/null || { rm -f "$tmpak" 2>/dev/null || true; log_warn "Gagal menyusun $h/authorized_keys"; return 1; }
    if ! mv -f "$tmpak" "$h/authorized_keys" 2>/dev/null; then
        rm -f "$tmpak" 2>/dev/null || true
        log_warn "Gagal memasang $h/authorized_keys"
        return 1
    fi
    chmod 700 "$h" 2>/dev/null || true
    chmod 600 "$h/authorized_keys" 2>/dev/null || true
    chown -R "$u:$u" "$h" 2>/dev/null \
        || chown -R "$(id -u "$u" 2>/dev/null || echo "$u"):$(id -g "$u" 2>/dev/null || echo "$u")" "$h" 2>/dev/null || true
    if command_exists restorecon; then restorecon -RF "$h" >/dev/null 2>&1 || true; fi
    log_ok "Kunci publik tersinkron untuk user '$u' → $h/authorized_keys"
    return 0
}

# Path biner sshd ('sshd' tidak selalu ada di PATH minimal).
sshd_bin_path() {
    local b
    b="$(command -v sshd 2>/dev/null || true)"
    if [ -z "$b" ] && [ -x /usr/sbin/sshd ]; then b="/usr/sbin/sshd"; fi
    printf '%s' "$b"
}

# Reload/restart sshd dengan urutan nama service yang berbeda antar distro.
sshd_restart_service() {
    if command_exists systemctl && [ -d /run/systemd/system ]; then
        systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 \
          || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
    elif command_exists rc-service; then
        rc-service sshd reload >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || true
    elif command_exists service; then
        service sshd reload >/dev/null 2>&1 || service ssh reload >/dev/null 2>&1 || true
    fi
    return 0
}

# Isi file konfigurasi sshd terkelola (satu sumber kebenaran).
sshd_managed_content() {
    local root_login="${SSH_ROOT_LOGIN:-prohibit-password}" pwline=""
    if [ "${SSH_DISABLE_PASSWORD_AUTH:-Tidak}" = "Ya" ]; then
        pwline="PasswordAuthentication no"
    fi
    cat <<EOF
# Dikelola otomatis oleh speedtest installer (bagian9/bagian10).
# Jangan diedit manual — perubahan akan ditimpa pada sinkronisasi berikutnya.
PermitRootLogin $root_login
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
${pwline}
EOF
}

# Tulis/ubah satu direktif di file konfigurasi sshd (idempotent).
sshd_apply_kv() {
    local f="$1" key="$2" val="$3"
    if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$f" 2>/dev/null; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$f"
    else
        printf '%s %s\n' "$key" "$val" >> "$f"
    fi
}

# Terapkan konfigurasi sshd terkelola: backup → drop-in (bila didukung) atau
# file utama → validasi 'sshd -t' → reload. Rollback otomatis bila tidak valid.
sshd_apply_managed_config() {
    local bin main="/etc/ssh/sshd_config" din="/etc/ssh/sshd_config.d/99-speedtest-managed.conf"
    local content bk need=1 tmp
    bin="$(sshd_bin_path)"
    if [ -z "$bin" ]; then log_warn "sshd tidak terpasang — standardisasi sshd dilewati."; return 1; fi
    content="$(sshd_managed_content)"

    if [ -f "$din" ] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main" 2>/dev/null; then
        if printf '%s\n' "$content" | diff -q - "$din" >/dev/null 2>&1; then need=0; fi
    fi
    if [ "$need" -eq 0 ]; then
        log_ok "Konfigurasi sshd sudah sesuai — tidak ada perubahan."
        return 0
    fi

    bk="$BASE_DIR/.ssh-backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk" 2>/dev/null || true
    if [ -f "$main" ]; then cp -p "$main" "$bk/sshd_config" 2>/dev/null || true; fi
    if [ -d /etc/ssh/sshd_config.d ]; then cp -p /etc/ssh/sshd_config.d/*.conf "$bk/" 2>/dev/null || true; fi

    if [ -f "$main" ] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
        mkdir -p /etc/ssh/sshd_config.d 2>/dev/null || true
        if ! printf '%s\n' "$content" > "$din" 2>/dev/null; then
            log_warn "Gagal menulis $din"
            return 1
        fi
        chmod 600 "$din" 2>/dev/null || true
        if "$bin" -t >/dev/null 2>&1; then
            log_ok "Konfigurasi sshd valid (drop-in: $din | backup: $bk)"
            sshd_restart_service
            return 0
        fi
        log_error "Validasi 'sshd -t' GAGAL dengan drop-in — dikembalikan (rollback)."
        rm -f "$din" 2>/dev/null || true
        return 1
    fi

    # Fallback: file utama (idempotent + validasi + rollback)
    if [ ! -f "$main" ]; then log_warn "$main tidak ada — konfigurasi sshd dilewati."; return 1; fi
    tmp="$main.speedtesttmp.$$"
    if ! cp -p "$main" "$tmp" 2>/dev/null; then log_warn "Tidak bisa menyalin $main"; return 1; fi
    sshd_apply_kv "$tmp" PermitRootLogin "${SSH_ROOT_LOGIN:-prohibit-password}"
    sshd_apply_kv "$tmp" PubkeyAuthentication yes
    sshd_apply_kv "$tmp" AuthorizedKeysFile .ssh/authorized_keys
    if [ "${SSH_DISABLE_PASSWORD_AUTH:-Tidak}" = "Ya" ]; then
        sshd_apply_kv "$tmp" PasswordAuthentication no
    fi
    if ! mv -f "$tmp" "$main" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        log_warn "Gagal menerapkan $main"
        return 1
    fi
    if "$bin" -t >/dev/null 2>&1; then
        log_ok "Konfigurasi sshd valid (file utama | backup: $bk)"
        sshd_restart_service
        return 0
    fi
    log_error "Validasi 'sshd -t' GAGAL — memulihkan backup."
    if [ -f "$bk/sshd_config" ]; then
        cp -f "$bk/sshd_config" "$main" 2>/dev/null || true
        if "$bin" -t >/dev/null 2>&1; then log_ok "sshd_config dipulihkan dari $bk."; fi
    else
        log_error "Tidak ada backup untuk dipulihkan — periksa $main secara manual!"
    fi
    return 1
}

# Sinkronisasi lengkap: unduh kunci → pasang untuk semua user target →
# (bila SSH_MANAGE_SSHD=Ya) terapkan konfigurasi sshd terkelola.
# Dipakai oleh bagian9, bagian10, dan boot-sync (@reboot) — idempotent.
ssh_sync_all() {
    local users="${SSH_TARGET_USERS:-root}" u i=0 rc=0 keyfile
    keyfile="$TMP_DIR/ssh-keys.pub"
    if ! ssh_keys_fetch "$keyfile"; then
        log_error "Gagal mengunduh/memvalidasi kunci publik (${SSH_KEYS_URL:-}) — konfigurasi SSH dibiarkan apa adanya."
        return 1
    fi
    log_info "$(ssh_keys_valid_count "$keyfile") kunci publik valid dari ${SSH_KEYS_URL:-}."
    for u in $users; do
        if id "$u" >/dev/null 2>&1; then
            ssh_keys_install_for_user "$u" "$keyfile" || rc=1
            i=$((i + 1))
        else
            log_warn "User '$u' tidak ada di sistem — dilewati."
        fi
    done
    rm -f "$keyfile" 2>/dev/null || true
    if [ "$i" -eq 0 ]; then log_warn "Tidak ada user target yang berhasil dipasangi kunci."; rc=1; fi
    if [ "${SSH_MANAGE_SSHD:-Ya}" = "Ya" ]; then
        sshd_apply_managed_config || rc=1
    else
        log_info "SSH_MANAGE_SSHD=Tidak → konfigurasi sshd tidak diubah."
    fi
    return $rc
}

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
