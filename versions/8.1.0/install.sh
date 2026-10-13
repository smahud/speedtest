#!/usr/bin/env bash
###############################################################################
# install.sh — Installer Speedtest OoklaServer (end-to-end, satu perintah)
#
# CARA PAKAI (server baru):
#   1) Siapkan direktori kerja dan data.ini:
#        mkdir -p /opt/speedtest && cd /opt/speedtest
#        cp data.ini.example data.ini && nano data.ini
#   2) Jalankan installer (pilih salah satu):
#        a) satu perintah (self-bootstrap):
#             curl -fsSL https://raw.githubusercontent.com/smahud/speedtest/main/install.sh | sudo bash
#        b) atau unduh lalu jalankan:
#             sudo curl -fsSL -o install.sh <URL install.sh>
#             sudo bash install.sh
#        c) atau tunjuk data.ini secara eksplisit:
#             sudo bash install.sh /opt/speedtest/data.ini
#
#   Semua dependency (bash, curl/wget, tar, jq, ca-certificates, cron, iptables,
#   speedtest CLI, certbot(+plugin Cloudflare), ZeroTier, openssh-server) dan
#   seluruh file pendukung (common + bagian0..11) dipasang OTOMATIS.
#
# Aturan penentuan data.ini (CONFIG_PATH):
#   1) Argumen pertama bila diberikan.
#   2) Current working directory (disarankan: direktori berisi data.ini).
#   3) Direktori tempat install.sh berada (bila dijalankan sebagai file).
#
# Semua file relatif aplikasi mengikuti BASE_DIR = direktori tempat data.ini.
#
# URUTAN EKSEKUSI (tidak ada yang saling menimpa):
#   bootstrap file → dependency → validasi → self-update (sekali)
#   → bagian0 banner → 1 dependency → 2 OoklaServer → 3 certbot
#   → 4 sertifikat → 5 properties+cert → 6 cron report → 8 service+verifikasi
#   → 9 SSH keys+sshd → 10 /etc/hosts+penegakan SSH → 11 cron self-update
#   → 7 ZeroTier (WAJIB, terakhir) → restart final
###############################################################################
set -euo pipefail

# ── Sumber file pendukung ────────────────────────────────────────────────────
# BASE_REPO  : repo utama (dipakai membaca VERSION & bootstrap pertama).
# REPO_RAW_BASE: sumber efektif. Bila tidak di-override, dipakai snapshot
#                versions/<VERSION>/ agar rilis tidak berubah di tengah jalan.
BASE_REPO="${BASE_REPO:-https://raw.githubusercontent.com/smahud/speedtest/main}"
REPO_RAW_BASE="${REPO_RAW_BASE:-}"
REPO_RAW_BASE_FROM_ENV=0
if [ -n "$REPO_RAW_BASE" ]; then
  REPO_RAW_BASE_FROM_ENV=1
fi

# File yang wajib ada setelah bootstrap (selain daftar di bawah).
SUPPORT_FILES="
VERSION
MANIFEST
checksums.sha256
speedtest-repo.conf
common_functions1.sh
auto_update_lib.sh
bagian0.sh
bagian1_install_dependency.sh
bagian2_install_ooklaserver.sh
bagian3_install_certbot.sh
bagian4_install_server_certificate.sh
bagian5_update_ooklaserver.sh
bagian6_automaintenance.sh
bagian7_network.sh
bagian8_cek_konfigurasi.sh
bagian9_ssh_access.sh
bagian10_hosts_ssh.sh
bagian11_self_update.sh
install.sh
ooklaserver.sh
uninstall.sh
speedtest-selfupdate.sh
"

# File yang boleh gagal diunduh (metadata opsional).
OPTIONAL_FILES=" MANIFEST checksums.sha256 VERSION install.sh "

# ── Logging bootstrap (sebelum common tersedia) ──────────────────────────────
_boot_info()  { printf '[INFO] %s\n' "$1"; }
_boot_ok()    { printf '[OK] %s\n' "$1"; }
_boot_err()   { printf '[ERROR] %s\n' "$1" >&2; }
_boot_warn()  { printf '[WARN] %s\n' "$1" >&2; }
_boot_die()   { _boot_err "$1"; exit "${2:-1}"; }

# Pengunduh ATOMIK: unduh ke .tmp lalu mv (file lama tidak pernah dirusak).
# $1=url $2=dest $3=direct(1=tulis langsung, untuk .sha256)
_fetch() {
  local url="$1" dest="$2" direct="${3:-0}" rc=0 tmp
  if [ "$direct" = "1" ]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --max-time 120 -o "$dest" "$url" || rc=$?
    elif command -v wget >/dev/null 2>&1; then
      wget -q -T 120 -O "$dest" "$url" || rc=$?
    else
      return 127
    fi
    if [ "$rc" -ne 0 ]; then rm -f "$dest" 2>/dev/null || true; fi
    return "$rc"
  fi

  tmp="${dest}.tmp.$$"
  rm -f "$tmp" 2>/dev/null || true
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 120 -o "$tmp" "$url" || rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 120 -O "$tmp" "$url" || rc=$?
  else
    return 127
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then rc=1; fi
    return "$rc"
  fi
  chmod --reference="$dest" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest" || return 1
  return 0
}

_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v busybox >/dev/null 2>&1; then busybox sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else printf ''
  fi
}

# Harus root (juga berlaku untuk `curl ... | sudo bash`).
if [ "$(id -u)" -ne 0 ]; then
  _boot_err "Installer ini harus dijalankan sebagai root."
  _boot_err "Contoh: curl -fsSL <URL install.sh> | sudo bash"
  exit 1
fi

# ── Deteksi mode jalan: sebagai file atau via pipe (curl | bash) ──────────────
_SELF_SRC="${BASH_SOURCE[0]:-$0}"
SELF_MODE="file"
if [ -n "$_SELF_SRC" ] && [ "$_SELF_SRC" != "bash" ] && [ "$_SELF_SRC" != "-" ] && [ -e "$_SELF_SRC" ]; then
  SPEEDTEST_SCRIPT_DIR="$(cd "$(dirname "$_SELF_SRC")" >/dev/null 2>&1 && pwd)" || SPEEDTEST_SCRIPT_DIR="$PWD"
else
  # Dijalankan via pipe: tidak ada file script → pakai CWD sebagai lokasi kerja.
  SPEEDTEST_SCRIPT_DIR="$PWD"
  SELF_MODE="piped"
fi
export SPEEDTEST_SCRIPT_DIR SELF_MODE

# --- Tentukan lokasi data.ini ---
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
  _boot_err "Prioritas: (1) argumen, (2) CWD '$PWD', (3) direktori script '$SPEEDTEST_SCRIPT_DIR'."
  _boot_err "Siapkan data.ini lebih dulu, contoh:"
  _boot_err "  mkdir -p /opt/speedtest && cd /opt/speedtest"
  _boot_err "  curl -fsSL <URL data.ini.example> -o data.ini && nano data.ini"
  exit 1
fi
BASE_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"
export CONFIG_PATH BASE_DIR

# --- Pastikan wget/curl tersedia untuk bootstrap ---
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  _boot_info "wget/curl belum ada, mencoba memasang..."
  if command -v apk >/dev/null 2>&1; then apk add --no-cache curl >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y curl >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -y curl >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then yum install -y curl >/dev/null 2>&1 || true
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Bila dipanggil via pipe, tulis salinan install.sh ke BASE_DIR supaya
# self-update (cron) bisa menjalankannya kembali.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SELF_MODE" = "piped" ] && [ ! -f "$BASE_DIR/install.sh" ]; then
  _boot_info "Mode pipe terdeteksi: menyiapkan salinan install.sh di BASE_DIR..."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Tentukan REPO_RAW_BASE efektif (hormati override env untuk fork/uji)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$REPO_RAW_BASE_FROM_ENV" != "1" ]; then
  REPO_RAW_BASE="$BASE_REPO"
  _V_TMP="$BASE_DIR/.version-probe.$$"
  if _fetch "$BASE_REPO/VERSION" "$_V_TMP" 2>/dev/null; then
    REPO_VERSION_NEW="$(head -1 "$_V_TMP" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "$REPO_VERSION_NEW" ]; then
      _V_PINNED="$BASE_REPO/versions/$REPO_VERSION_NEW"
      if _fetch "$_V_PINNED/VERSION" "$BASE_DIR/.version-pin-probe.$$" 2>/dev/null; then
        REPO_RAW_BASE="$_V_PINNED"
        _boot_info "Memakai snapshot rilis imutabel: $REPO_RAW_BASE"
      else
        _boot_info "Snapshot versi belum tersedia; memakai: $REPO_RAW_BASE"
      fi
      rm -f "$BASE_DIR/.version-pin-probe.$$" 2>/dev/null || true
    fi
  else
    _boot_warn "Tidak bisa membaca VERSION dari repo (jaringan?) — memakai $REPO_RAW_BASE"
  fi
  rm -f "$_V_TMP" 2>/dev/null || true
fi
export REPO_RAW_BASE

# ─────────────────────────────────────────────────────────────────────────────
# Self-bootstrap: sinkronkan file pendukung ke BASE_DIR (anti-korupsi)
#   staged → verifikasi .sha256 → uji sintaks → baru dipasang (mv)
#   Unduhan gagal TIDAK merusak file lama; file rusak tidak pernah dipasang.
# ─────────────────────────────────────────────────────────────────────────────
ensure_support_files() {
  local f stage="$BASE_DIR/.bootstrap-staging" dl=0 kept=0 missing="" bad=""
  rm -rf "$stage" 2>/dev/null || true
  mkdir -p "$stage" 2>/dev/null || _boot_die "Gagal membuat staging di $BASE_DIR"
  chmod 700 "$stage" 2>/dev/null || true

  _boot_info "Menyelaraskan file pendukung dari: $REPO_RAW_BASE"

  for f in $SUPPORT_FILES; do
    # 1) Salinan lokal (direktori script berbeda dari BASE_DIR) → prioritas.
    if [ "$SPEEDTEST_SCRIPT_DIR" != "$BASE_DIR" ] && [ -f "$SPEEDTEST_SCRIPT_DIR/$f" ]; then
      cp -f "$SPEEDTEST_SCRIPT_DIR/$f" "$stage/$f" 2>/dev/null || true
      continue
    fi
    # 2) Unduh ke staging.
    if _fetch "$REPO_RAW_BASE/$f" "$stage/$f" 2>/dev/null; then
      dl=$((dl + 1))
      # Verifikasi checksum per-file bila tersedia.
      if _fetch "$REPO_RAW_BASE/$f.sha256" "$stage/$f.sha256" 1 2>/dev/null && [ -s "$stage/$f.sha256" ]; then
        _want="$(awk 'NR==1{print $1}' "$stage/$f.sha256" 2>/dev/null || true)"
        _got="$(_sha256_of "$stage/$f")"
        if [ -n "$_want" ] && [ -n "$_got" ] && [ "$_want" != "$_got" ]; then
          _boot_err "Checksum TIDAK cocok: $f — file ini ditolak."
          rm -f "$stage/$f" "$stage/$f.sha256" 2>/dev/null || true
          bad="$bad $f"
          if [ -f "$BASE_DIR/$f" ]; then
            cp -f "$BASE_DIR/$f" "$stage/$f" 2>/dev/null || true
            _boot_warn "Memakai versi lama yang ada di $BASE_DIR."
          fi
          continue
        fi
      fi
      rm -f "$stage/$f.sha256" 2>/dev/null || true
      continue
    fi
    # 3) Unduhan gagal → pakai file lama bila ada.
    if [ -f "$BASE_DIR/$f" ]; then
      cp -f "$BASE_DIR/$f" "$stage/$f" 2>/dev/null || true
      kept=$((kept + 1))
      _boot_warn "Gagal mengunduh $f — memakai versi lokal."
    else
      case "$OPTIONAL_FILES" in *" $f "*) : ;; *) missing="$missing $f" ;; esac
    fi
  done

  # Uji sintaks; file rusak dibuang, versi lama dipertahankan.
  for f in "$stage"/*.sh; do
    [ -e "$f" ] || continue
    _base="$(basename "$f")"
    _ok=0
    if bash -n "$f" >/dev/null 2>&1; then _ok=1; fi
    if [ "$_ok" -eq 0 ] && sh -n "$f" >/dev/null 2>&1; then _ok=1; fi
    if [ "$_ok" -eq 0 ]; then
      _boot_err "File baru '$_base' tidak lolos uji sintaks — dibuang."
      rm -f "$f" 2>/dev/null || true
      bad="$bad $_base"
      if [ -f "$BASE_DIR/$_base" ]; then
        cp -f "$BASE_DIR/$_base" "$stage/$_base" 2>/dev/null || true
      else
        missing="$missing $_base"
      fi
    fi
  done

  # Pasang (mv = atomik per file)
  for f in $SUPPORT_FILES; do
    [ -f "$stage/$f" ] || continue
    mv -f "$stage/$f" "$BASE_DIR/$f" 2>/dev/null || _boot_warn "Gagal memasang $f"
  done
  rm -rf "$stage" 2>/dev/null || true
  chmod a+x "$BASE_DIR"/*.sh 2>/dev/null || true

  _boot_ok "File pendukung siap (diunduh: $dl, dari lokal: $kept)."
  if [ -n "$missing" ]; then
    _boot_die "File wajib berikut tidak tersedia:$missing — periksa koneksi/repo lalu ulangi."
  fi
  if [ -n "$bad" ]; then
    _boot_warn "File yang ditolak (versi lama dipakai bila ada):$bad"
  fi
  return 0
}
ensure_support_files

# Mulai sekarang BASE_DIR adalah "rumah" script.
SPEEDTEST_SCRIPT_DIR="$BASE_DIR"
export SPEEDTEST_SCRIPT_DIR

# --- Muat pustaka bersama ---
[ -f "$BASE_DIR/common_functions1.sh" ] || _boot_die "common_functions1.sh tidak ada di $BASE_DIR."
# shellcheck source=common_functions1.sh
. "$BASE_DIR/common_functions1.sh"

if ! command -v check_resources >/dev/null 2>&1; then
  _boot_err "Pustaka common_functions1.sh tidak dimuat dengan benar."
  rm -f "$BASE_DIR/common_functions1.sh"
  ensure_support_files
  # shellcheck source=common_functions1.sh
  . "$BASE_DIR/common_functions1.sh"
fi

resolve_config_path "$CONFIG_PATH"
init_paths

log_info "==================================================="
log_info " Installer Speedtest OoklaServer"
log_info " CONFIG_PATH : $CONFIG_PATH"
log_info " BASE_DIR    : $BASE_DIR"
log_info " REPO        : $REPO_RAW_BASE"
log_info " MODE        : $SELF_MODE"
log_info " LOG_FILE    : $LOG_FILE"
log_info "==================================================="

detect_os
detect_init

if command -v check_resources >/dev/null 2>&1; then
  check_resources || die "Sumber daya sistem tidak mencukupi."
fi

# --- Dependency dasar ---
log_info "Memperbarui index paket & memasang dependency dasar..."
pkg_update

CRON_PKG="cron"
case "$PKG_MGR" in
  apt) CRON_PKG="cron" ;;
  dnf|yum|zypper) CRON_PKG="cronie" ;;
  apk) CRON_PKG="cronie" ;;
esac

BASE_PKGS="bash curl wget tar jq ca-certificates"
for pkg in $BASE_PKGS "$CRON_PKG"; do
  if ! pkg_install "$pkg" >/dev/null 2>&1; then
    log_warn "Paket '$pkg' gagal/tidak tersedia di $PKG_MGR (dilewati)."
  fi
done
# Paket opsional (best-effort). Semua pemakaian di skrip sudah diberi guard,
# jadi kegagalan di sini hanya menonaktifkan fitur terkait, bukan instalasi.
#   iptables → NAT/forwarding ZeroTier (mode exit node)
#   procps   → pgrep (cek proses OoklaServer/sshd di beberapa distrik minimal)
#   openssl  → pemantau masa berlaku sertifikat (mode DNS manual)
for _extra in iptables procps openssl; do
  pkg_install "$_extra" >/dev/null 2>&1 || log_warn "Paket '$_extra' tidak tersedia (fitur terkait dilewati bila tak ada)."
done
log_ok "Dependency dasar selesai diproses."

# Pemasangan paket cron TIDAK otomatis menjalankan daemon-nya, terutama di
# image minimal/container. Tanpa langkah ini cron reporting, self-update harian,
# boot-sync, dan moon updater tidak akan pernah dieksekusi.
ensure_cron_service() {
  local unit started=""
  # Coba langsung 'enable --now' lalu verifikasi 'is-active'. Tidak memakai
  # 'systemctl list-unit-files' agar tetap akurat di container/minimal image
  # yang tidak punya daftar unit lengkap.
  for unit in cron crond cronie; do
    case "${INIT_SYSTEM:-}" in
      systemd)
        systemctl enable --now "${unit}.service" >/dev/null 2>&1 || true
        if systemctl is-active "${unit}.service" >/dev/null 2>&1; then started="$unit"; break; fi
        ;;
      openrc)
        if [ -x "/etc/init.d/$unit" ]; then
          rc-update add "$unit" default >/dev/null 2>&1 || true
          if rc-service "$unit" start >/dev/null 2>&1; then started="$unit"; break; fi
        fi
        ;;
      *)
        if command -v service >/dev/null 2>&1 && service "$unit" start >/dev/null 2>&1; then
          started="$unit"; break
        fi
        ;;
    esac
  done
  if [ -n "$started" ]; then
    log_ok "Layanan cron aktif: $started (cron reporting + self-update otomatis berjalan)."
  else
    log_warn "Layanan cron belum dapat dipastikan aktif. Cek manual setelah instalasi:"
    log_warn "  Debian/Ubuntu: systemctl status cron   | Alpine: rc-service crond status"
  fi
}
export INIT_SYSTEM
ensure_cron_service

# --- Validasi data.ini ---
load_and_validate_config
chmod 600 "$CONFIG_PATH" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# SELF-UPDATE (satu kali, sebelum bagian dijalankan)
#   - memastikan instalasi memakai versi script terbaru dari repo
#   - bila ada file yang berubah, installer menjalankan ULANG dirinya sendiri
#     (re-exec) agar tidak ada versi campur-aduk (old script + new library)
# ─────────────────────────────────────────────────────────────────────────────
if [ "${AUTO_UPDATE_ENABLED:-Ya}" = "Ya" ] && [ -f "$BASE_DIR/auto_update_lib.sh" ]; then
  log_info "Memeriksa pembaruan script dari repo..."
  # shellcheck source=auto_update_lib.sh
  . "$BASE_DIR/auto_update_lib.sh"
  au_load_repo_config "$BASE_DIR" >/dev/null
  if [ "$REPO_RAW_BASE_FROM_ENV" != "1" ]; then
    REPO_RAW_BASE="${REPO_RAW_BASE_DEFAULT:-$BASE_REPO}"
  fi
  export REPO_RAW_BASE

  UPDATE_RC=0
  au_self_update_core "$BASE_DIR" "$REPO_RAW_BASE" 1 || UPDATE_RC=$?

  if [ "$UPDATE_RC" = "0" ] && [ "${SPEEDTEST_REEXEC:-0}" != "1" ] && [ -f "$BASE_DIR/install.sh" ]; then
    log_info "Script diperbarui — menjalankan ulang installer versi baru (sekali)..."
    export SPEEDTEST_REEXEC=1
    exec bash "$BASE_DIR/install.sh" "$CONFIG_PATH"
  fi

  # Muat ulang pustaka & konfigurasi hasil update (tanpa re-exec).
  unset SPEEDTEST_COMMON_LOADED
  # shellcheck source=common_functions1.sh
  . "$BASE_DIR/common_functions1.sh"
  # shellcheck source=auto_update_lib.sh
  . "$BASE_DIR/auto_update_lib.sh"
  resolve_config_path "$CONFIG_PATH"
  init_paths
  load_and_validate_config
  detect_init
  log_ok "Script instalasi sudah memakai versi terbaru."
else
  log_info "Self-update pre-install dilewati (AUTO_UPDATE_ENABLED=Tidak)."
fi

# --- State instalasi (dipakai management tool & uninstall) ---
write_state() {
  cat > "$STATE_FILE" <<STATEOF
# Speedtest Install State - generated by install.sh (jangan diedit manual)
CONFIG_PATH=$CONFIG_PATH
BASE_DIR=$BASE_DIR
OOKLA_SCRIPT=$OOKLA_SCRIPT
OOKLA_BIN=$OOKLA_BIN
OOKLA_PROPERTIES=$OOKLA_PROPERTIES
OOKLA_PIDFILE=$OOKLA_PIDFILE
INIT_SYSTEM=$INIT_SYSTEM
REPO_RAW_BASE=$REPO_RAW_BASE
VERSION=$(head -1 "$BASE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || printf 'unknown')
STATEOF
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}
write_state

# --- Eksekusi tiap bagian ---
section_path() {
  local name="$1"
  if [ -f "$BASE_DIR/$name.sh" ]; then printf '%s' "$BASE_DIR/$name.sh"; else printf ''; fi
}

run_section() {
  local name="$1" path
  path="$(section_path "$name")"
  print_hash 50
  if [ -z "$path" ]; then
    log_warn "File $name.sh tidak ditemukan, lewati bagian ini."
    return 0
  fi
  log_info ">> Menjalankan $name"
  # Tolak file kosong/rusak (indikasi unduhan buruk) — jangan dianggap "selesai".
  if [ ! -s "$path" ] || ! head -c 64 "$path" | grep -q '^#!'; then
    die "Bagian $name GAGAL: file $name.sh kosong/tidak valid."
  fi
  # Bagian4 perlu TTY untuk mode non-Cloudflare → jangan redirect stdin.
  if bash "$path" "$CONFIG_PATH"; then
    log_ok "<< $name selesai"
  else
    local rc=$?
    die "Bagian $name GAGAL (rc=$rc). Lihat log: $LOG_FILE"
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
run_section "bagian8_cek_konfigurasi"

# Bagian9 mengatur ulang akses SSH (kunci GitHub + sshd). Dilindungi TTY agar
# tidak mengunci akses bila dijalankan otomatis tanpa terminal.
if [ -t 0 ] || [ -c /dev/tty ]; then
  run_section "bagian9_ssh_access"
else
  log_warn "Tanpa TTY: bagian9 (SSH) DITUNDA. Akan diterapkan otomatis oleh"
  log_warn "boot-sync (@reboot → bagian10 -postboot) dan/atau bagian10 di bawah (bila mungkin)."
fi

run_section "bagian10_hosts_ssh"
run_section "bagian11_self_update"

# Bagian7 dijalankan TERAKHIR: ZeroTier WAJIB (jaringan kontrol operator).
# Bila node belum di-authorize, instalasi berhenti dengan pesan jelas — semua
# komponen lain sudah terpasang dan akan dicoba ulang oleh self-update berkala.
run_section "bagian7_network"

# Pastikan script cron executable.
chmod a+x "$BASE_DIR/speedtest-selfupdate.sh" "$BASE_DIR/bagian10_hosts_ssh.sh" \
          "$BASE_DIR/bagian7_network.sh" 2>/dev/null || true

# --- Restart final ---
log_info "Melakukan restart final OoklaServer dari lokasi instalasi..."
if [ -x "$OOKLA_SCRIPT" ]; then
  ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || log_warn "Restart final mengembalikan error (cek status)."
fi

# Nilai dari data.ini (dipakai di ringkasan & verifikasi akhir).
Domain="${Domain:-}"

# ── Verifikasi akhir otomatis (satu perintah install = langsung terbukti) ────
verify_final() {
  local c="" tag unit cron_unit="" ok_ip=""
  print_hash 50
  log_info "VERIFIKASI AKHIR (otomatis, tanpa perlu cek manual):"

  # 1) OoklaServer
  if pgrep -x OoklaServer >/dev/null 2>&1 \
     || { command_exists ss && ss -tln 2>/dev/null | grep -q ':8080 '; } \
     || { command_exists netstat && netstat -tln 2>/dev/null | grep -q ':8080 '; }; then
    log_ok "  [OK]   OoklaServer berjalan (port 8080)."
  else
    log_warn "  [WARN] OoklaServer belum terdeteksi — jalankan: $BASE_DIR/speedtestctl.sh restart"
  fi

  # 2) Mapping RegisteredSpeedtestURL → localhost
  ok_ip="${HOSTS_TARGET_IP:-127.0.0.1}"
  if [ -f "${HOSTS_FILE:-/etc/hosts}" ] \
     && grep -qF "${HOSTS_MARKER:-speedtest-managed}" "${HOSTS_FILE:-/etc/hosts}" 2>/dev/null; then
    log_ok "  [OK]   Mapping ${Domain} → ${ok_ip} aktif di ${HOSTS_FILE:-/etc/hosts}."
  else
    log_warn "  [WARN] Mapping hosts belum ada — cek: bash $BASE_DIR/bagian10_hosts_ssh.sh"
  fi

  # 3) Akses SSH (kunci GitHub + sshd)
  if [ -f /root/.ssh/authorized_keys ] \
     && grep -qF "# BEGIN ${SSH_MARKER:-speedtest-managed-keys}" /root/.ssh/authorized_keys 2>/dev/null; then
    log_ok "  [OK]   Kunci SSH (${SSH_KEYS_URL:-github.com/smahud.keys}) terpasang untuk root."
  else
    log_warn "  [WARN] Kunci SSH belum terpasang — cek: bash $BASE_DIR/bagian9_ssh_access.sh"
  fi

  # 4) Cron: entri wajib + daemon aktif
  if command_exists crontab; then
    c="$(crontab -l 2>/dev/null || true)"
    for tag in "# speedtest-report (managed)" "# speedtest-autoupdate (managed)" "# speedtest-boot-sync (managed)"; do
      case "$c" in
        *"$tag"*) log_ok "  [OK]   Cron terpasang: $tag" ;;
        *)        log_warn "  [WARN] Cron tidak ditemukan: $tag" ;;
      esac
    done
    for unit in cron crond cronie; do
      if command_exists systemctl && systemctl is-active "$unit" >/dev/null 2>&1; then cron_unit="$unit"; break; fi
      if command_exists rc-service && rc-service "$unit" status >/dev/null 2>&1; then cron_unit="$unit"; break; fi
    done
    if [ -n "$cron_unit" ]; then
      log_ok "  [OK]   Daemon cron aktif: $cron_unit"
    else
      log_warn "  [WARN] Daemon cron belum terdeteksi aktif (jadwal tidak akan jalan)."
    fi
  else
    log_warn "  [WARN] crontab tidak tersedia — penjadwalan otomatis tidak aktif."
  fi

  # 5) ZeroTier (wajib) — bagian7 sudah memverifikasi; ini konfirmasi ringkas.
  if command_exists zerotier-cli \
     && zerotier-cli listnetworks 2>/dev/null | grep -q "${ZT_NETWORK_ID:-__none__}"; then
    log_ok "  [OK]   ZeroTier terhubung ke network ${ZT_NETWORK_ID:-?}."
  else
    log_warn "  [WARN] ZeroTier belum terhubung — cek: zerotier-cli listnetworks"
  fi

  # 6) Self-update otomatis siap
  if [ -x "$BASE_DIR/speedtest-selfupdate.sh" ]; then
    log_ok "  [OK]   Self-update otomatis siap (cron harian + boot-sync)."
  else
    log_warn "  [WARN] speedtest-selfupdate.sh tidak ada di $BASE_DIR."
  fi
}
verify_final

print_hash 50
log_ok "INSTALASI SELESAI."
log_info "BASE_DIR        : $BASE_DIR"
log_info "Versi script    : $(head -1 "$BASE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || printf 'unknown')"
log_info "Management tool : $BASE_DIR/speedtestctl.sh"
log_info "Self-update     : $BASE_DIR/speedtest-selfupdate.sh (cron harian otomatis)"
log_info "Cek pembaruan   : bash $BASE_DIR/speedtest-selfupdate.sh --dry-run"
log_info "Cleanup total   : bash $BASE_DIR/uninstall.sh"
log_info ""
log_info "ZeroTier (wajib, hardcode di speedtest-repo.conf):"
log_info "  Network ID : ${ZT_NETWORK_ID:-?}"
log_info "  Status     : $(command -v zerotier-cli >/dev/null 2>&1 && zerotier-cli listnetworks 2>/dev/null | grep "${ZT_NETWORK_ID:-x}" || echo 'cek: zerotier-cli listnetworks')"
log_info ""
log_info "Perintah management (bisa dari mana saja):"
log_info "  $BASE_DIR/speedtestctl.sh status|start|stop|restart|logs|uninstall"
print_hash 50
