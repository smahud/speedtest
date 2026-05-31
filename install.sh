#!/usr/bin/env bash
###############################################################################
# install.sh — Installer Speedtest OoklaServer (end-to-end, non-interaktif*)
#
# *Pengecualian: mode non-Cloudflare butuh interaksi user untuk update DNS TXT
#  (verifikasi manual). Semua mode lain sepenuhnya otomatis.
#
# Penggunaan:
#   ./install.sh [/path/ke/data.ini]
#
# DIJALANKAN DI DIREKTORI TEMPAT data.ini BERADA (tanpa argumen pun bisa):
#   cd /folder/berisi/data.ini
#   ./install.sh
#
# Aturan penentuan lokasi data.ini (CONFIG_PATH):
#   1) Argumen pertama bila diberikan.
#   2) Current working directory (tempat Anda menjalankan command).
#   3) Direktori tempat install.sh berada.
#   4) Jika tidak ditemukan -> error jelas.
#
# Semua file relatif aplikasi mengikuti BASE_DIR = direktori tempat data.ini.
# Tidak ada path /root/ yang di-hardcode.
#
# SELF-BOOTSTRAP:
#   Jika install.sh dijalankan SENDIRIAN (mis. hasil 'wget bit.ly/...'),
#   script ini otomatis mengunduh file pendukung (common + bagian1..8 +
#   ooklaserver.sh) ke BASE_DIR dari repository, lalu menjalankannya.
###############################################################################
set -euo pipefail

# Sumber file pendukung (bisa di-override via env REPO_RAW_BASE).
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/smahud/speedtest/main}"
export REPO_RAW_BASE

SUPPORT_FILES="
common_functions1.sh
bagian0.sh
bagian1_install_dependency.sh
bagian2_install_ooklaserver.sh
bagian3_install_certbot.sh
bagian4_install_server_certificate.sh
bagian5_update_ooklaserver.sh
bagian6_automaintenance.sh
bagian7_network.sh
bagian8_cek_konfigurasi.sh
ooklaserver.sh
"

# --- Tentukan direktori script ini (bukan CWD) ---------------------------------
SPEEDTEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
export SPEEDTEST_SCRIPT_DIR

# --- Bootstrap minimal logging (sebelum common tersedia) ----------------------
_boot_info()  { printf '[INFO] %s\n' "$1"; }
_boot_err()   { printf '[ERROR] %s\n' "$1" >&2; }
_boot_die()   { _boot_err "$1"; exit "${2:-1}"; }

# Pengunduh lintas tool (wget/curl).
_fetch() {
    # $1 = url, $2 = dest
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    else
        return 127
    fi
}

# Harus root.
if [ "$(id -u)" -ne 0 ]; then
    _boot_die "Script ini harus dijalankan sebagai root (gunakan sudo)."
fi

# --- Tentukan lokasi data.ini SEBELUM bootstrap ------------------------------
# Prioritas: argumen -> CWD -> direktori script.
ARG_CFG="${1:-}"
CONFIG_PATH=""
if [ -n "$ARG_CFG" ]; then
    if [ -d "$ARG_CFG" ]; then ARG_CFG="$ARG_CFG/data.ini"; fi
    [ -f "$ARG_CFG" ] || _boot_die "data.ini tidak ditemukan: '$ARG_CFG'"
    CONFIG_PATH="$(cd "$(dirname "$ARG_CFG")" && pwd)/$(basename "$ARG_CFG")"
elif [ -f "$PWD/data.ini" ]; then
    CONFIG_PATH="$PWD/data.ini"
elif [ -f "$SPEEDTEST_SCRIPT_DIR/data.ini" ]; then
    CONFIG_PATH="$SPEEDTEST_SCRIPT_DIR/data.ini"
else
    _boot_err "data.ini tidak ditemukan."
    _boot_err "Prioritas pencarian: (1) argumen, (2) CWD '$PWD', (3) '$SPEEDTEST_SCRIPT_DIR'."
    _boot_err "Letakkan data.ini di direktori ini lalu jalankan ulang, atau:"
    _boot_err "  ./install.sh /path/ke/data.ini"
    exit 1
fi
BASE_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
export CONFIG_PATH BASE_DIR

# --- Pastikan wget/curl tersedia untuk bootstrap (best effort) ----------------
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    _boot_info "wget/curl belum ada, mencoba memasang..."
    if command -v apk >/dev/null 2>&1; then apk add --no-cache wget >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y wget >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then dnf install -y wget >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then yum install -y wget >/dev/null 2>&1 || true
    fi
fi

# --- Self-bootstrap: unduh/perbarui file pendukung ke BASE_DIR -----------------
ensure_support_files() {
    local f
    _boot_info "Menyelaraskan file pendukung di BASE_DIR..."
    for f in $SUPPORT_FILES; do
        # JANGAN menimpa install.sh yang sedang berjalan secara langsung (Self-Overwrite Bug)
        if [ "$f" = "install.sh" ] && [ -f "$BASE_DIR/install.sh" ]; then
            # Cek apakah file yang dijalankan adalah file ini
            if [ "$SPEEDTEST_SCRIPT_DIR/install.sh" = "$BASE_DIR/install.sh" ]; then
                continue
            fi
        fi

        # Prioritas: 
        # 1. Jika ada di direktori script saat ini (dan bukan BASE_DIR), salin.
        if [ "$SPEEDTEST_SCRIPT_DIR" != "$BASE_DIR" ] && [ -f "$SPEEDTEST_SCRIPT_DIR/$f" ]; then
            cp -f "$SPEEDTEST_SCRIPT_DIR/$f" "$BASE_DIR/$f"
        else
            # 2. Unduh dari repo
            _boot_info "Mengunduh $f ..."
            _fetch "$REPO_RAW_BASE/$f" "$BASE_DIR/$f" || {
                if [ ! -f "$BASE_DIR/$f" ]; then
                    _boot_die "Gagal mengunduh $f dan file lokal tidak ada."
                fi
                _boot_err "Gagal memperbarui $f, menggunakan versi yang ada."
            }
        fi
    done
    chmod a+x "$BASE_DIR"/*.sh 2>/dev/null || true
    return 0
}
ensure_support_files

# Mulai sekarang, jalankan dari BASE_DIR sebagai "rumah" script.
SPEEDTEST_SCRIPT_DIR="$BASE_DIR"
export SPEEDTEST_SCRIPT_DIR

# --- Muat pustaka bersama ------------------------------------------------------
[ -f "$BASE_DIR/common_functions1.sh" ] || _boot_die "common_functions1.sh tidak ada di $BASE_DIR."
# shellcheck source=common_functions1.sh
. "$BASE_DIR/common_functions1.sh"

# Verifikasi integritas pustaka
if ! command -v check_resources >/dev/null 2>&1; then
    _boot_err "Pustaka common_functions1.sh tidak dimuat dengan benar atau versi lama terdeteksi."
    _boot_info "Mencoba pembersihan sisa file lama..."
    rm -f "$BASE_DIR/common_functions1.sh"
    ensure_support_files
    . "$BASE_DIR/common_functions1.sh"
fi

# Re-resolve secara resmi (mengisi semua variabel path turunan).
resolve_config_path "$CONFIG_PATH"
init_paths

log_info "==================================================="
log_info " Installer Speedtest OoklaServer"
log_info " CONFIG_PATH : $CONFIG_PATH"
log_info " BASE_DIR    : $BASE_DIR"
log_info " LOG_FILE    : $LOG_FILE"
log_info "==================================================="

detect_os
detect_init

# --- Periksa Sumber Daya ---
if command -v check_resources >/dev/null 2>&1; then
    check_resources || die "Sumber daya sistem tidak mencukupi."
else
    log_warn "Fungsi check_resources tidak ditemukan, melewati pemeriksaan sumber daya."
fi

# --- Update index & install dependency dasar ----------------------------------
log_info "Memperbarui index paket & memasang dependency dasar..."
pkg_update

CRON_PKG="cron"
case "$PKG_MGR" in
    apt)            CRON_PKG="cron" ;;
    dnf|yum|zypper) CRON_PKG="cronie" ;;
    apk)            CRON_PKG="cronie" ;;
esac

for pkg in bash git curl tar wget jq ca-certificates iptables "$CRON_PKG"; do
    if ! pkg_install "$pkg" >/dev/null 2>&1; then
        log_warn "Paket '$pkg' gagal/ tidak tersedia di $PKG_MGR (dilewati)."
    fi
done
log_ok "Dependency dasar selesai diproses."

# --- Validasi data.ini sebelum melanjutkan ------------------------------------
load_and_validate_config

# Keamanan: data.ini bisa berisi token Cloudflare -> ketatkan permission.
chmod 600 "$CONFIG_PATH" 2>/dev/null || true

# Tulis state instalasi (dipakai oleh management script).
write_state() {
    cat > "$STATE_FILE" <<EOF
# State instalasi Speedtest OoklaServer (auto-generated). JANGAN EDIT MANUAL.
BASE_DIR="$BASE_DIR"
CONFIG_PATH="$CONFIG_PATH"
SCRIPT_DIR="$BASE_DIR"
OOKLA_SCRIPT="$OOKLA_SCRIPT"
OOKLA_BIN="$OOKLA_BIN"
OOKLA_PROPERTIES="$OOKLA_PROPERTIES"
INIT_SYSTEM="$INIT_SYSTEM"
DOMAIN="$Domain"
INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}
write_state

# --- Eksekusi tiap bagian ------------------------------------------------------
section_path() {
    local name="$1"
    if [ -f "$BASE_DIR/$name.sh" ]; then
        printf '%s' "$BASE_DIR/$name.sh"
    else
        printf ''
    fi
}

run_section() {
    local name="$1"
    local path
    path="$(section_path "$name")"
    print_hash 50
    if [ -z "$path" ]; then
        log_warn "File $name.sh tidak ditemukan, lewati bagian ini."
        return 0
    fi
    log_info ">> Menjalankan $name"
    # Bagian4 (sertifikat) bisa interaktif (mode non-Cloudflare): JANGAN
    # redirect stdin-nya. Bagian lain non-interaktif.
    if bash "$path" "$CONFIG_PATH"; then
        log_ok "<< $name selesai"
    else
        die "Bagian $name GAGAL. Lihat log: $LOG_FILE"
    fi
    print_hash 50
}

run_section "bagian0"
run_section "bagian1_install_dependency"
run_section "bagian2_install_ooklaserver"
run_section "bagian3_install_certbot"
run_section "bagian4_install_server_certificate"
run_section "bagian5_update_ooklaserver"
run_section "bagian6_automaintenance"
if [ "$AktifkanZeroTier" = "Ya" ]; then
    run_section "bagian7_network"
else
    log_info "ZeroTier dinonaktifkan via data.ini (AktifkanZeroTier=Tidak), lewati bagian7."
fi
run_section "bagian8_cek_konfigurasi"

# --- Auto-restart final (pengganti '/root/ooklaserver.sh restart') ------------
log_info "Melakukan restart final OoklaServer dari lokasi instalasi..."
if [ -x "$OOKLA_SCRIPT" ]; then
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || log_warn "Restart final mengembalikan error (cek status)."
fi

print_hash 50
log_ok "INSTALASI SELESAI."
log_info "BASE_DIR        : $BASE_DIR"
log_info "Properties      : $OOKLA_PROPERTIES"
log_info "Management tool : $BASE_DIR/speedtestctl.sh"
log_info ""
log_info "Tidak perlu lagi menjalankan '/root/ooklaserver.sh restart' — sudah otomatis."
log_info "Perintah management (jalan dari mana saja):"
log_info "  $BASE_DIR/speedtestctl.sh status"
log_info "  $BASE_DIR/speedtestctl.sh restart"
log_info "  $BASE_DIR/speedtestctl.sh stop"
log_info "  $BASE_DIR/speedtestctl.sh start"
log_info "  $BASE_DIR/speedtestctl.sh uninstall"
print_hash 50
