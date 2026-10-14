#!/usr/bin/env bash
###############################################################################
# auto_update_lib.sh — Pustaka BERSAMA untuk self-update, dipakai oleh:
#   - install.sh              (self-update di awal proses instalasi)
#   - speedtest-selfupdate.sh (cron / manual)
#
# CATATAN PENTING: seluruh fungsi di sini AMAN dijalankan di bawah `set -e`.
# Hindari pola `[ test ] && perintah` di level statement dan command
# substitution yang bisa gagal — keduanya akan mematikan pemanggil.
#
# Alur update ANTI-KORUPSI:
#   1. Unduh semua file + pasangan .sha256 ke direktori staging.
#   2. Verifikasi SHA-256.
#   3. Uji sintaks (bash -n / sh -n).
#   4. Bandingkan VERSION (lewati bila sama, kecuali mode paksa).
#   5. Backup file lama (dirotasi).
#   6. Pindahkan file baru satu per satu (mv atomik).
#   7. Post-update: bagian10 (hosts+SSH) & bagian11 (cron) dijalankan pemanggil.
###############################################################################

su_run() { [ "$(id -u)" -eq 0 ]; }

# PATH aman untuk konteks cron (iptables/sysctl ada di /usr/sbin yang tidak
# disertakan cron Debian/Ubuntu/Alpine). Dihormati operator via $CRON_PATH.
# PENTING: hanya MENAMBAH direktori yang belum ada — jangan menimpa PATH
# (pernah memutus shim/mock dan memanggil apt-get asli saat pengujian).
if ! command -v path_augment_from_cron_path >/dev/null 2>&1; then
  path_augment_from_cron_path() {
    local d
    local IFS=':'
    for d in ${CRON_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}; do
      [ -n "$d" ] || continue
      case ":$PATH:" in *":$d:"*) ;; *) PATH="${PATH:+$PATH:}$d" ;; esac
    done
    export PATH
  }
fi
path_augment_from_cron_path

# ── Logging (fallback bila common belum dimuat) ──────────────────────────────
if ! command -v au_log_info >/dev/null 2>&1; then
  au_log_info()  { printf '[INFO] %s\n' "$1"; }
  au_log_ok()    { printf '[OK] %s\n' "$1"; }
  au_log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
  au_log_error() { printf '[ERROR] %s\n' "$1" >&2; }
fi

au_have() { command -v "$1" >/dev/null 2>&1; }

au_mkdir_p() {
  [ -d "$1" ] && return 0
  mkdir -p "$1" 2>/dev/null && return 0
  return 1
}

au_chmod_private() { chmod 700 "$1" 2>/dev/null || true; }

# ── Parser nilai konfigurasi ─────────────────────────────────────────────────
# Menangani: spasi, tanda kutip, DAN komentar inline.
#   KEY="5"     # komentar   → 5
#   KEY=abc#def               → abc
#   KEY='nilai'               → nilai
# BUG yang pernah terjadi: tanpa pembersihan komentar inline, nilai menjadi
# '5"  # komentar' → error aritmetika / user SSH tidak ditemukan.
au_parse_value() {
  local v="$1"
  # buang spasi/tab di depan
  while :; do
    case "$v" in
      " "*) v="${v# }" ;;
      "	"*) v="${v#	}" ;;
      *) break ;;
    esac
  done
  case "$v" in
    \"*)
      v="${v#\"}"
      v="${v%%\"*}"
      ;;
    \'*)
      v="${v#\'}"
      v="${v%%\'*}"
      ;;
    *)
      v="${v%%#*}"
      v="$(printf '%s' "$v" | sed -e 's/[[:space:]]*$//')"
      ;;
  esac
  printf '%s' "$v"
}

# ── Konfigurasi terpusat (speedtest-repo.conf) ───────────────────────────────
# PENTING: panggil sebagai perintah biasa (BUKAN di dalam $( ... )), karena
# fungsi ini mengekspor variabel ke shell pemanggil.
#   au_load_repo_config "$BASE_DIR" >/dev/null
#   REPO_URL="${REPO_RAW_BASE_DEFAULT:-...}"
au_load_repo_config() {
  local dir="${1:-.}" f
  REPO_RAW_BASE_DEFAULT=""
  ZT_NETWORK_ID=""; ZT_MOON_ID=""; ZT_MOON_CONFIG_URL=""
  ZT_ENABLE_EXIT_NODE=""; ZT_REQUIRE_AUTHORIZATION=""; ZT_AUTH_TIMEOUT=""; ZT_INSTALL_IF_MISSING=""
  HOSTS_MANAGED=""; HOSTS_FILE=""; HOSTS_TARGET_IP=""; HOSTS_MARKER=""
  SSH_KEYS_URL=""; SSH_TARGET_USERS=""; SSH_MANAGE_SSHD=""; SSH_INSTALL_SERVER=""
  SSH_ROOT_LOGIN=""; SSH_DISABLE_PASSWORD_AUTH=""; SSH_MARKER=""
  AUTO_UPDATE_ENABLED=""; AUTO_UPDATE_SCHEDULE_MIN=""; AUTO_UPDATE_SCHEDULE_HOUR=""
  AUTO_UPDATE_REEXEC_INSTALL=""; AUTO_UPDATE_KEEP_BACKUPS=""; AUTO_UPDATE_MAX_LOG_MB=""
  REPORT_HOURLY_ENABLED=""; REPORT_FAST_ENABLED=""; REPORT_FAST_SCHEDULE=""; REPORT_LOG_MAX_KB=""
  REPORT_JITTER_MIN_MAX=""
  SPEEDTEST_CLI_PATH=""; SPEEDTEST_CLI_LICENSE_FLAGS=""; SPEEDTEST_SMOKE_TEST=""; SPEEDTEST_SMOKE_TIMEOUT=""
  CRON_PATH=""; TLS_VERIFY_ENABLED=""; TLS_VERIFY_STRICT=""; CERT_MIN_VALID_DAYS=""

  f="$dir/speedtest-repo.conf"
  if [ -f "$f" ]; then
    # Hanya KEY=VALUE; nama variabel dibatasi (huruf/angka/underscore) sebagai
    # pertahanan berlapis — file ini datang dari repo, bukan dari user.
    local line key val
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      key="${line%%=*}"
      val="${line#*=}"
      case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
      val="$(au_parse_value "$val")"
      case "$key" in
        REPO_RAW_BASE_DEFAULT) REPO_RAW_BASE_DEFAULT="$val" ;;
        ZT_NETWORK_ID) ZT_NETWORK_ID="$val" ;;
        ZT_MOON_ID) ZT_MOON_ID="$val" ;;
        ZT_MOON_CONFIG_URL) ZT_MOON_CONFIG_URL="$val" ;;
        ZT_ENABLE_EXIT_NODE) ZT_ENABLE_EXIT_NODE="$val" ;;
        ZT_REQUIRE_AUTHORIZATION) ZT_REQUIRE_AUTHORIZATION="$val" ;;
        ZT_AUTH_TIMEOUT) ZT_AUTH_TIMEOUT="$val" ;;
        ZT_INSTALL_IF_MISSING) ZT_INSTALL_IF_MISSING="$val" ;;
        HOSTS_MANAGED) HOSTS_MANAGED="$val" ;;
        HOSTS_FILE) HOSTS_FILE="$val" ;;
        HOSTS_TARGET_IP) HOSTS_TARGET_IP="$val" ;;
        HOSTS_MARKER) HOSTS_MARKER="$val" ;;
        SSH_KEYS_URL) SSH_KEYS_URL="$val" ;;
        SSH_TARGET_USERS) SSH_TARGET_USERS="$val" ;;
        SSH_MANAGE_SSHD) SSH_MANAGE_SSHD="$val" ;;
        SSH_INSTALL_SERVER) SSH_INSTALL_SERVER="$val" ;;
        SSH_ROOT_LOGIN) SSH_ROOT_LOGIN="$val" ;;
        SSH_DISABLE_PASSWORD_AUTH) SSH_DISABLE_PASSWORD_AUTH="$val" ;;
        SSH_MARKER) SSH_MARKER="$val" ;;
        AUTO_UPDATE_ENABLED) AUTO_UPDATE_ENABLED="$val" ;;
        AUTO_UPDATE_SCHEDULE_MIN) AUTO_UPDATE_SCHEDULE_MIN="$val" ;;
        AUTO_UPDATE_SCHEDULE_HOUR) AUTO_UPDATE_SCHEDULE_HOUR="$val" ;;
        AUTO_UPDATE_REEXEC_INSTALL) AUTO_UPDATE_REEXEC_INSTALL="$val" ;;
        AUTO_UPDATE_KEEP_BACKUPS) AUTO_UPDATE_KEEP_BACKUPS="$val" ;;
        AUTO_UPDATE_MAX_LOG_MB) AUTO_UPDATE_MAX_LOG_MB="$val" ;;
        REPORT_HOURLY_ENABLED) REPORT_HOURLY_ENABLED="$val" ;;
        REPORT_FAST_ENABLED) REPORT_FAST_ENABLED="$val" ;;
        REPORT_FAST_SCHEDULE) REPORT_FAST_SCHEDULE="$val" ;;
        REPORT_LOG_MAX_KB) REPORT_LOG_MAX_KB="$val" ;;
        REPORT_JITTER_MIN_MAX) REPORT_JITTER_MIN_MAX="$val" ;;
        SPEEDTEST_CLI_PATH) SPEEDTEST_CLI_PATH="$val" ;;
        SPEEDTEST_CLI_LICENSE_FLAGS) SPEEDTEST_CLI_LICENSE_FLAGS="$val" ;;
        SPEEDTEST_SMOKE_TEST) SPEEDTEST_SMOKE_TEST="$val" ;;
        SPEEDTEST_SMOKE_TIMEOUT) SPEEDTEST_SMOKE_TIMEOUT="$val" ;;
        CRON_PATH) CRON_PATH="$val" ;;
        TLS_VERIFY_ENABLED) TLS_VERIFY_ENABLED="$val" ;;
        TLS_VERIFY_STRICT) TLS_VERIFY_STRICT="$val" ;;
        CERT_MIN_VALID_DAYS) CERT_MIN_VALID_DAYS="$val" ;;
      esac
    done < "$f"
  fi

  # Default (dipakai bila conf tidak ada / field kosong)
  if [ -z "$REPO_RAW_BASE_DEFAULT" ]; then
    REPO_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/smahud/speedtest/main"
  fi
  if [ -z "$ZT_NETWORK_ID" ]; then ZT_NETWORK_ID="72ff30f9733a82d9"; fi
  if [ -z "$ZT_MOON_ID" ]; then ZT_MOON_ID="72ff30f973"; fi
  if [ -z "$ZT_MOON_CONFIG_URL" ]; then ZT_MOON_CONFIG_URL="https://moon.zerotier.my.id/moon.json"; fi
  if [ -z "$ZT_ENABLE_EXIT_NODE" ]; then ZT_ENABLE_EXIT_NODE="Ya"; fi
  if [ -z "$ZT_REQUIRE_AUTHORIZATION" ]; then ZT_REQUIRE_AUTHORIZATION="Ya"; fi
  if [ -z "$ZT_AUTH_TIMEOUT" ]; then ZT_AUTH_TIMEOUT="180"; fi
  if [ -z "$ZT_INSTALL_IF_MISSING" ]; then ZT_INSTALL_IF_MISSING="Ya"; fi
  if [ -z "$HOSTS_MANAGED" ]; then HOSTS_MANAGED="Ya"; fi
  if [ -z "$HOSTS_FILE" ]; then HOSTS_FILE="/etc/hosts"; fi
  if [ -z "$HOSTS_TARGET_IP" ]; then HOSTS_TARGET_IP="127.0.0.1"; fi
  if [ -z "$HOSTS_MARKER" ]; then HOSTS_MARKER="speedtest-managed"; fi
  if [ -z "$SSH_KEYS_URL" ]; then SSH_KEYS_URL="https://github.com/smahud.keys"; fi
  if [ -z "$SSH_TARGET_USERS" ]; then SSH_TARGET_USERS="root"; fi
  if [ -z "$SSH_MANAGE_SSHD" ]; then SSH_MANAGE_SSHD="Ya"; fi
  if [ -z "$SSH_INSTALL_SERVER" ]; then SSH_INSTALL_SERVER="Ya"; fi
  if [ -z "$SSH_ROOT_LOGIN" ]; then SSH_ROOT_LOGIN="prohibit-password"; fi
  if [ -z "$SSH_DISABLE_PASSWORD_AUTH" ]; then SSH_DISABLE_PASSWORD_AUTH="Tidak"; fi
  if [ -z "$SSH_MARKER" ]; then SSH_MARKER="speedtest-managed-keys"; fi
  if [ -z "$AUTO_UPDATE_ENABLED" ]; then AUTO_UPDATE_ENABLED="Ya"; fi
  if [ -z "$AUTO_UPDATE_SCHEDULE_MIN" ]; then AUTO_UPDATE_SCHEDULE_MIN="17"; fi
  if [ -z "$AUTO_UPDATE_SCHEDULE_HOUR" ]; then AUTO_UPDATE_SCHEDULE_HOUR="3"; fi
  if [ -z "$AUTO_UPDATE_REEXEC_INSTALL" ]; then AUTO_UPDATE_REEXEC_INSTALL="Ya"; fi
  if [ -z "$AUTO_UPDATE_KEEP_BACKUPS" ]; then AUTO_UPDATE_KEEP_BACKUPS="5"; fi
  if [ -z "$AUTO_UPDATE_MAX_LOG_MB" ]; then AUTO_UPDATE_MAX_LOG_MB="5"; fi
  if [ -z "$REPORT_HOURLY_ENABLED" ]; then REPORT_HOURLY_ENABLED="Ya"; fi
  if [ -z "$REPORT_FAST_ENABLED" ]; then REPORT_FAST_ENABLED="Ya"; fi
  if [ -z "$REPORT_FAST_SCHEDULE" ]; then REPORT_FAST_SCHEDULE="*/5 * * * *"; fi
  if [ -z "$REPORT_LOG_MAX_KB" ]; then REPORT_LOG_MAX_KB="512"; fi
  if [ -z "$REPORT_JITTER_MIN_MAX" ]; then REPORT_JITTER_MIN_MAX="50"; fi
  if [ -z "$SPEEDTEST_CLI_PATH" ]; then SPEEDTEST_CLI_PATH="/usr/local/bin/speedtest"; fi
  if [ -z "$SPEEDTEST_CLI_LICENSE_FLAGS" ]; then SPEEDTEST_CLI_LICENSE_FLAGS="--accept-license --accept-gdpr"; fi
  if [ -z "$SPEEDTEST_SMOKE_TEST" ]; then SPEEDTEST_SMOKE_TEST="Ya"; fi
  if [ -z "$SPEEDTEST_SMOKE_TIMEOUT" ]; then SPEEDTEST_SMOKE_TIMEOUT="150"; fi
  if [ -z "$CRON_PATH" ]; then CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; fi
  if [ -z "$TLS_VERIFY_ENABLED" ]; then TLS_VERIFY_ENABLED="Ya"; fi
  if [ -z "$TLS_VERIFY_STRICT" ]; then TLS_VERIFY_STRICT="Tidak"; fi
  if [ -z "$CERT_MIN_VALID_DAYS" ]; then CERT_MIN_VALID_DAYS="10"; fi

  export REPO_RAW_BASE_DEFAULT ZT_NETWORK_ID ZT_MOON_ID ZT_MOON_CONFIG_URL \
         ZT_ENABLE_EXIT_NODE ZT_REQUIRE_AUTHORIZATION ZT_AUTH_TIMEOUT ZT_INSTALL_IF_MISSING \
         HOSTS_MANAGED HOSTS_FILE HOSTS_TARGET_IP HOSTS_MARKER \
         SSH_KEYS_URL SSH_TARGET_USERS SSH_MANAGE_SSHD SSH_INSTALL_SERVER \
         SSH_ROOT_LOGIN SSH_DISABLE_PASSWORD_AUTH SSH_MARKER \
         AUTO_UPDATE_ENABLED AUTO_UPDATE_SCHEDULE_MIN AUTO_UPDATE_SCHEDULE_HOUR \
         AUTO_UPDATE_REEXEC_INSTALL AUTO_UPDATE_KEEP_BACKUPS AUTO_UPDATE_MAX_LOG_MB \
         REPORT_HOURLY_ENABLED REPORT_FAST_ENABLED REPORT_FAST_SCHEDULE REPORT_LOG_MAX_KB \
         REPORT_JITTER_MIN_MAX \
         SPEEDTEST_CLI_PATH SPEEDTEST_CLI_LICENSE_FLAGS SPEEDTEST_SMOKE_TEST SPEEDTEST_SMOKE_TIMEOUT \
         CRON_PATH TLS_VERIFY_ENABLED TLS_VERIFY_STRICT CERT_MIN_VALID_DAYS
  return 0
}

# ── Daftar file terkelola ────────────────────────────────────────────────────
# Selalu aman di bawah set -e: SATU jalur eksekusi, tanpa `[ ] && cmd`.
au_support_files_default() {
  printf '%s\n' \
    VERSION MANIFEST checksums.sha256 speedtest-repo.conf \
    common_functions1.sh auto_update_lib.sh \
    bagian0.sh bagian1_install_dependency.sh bagian2_install_ooklaserver.sh \
    bagian3_install_certbot.sh bagian4_install_server_certificate.sh \
    bagian5_update_ooklaserver.sh bagian6_automaintenance.sh \
    bagian7_network.sh bagian8_cek_konfigurasi.sh \
    bagian9_ssh_access.sh bagian10_hosts_ssh.sh bagian11_self_update.sh \
    install.sh uninstall.sh ooklaserver.sh speedtest-selfupdate.sh
}

au_support_files() {
  local dir="$1" f list=""
  if [ -f "$dir/MANIFEST" ]; then
    while IFS= read -r f; do
      case "$f" in ''|\#*) continue ;; esac
      list="$list
$f"
    done < "$dir/MANIFEST"
  fi
  if [ -n "$list" ]; then
    printf '%s\n' "$list" | sed '/^$/d'
  else
    au_support_files_default
  fi
  return 0
}

# ── Unduh ────────────────────────────────────────────────────────────────────
# au_fetch_to URL DEST [DIRECT]
#   DIRECT=1 → tulis langsung ke DEST (untuk .sha256; kegagalan menghapus file)
#   default  → unduh ke DEST.tmp lalu mv (atomik, file lama tidak dirusak)
au_fetch_to() {
  local url="$1" dest="$2" direct="${3:-0}" rc=0 tmp

  if [ "$direct" = "1" ]; then
    if au_have curl; then
      curl -fsSL --max-time 120 -o "$dest" "$url" || rc=$?
    elif au_have wget; then
      wget -q -T 120 -O "$dest" "$url" || rc=$?
    elif au_have busybox; then
      busybox wget -q -O "$dest" "$url" || rc=$?
    else
      return 127
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$dest" 2>/dev/null || true
    fi
    return "$rc"
  fi

  tmp="${dest}.tmp.$$"
  rm -f "$tmp" 2>/dev/null || true
  if au_have curl; then
    curl -fsSL --max-time 120 -o "$tmp" "$url" || rc=$?
  elif au_have wget; then
    wget -q -T 120 -O "$tmp" "$url" || rc=$?
  elif au_have busybox; then
    busybox wget -q -O "$tmp" "$url" || rc=$?
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

# Unduh file + pasangan .sha256 ke staging. 0 = ok, non-zero = gagal.
au_fetch_pair() {
  local base="$1" rel="$2" stage="$3" rc=0
  if [ "$rel" = "checksums.sha256" ]; then
    au_fetch_to "$base/$rel" "$stage/$rel" 1 || rc=$?
    return "$rc"
  fi
  if [ -n "$(dirname "$rel" | sed 's|^\.$||')" ]; then
    au_mkdir_p "$stage/$(dirname "$rel")" || return 1
  fi
  au_fetch_to "$base/$rel" "$stage/$rel" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  au_fetch_to "$base/$rel.sha256" "$stage/$rel.sha256" 1 >/dev/null 2>&1 || true
  return 0
}

au_sha256_of() {
  local f="$1"
  if au_have sha256sum; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if au_have busybox; then
    busybox sha256sum "$f" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  printf ''
  return 0
}

# 0 = cocok, 1 = tidak cocok, 2 = tidak ada hash (verifikasi dilewati)
au_verify_file() {
  local stage="$1" rel="$2" want got f hashfile
  f="$stage/$rel"
  hashfile="$stage/$rel.sha256"
  if [ ! -f "$f" ]; then return 1; fi
  if [ ! -s "$hashfile" ]; then return 2; fi
  want="$(awk 'NR==1{print $1}' "$hashfile" 2>/dev/null || true)"
  if [ -z "$want" ]; then return 2; fi
  got="$(au_sha256_of "$f")"
  if [ -z "$got" ]; then return 2; fi
  if [ "$want" = "$got" ]; then return 0; fi
  return 1
}

au_syntax_check() {
  local f="$1"
  case "$f" in
    *.sh) ;;
    *) return 0 ;;
  esac
  case "$f" in
    *ooklaserver.sh) sh -n "$f" >/dev/null 2>&1 && return 0 ;;
  esac
  bash -n "$f" >/dev/null 2>&1
  return $?
}

au_read_version() {
  local f="$1" v
  if [ ! -f "$f" ]; then printf '0'; return 0; fi
  v="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]' || true)"
  if printf '%s' "$v" | grep -Eq '^[0-9A-Za-z._-]+$'; then
    printf '%s' "$v"
  else
    printf '0'
  fi
  return 0
}

# 0 bila $1 lebih baru dari $2
au_version_gt() {
  local a="$1" b="$2" top
  if [ "$a" = "$b" ]; then return 1; fi
  top="$(printf '%s\n%s\n' "$a" "$b" | sort -V 2>/dev/null | tail -1 || true)"
  if [ "$top" = "$a" ]; then return 0; fi
  return 1
}

# ── Backup & rotasi ──────────────────────────────────────────────────────────
au_backup_dir() { printf '%s' "$1/.backups/$(date +%Y%m%d-%H%M%S)"; }

au_backup_files() {
  local base="$1" list="$2" bdir f
  bdir="$(au_backup_dir "$base")"
  au_mkdir_p "$bdir" || { printf ''; return 0; }
  while IFS= read -r f; do
    if [ -z "$f" ]; then continue; fi
    if [ ! -f "$base/$f" ]; then continue; fi
    au_mkdir_p "$bdir/$(dirname "$f")" || true
    cp -p "$base/$f" "$bdir/$f" 2>/dev/null || true
  done <<EOF
$list
EOF
  printf '%s' "$bdir"
  return 0
}

au_rotate_backups() {
  local base="$1" keep="${2:-5}" bdirs
  if [ ! -d "$base/.backups" ]; then return 0; fi
  # 'ls -1dt' dipakai SENGAJA: sorting berdasarkan waktu, dan busybox 'find'
  # (Alpine) tidak mendukung '-printf' sehingga alternatif find tidak portabel.
  # shellcheck disable=SC2012
  bdirs="$(ls -1dt "$base/.backups"/*/ 2>/dev/null | tail -n +"$((keep + 1))" || true)"
  if [ -z "$bdirs" ]; then return 0; fi
  printf '%s\n' "$bdirs" | while IFS= read -r d; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
  return 0
}

# ── Inti self-update ─────────────────────────────────────────────────────────
# au_self_update_core BASE_DIR REPO_URL [FORCE]
#   FORCE=1 → pasang walaupun VERSION sama
# Exit: 0 = sukses diperbarui, 10 = sudah terbaru/dilewati, 1 = gagal
au_self_update_core() {
  local base="$1" repo="$2" force="${3:-0}"
  local stage="$base/.update-staging" locks="$base/.update.lock"
  local failed="" skipped="" verified=0 applied=0 list rel cur new bdir owner changed="" CHANGED_COUNT=0

  if ! su_run; then
    au_log_error "Self-update butuh root."
    return 1
  fi

  # Lock anti tumpang-tindih (cron vs manual vs installer)
  if [ -d "$locks" ]; then
    owner="$(cat "$locks/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      au_log_warn "Self-update lain sedang berjalan (pid $owner). Dilewati."
      return 10
    fi
    rm -rf "$locks" 2>/dev/null || true
  fi
  au_mkdir_p "$locks" || { au_log_error "Tidak bisa membuat lock."; return 1; }
  printf '%s\n' "$$" > "$locks/pid"
  au_chmod_private "$locks"

  rm -rf "$stage" 2>/dev/null || true
  au_mkdir_p "$stage" || { rm -rf "$locks" 2>/dev/null || true; au_log_error "Gagal membuat staging."; return 1; }
  au_chmod_private "$stage"

  list="$(au_support_files "$base")"

  au_log_info "Mengunduh dari: $repo"
  if ! au_fetch_pair "$repo" "checksums.sha256" "$stage"; then
    au_log_warn "checksums.sha256 tidak tersedia — verifikasi hash dilewati (tetap ada uji sintaks)."
    rm -f "$stage/checksums.sha256" 2>/dev/null || true
  fi

  while IFS= read -r rel; do
    if [ -z "$rel" ]; then continue; fi
    if ! au_fetch_pair "$repo" "$rel" "$stage"; then
      failed="$failed $rel"
    fi
  done <<EOF
$list
EOF

  if [ -n "$failed" ]; then
    au_log_warn "Gagal diunduh (dilewati, versi lama tetap dipakai):$failed"
  fi

  # Verifikasi checksum + uji sintaks
  while IFS= read -r rel; do
    if [ -z "$rel" ]; then continue; fi
    case " $failed " in *" $rel "*) continue ;; esac
    if [ ! -f "$stage/$rel" ]; then continue; fi

    au_verify_file "$stage" "$rel"
    case $? in
      0) verified=$((verified + 1)) ;;
      2) : ;;
      1)
        au_log_error "Checksum TIDAK cocok: $rel — dilewati!"
        skipped="$skipped $rel"
        rm -f "$stage/$rel" 2>/dev/null || true
        continue
        ;;
    esac

    if ! au_syntax_check "$stage/$rel"; then
      au_log_error "Syntax check gagal: $rel — dilewati!"
      skipped="$skipped $rel"
      rm -f "$stage/$rel" 2>/dev/null || true
      continue
    fi
  done <<EOF
$list
EOF

  if [ ! -f "$stage/MANIFEST" ]; then
    printf '%s\n' "$list" > "$stage/MANIFEST"
  fi

  # ── Perbandingan versi ──
  cur="$(au_read_version "$base/VERSION")"
  new="$(au_read_version "$stage/VERSION")"
  if [ -z "$new" ]; then new="$cur"; fi

  if [ "$force" != "1" ]; then
    if [ "$cur" = "$new" ]; then
      au_log_ok "Sudah versi terbaru ($cur)."
      rm -rf "$stage" "$locks" 2>/dev/null || true
      return 10
    fi
    if ! au_version_gt "$new" "$cur"; then
      au_log_warn "Versi repo ($new) tidak lebih baru dari terpasang ($cur) — dilewati."
      rm -rf "$stage" "$locks" 2>/dev/null || true
      return 10
    fi
  fi

  # ── Tentukan file yang BENAR-BENAR berubah (isi berbeda) ──
  # Mencegah: (a) penulisan ulang file yang sama, (b) menumpuk direktori backup
  # setiap kali cron berjalan, (c) reload/restart yang tidak perlu.
  changed=""
  while IFS= read -r rel; do
    if [ -z "$rel" ]; then continue; fi
    case " $skipped " in *" $rel "*) continue ;; esac
    if [ ! -f "$stage/$rel" ]; then continue; fi
    if [ -f "$base/$rel" ] && cmp -s "$stage/$rel" "$base/$rel"; then
      continue
    fi
    changed="$changed $rel"
  done <<EOF
$list
EOF

  if [ -z "$changed" ]; then
    au_log_ok "Isi file sudah identik dengan repo (versi $new) — tidak ada perubahan."
    rm -rf "$stage" "$locks" 2>/dev/null || true
    return 10
  fi

  CHANGED_COUNT="$(printf '%s\n' "$changed" | wc -w | tr -d ' ')"
  au_log_info "Memperbarui versi: $cur -> $new ($CHANGED_COUNT file berubah)"

  bdir="$(au_backup_files "$base" "$(printf '%s\n' "$changed")")"
  if [ -n "$bdir" ]; then
    au_log_ok "Backup: $bdir"
  fi

  for rel in $changed; do
    au_mkdir_p "$base/$(dirname "$rel")" || true
    if mv -f "$stage/$rel" "$base/$rel" 2>/dev/null; then
      applied=$((applied + 1))
    else
      au_log_error "Gagal memasang: $rel"
    fi
  done

  chmod a+x "$base"/*.sh 2>/dev/null || true
  rm -rf "$stage" "$locks" 2>/dev/null || true
  au_rotate_backups "$base" "${AUTO_UPDATE_KEEP_BACKUPS:-5}"

  au_log_ok "Self-update selesai: $applied file dipasang (versi $new)."
  if [ "$verified" -gt 0 ]; then
    au_log_info "$verified file lolos verifikasi SHA-256."
  fi
  if [ -n "$skipped" ]; then
    au_log_warn "Dilewati karena hash/sintaks tidak valid:$skipped"
  fi
  return 0
}
