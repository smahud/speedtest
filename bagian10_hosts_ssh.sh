#!/usr/bin/env bash
###############################################################################
# bagian10_hosts_ssh.sh — PENEGAK (enforcer) dua hal yang harus SELALU ada:
#   1. Entri HOSTS_FILE (+/etc/hosts) untuk RegisteredSpeedtestURL → 127.0.0.1
#   2. Akses SSH: public key GitHub di authorized_keys + konfigurasi sshd standar
#
# Dirancang bisa dijalankan TANPA ketergantungan sesi instalasi:
#   bash bagian10_hosts_ssh.sh /path/ke/data.ini
#   bash bagian10_hosts_ssh.sh -postboot      # dipanggil cron @reboot / self-update
#
# Karena idempotent, script ini aman dipanggil berkali-kali (mis. setiap kali
# self-update selesai) sehingga konfigurasi tidak pernah "hilang" kalau sistem
# di-reset/reimage, dan kunci baru yang Anda tambahkan di GitHub akan tersinkron.
###############################################################################
set -uo pipefail

SCRIPT_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# ── Environment minimal (tanpa common bila dipanggil dari cron/boot) ─────────
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR_SELF}"
CONFIG_PATH="${CONFIG_PATH:-$BASE_DIR/data.ini}"
TMP_DIR="${TMP_DIR:-$BASE_DIR/tmp}"
mkdir -p "$TMP_DIR" 2>/dev/null || true

# Pustaka shared (self-update + pembaca speedtest-repo.conf)
[ -f "$BASE_DIR/auto_update_lib.sh" ] && . "$BASE_DIR/auto_update_lib.sh"

if [ -f "$BASE_DIR/common_functions1.sh" ]; then
  # shellcheck source=common_functions1.sh
  . "$BASE_DIR/common_functions1.sh"
fi

# Bila common tidak ada (mis. sistem rusak), baca konfigurasi repo langsung
# supaya nilai hardcode (ZeroTier, hosts, SSH) tetap terpakai.
if [ -z "${HOSTS_FILE:-}" ] && command -v au_load_repo_config >/dev/null 2>&1; then
  au_load_repo_config "$BASE_DIR" >/dev/null 2>&1 || true
fi

if ! command -v log_info >/dev/null 2>&1; then
  log_info()  { printf '[INFO] %s\n' "$1"; }
  log_ok()    { printf '[OK] %s\n' "$1"; }
  log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
  log_error() { printf '[ERROR] %s\n' "$1" >&2; }
fi

# Pengunduh sederhana (dipakai bila bagian9 tidak tersedia).
p10_download() {
  local url="$1" dest="$2" rc=0 apk_url="${1%.keys}.apk"
  rm -f "$dest.tmp" 2>/dev/null
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 -o "$dest.tmp" "$url" || rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$dest.tmp" "$url" || rc=$?
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -q -O "$dest.tmp" "$url" || rc=$?
  else
    return 127
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$dest.tmp" ]; then
    rm -f "$dest.tmp"
    rc=0
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --max-time 60 -o "$dest.tmp" "$apk_url" || rc=$?
    elif command -v wget >/dev/null 2>&1; then
      wget -q -T 60 -O "$dest.tmp" "$apk_url" || rc=$?
    fi
    [ "$rc" -eq 0 ] && [ -s "$dest.tmp" ] || { rm -f "$dest.tmp"; return 1; }
  fi
  mv -f "$dest.tmp" "$dest"
  return 0
}

# ── Ambil RegisteredSpeedtestURL dari data.ini ───────────────────────────────
p10_registered_url() {
  if command -v ini_get >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
    ini_get RegisteredSpeedtestURL "$CONFIG_PATH"
    return 0
  fi
  [ -f "$CONFIG_PATH" ] || return 0
  grep -E '^[[:space:]]*RegisteredSpeedtestURL[[:space:]]*=' "$CONFIG_PATH" 2>/dev/null \
    | tail -n1 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '"'"'" | awk '{print $1}'
}

# Normalisasi input → hostname murni (buang skema, path, port)
p10_hostname() {
  printf '%s' "$1" | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|/.*$||; s|:.*$||'
}

# ═══════════════════════════════════════════════════════════════════════════
# 1) /etc/hosts : RegisteredSpeedtestURL → 127.0.0.1
# ═══════════════════════════════════════════════════════════════════════════
ensure_hosts_entry() {
  [ "${HOSTS_MANAGED:-Ya}" = "Ya" ] || { log_info "HOSTS_MANAGED=Tidak → melewati /etc/hosts."; return 0; }

  local URL HOST HOSTS="${HOSTS_FILE:-/etc/hosts}" IP="${HOSTS_TARGET_IP:-127.0.0.1}"
  local MARK="${HOSTS_MARKER:-speedtest-managed}"
  URL="$(p10_registered_url)"
  [ -n "$URL" ] || { log_warn "RegisteredSpeedtestURL kosong di data.ini — lewati /etc/hosts."; return 0; }
  HOST="$(p10_hostname "$URL")"
  [ -n "$HOST" ] || { log_warn "Tidak bisa mengekstrak hostname dari '$URL'."; return 0; }

  if [ ! -f "$HOSTS" ]; then
    log_warn "$HOSTS tidak ada — mencoba membuat."
    : > "$HOSTS" 2>/dev/null || { log_error "Tidak bisa membuat $HOSTS"; return 1; }
  fi

  # Sudah dikelola? (baris dengan penanda kita)
  local marker_line="$IP $HOST # $MARK"
  if grep -qF "$marker_line" "$HOSTS" 2>/dev/null; then
    log_ok "Entri /etc/hosts sudah ada: $marker_line"
    return 0
  fi

  # Bersihkan entri TERKELOLA versi lama (host sama tapi IP beda / baris penanda)
  local bak="$HOSTS.${MARK}.bak"
  cp -p "$HOSTS" "$bak" 2>/dev/null || true
  local tmp="$HOSTS.$$.tmp"
  grep -vE "[[:space:]]+#[[:space:]]*${MARK}$" "$HOSTS" > "$tmp" 2>/dev/null || cp -f "$HOSTS" "$tmp"
  # mv gagal bila $HOSTS adalah mount point (umum di container: /etc/hosts
  # di-bind Docker). Fallback: tulis in-place.
  if ! mv -f "$tmp" "$HOSTS" 2>/dev/null; then
    if cat "$tmp" > "$HOSTS" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
    else
      log_error "Gagal memperbarui $HOSTS"
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
  fi

  printf '%s\n' "$marker_line" >> "$HOSTS"
  log_ok "Ditambahkan ke $HOSTS: $marker_line"

  # Peringatan bila hostname sama-sama diarahkan ke IP lain oleh baris non-managed
  local conflict
  conflict="$(grep -E "^[^#]*[[:space:]]${HOST}([[:space:]]|$)" "$HOSTS" 2>/dev/null | grep -v "$MARK" | grep -v "^${IP}[[:space:]]" || true)"
  if [ -n "$conflict" ]; then
    log_warn "Perhatian: ada entri lain untuk '$HOST' di $HOSTS:"
    printf '  %s\n' "$conflict" >&2
    log_warn "Entri pertama yang cocok akan menang. Backup: $bak"
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# 2) SSH keys + sshd (idempotent, fail-safe)
# ═══════════════════════════════════════════════════════════════════════════
p10_sshd_bin() {
  if command -v sshd >/dev/null 2>&1; then command -v sshd
  elif [ -x /usr/sbin/sshd ]; then printf '%s' /usr/sbin/sshd
  else printf ''
  fi
}

p10_restart_sshd() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 \
      || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service sshd reload >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service ssh reload >/dev/null 2>&1 || service sshd reload >/dev/null 2>&1 || true
  fi
  return 0
}

ensure_ssh() {
  local KEYS_URL="${SSH_KEYS_URL:-https://github.com/smahud.keys}"
  local USERS="${SSH_TARGET_USERS:-root}"
  local MANAGE="${SSH_MANAGE_SSHD:-Ya}"
  local ROOTLOGIN="${SSH_ROOT_LOGIN:-prohibit-password}"
  local DISABLE_PW="${SSH_DISABLE_PASSWORD_AUTH:-Tidak}"
  local MARK="${SSH_MARKER:-speedtest-managed-keys}"
  local KEYFILE="$TMP_DIR/ssh-keys.p10" i=0

  [ "$(id -u)" -eq 0 ] || { log_warn "Bukan root — langkah SSH dilewati."; return 0; }

  log_info "Menyinkronkan public key dari $KEYS_URL ..."
  if ! p10_download "$KEYS_URL" "$KEYFILE"; then
    log_error "Gagal mengunduh public key (jaringan?). Konfigurasi SSH yang ada DIBIARKAN apa adanya."
    return 1
  fi
  if ! grep -qE '^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-)' "$KEYFILE" 2>/dev/null; then
    log_error "File kunci tidak valid — konfigurasi SSH dibiarkan apa adanya."
    rm -f "$KEYFILE"
    return 1
  fi
  chmod 600 "$KEYFILE" 2>/dev/null || true

  for u in $USERS; do
    local home h
    home="$(user_home "$u")"
    [ -n "$home" ] || { log_warn "User '$u' tidak ada — dilewati."; continue; }
    h="$home/.ssh"
    mkdir -p "$h" 2>/dev/null || continue
    touch "$h/authorized_keys" 2>/dev/null || continue
    local tmpak="$h/authorized_keys.p10tmp"
    if ! awk -v begin="# BEGIN $MARK" -v end="# END $MARK" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip { print }
      ' "$h/authorized_keys" > "$tmpak" 2>/dev/null; then
      cp -f "$h/authorized_keys" "$tmpak"
    fi
    {
      printf '# BEGIN %s\n' "$MARK"
      printf '# Dikelola otomatis oleh speedtest installer — jangan diedit manual.\n'
      printf '# Sumber: %s (disinkronkan %s)\n' "$KEYS_URL" "$(date -Iseconds 2>/dev/null || date)"
      grep -vE '^[[:space:]]*(#|$)' "$KEYFILE"
      printf '# END %s\n' "$MARK"
    } >> "$tmpak"
    mv -f "$tmpak" "$h/authorized_keys" 2>/dev/null || { log_warn "Gagal menulis authorized_keys user '$u'."; continue; }
    chmod 700 "$h" 2>/dev/null || true
    chmod 600 "$h/authorized_keys" 2>/dev/null || true
    chown -R "$u":"$u" "$h" 2>/dev/null || chown -R "$(id -u "$u")":"$(id -g "$u")" "$h" 2>/dev/null || true
    command -v restorecon >/dev/null 2>&1 && restorecon -RF "$h" >/dev/null 2>&1 || true
    i=$((i+1))
    log_ok "Kunci publik disinkronkan untuk user '$u'."
  done
  rm -f "$KEYFILE" 2>/dev/null || true

  [ "$MANAGE" = "Ya" ] || { log_info "SSH_MANAGE_SSHD=Tidak → konfigurasi sshd tidak diubah."; return 0; }

  local bin; bin="$(p10_sshd_bin)"
  [ -n "$bin" ] || { log_warn "sshd tidak terpasang — standardisasi sshd dilewati."; return 0; }

  local MAIN="/etc/ssh/sshd_config" DROPIN_DIR="/etc/ssh/sshd_config.d" DROPIN="/etc/ssh/sshd_config.d/99-speedtest-managed.conf"
  local content pwline=""
  [ "$DISABLE_PW" = "Ya" ] && pwline="PasswordAuthentication no"
  content="$(cat <<EOF
# Dikelola otomatis oleh speedtest installer (bagian10).
# Jangan diedit manual — perubahan akan ditimpa pada sinkronisasi berikutnya.
PermitRootLogin $ROOTLOGIN
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
${pwline}
EOF
)"

  # Hanya tulis ulang bila isinya berbeda (menghindari reload sshd tak perlu)
  local need_write=1
  if [ -f "$DROPIN" ] && [ -f "$MAIN" ] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN"; then
    printf '%s\n' "$content" | diff -q - "$DROPIN" >/dev/null 2>&1 && need_write=0
  fi
  if [ "$need_write" -eq 0 ]; then
    log_ok "Konfigurasi sshd sudah sesuai — tidak ada perubahan."
    return 0
  fi

  local BK
  BK="$BASE_DIR/.ssh-backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK" 2>/dev/null || true
  [ -f "$MAIN" ] && cp -p "$MAIN" "$BK/sshd_config" 2>/dev/null || true

  if [ -f "$MAIN" ] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN"; then
    mkdir -p "$DROPIN_DIR" 2>/dev/null || true
    printf '%s\n' "$content" > "$DROPIN" || { log_warn "Gagal menulis $DROPIN"; return 1; }
    chmod 600 "$DROPIN" 2>/dev/null || true
    if "$bin" -t >/dev/null 2>&1; then
      log_ok "Konfigurasi sshd valid (drop-in). Backup: $BK"
      p10_restart_sshd
      return 0
    fi
    log_error "Validasi sshd -t gagal — drop-in dibatalkan (rollback)."
    rm -f "$DROPIN" 2>/dev/null || true
    return 1
  fi

  # Fallback: file utama (idempotent, dengan validasi + rollback)
  local TMP="$MAIN.p10tmp"
  cp -p "$MAIN" "$TMP" 2>/dev/null || { log_warn "Tidak bisa menyalin $MAIN"; return 1; }
  apply_kv() {
    if grep -qE "^[[:space:]]*$1[[:space:]]+" "$TMP" 2>/dev/null; then
      sed -i -E "s|^[[:space:]]*$1[[:space:]]+.*|$1 $2|" "$TMP"
    else
      printf '%s %s\n' "$1" "$2" >> "$TMP"
    fi
  }
  apply_kv PermitRootLogin "$ROOTLOGIN"
  apply_kv PubkeyAuthentication yes
  apply_kv AuthorizedKeysFile .ssh/authorized_keys
  [ -n "$pwline" ] && apply_kv PasswordAuthentication no

  # Uji dulu file kandidat via salinan sementara? (sshd -t hanya baca path asli)
  mv -f "$TMP" "$MAIN" 2>/dev/null || { log_warn "Gagal menerapkan sshd_config"; return 1; }
  if "$bin" -t >/dev/null 2>&1; then
    log_ok "Konfigurasi sshd valid (file utama). Backup: $BK"
    p10_restart_sshd
    return 0
  fi
  log_error "Validasi sshd -t gagal — memulihkan backup..."
  [ -f "$BK/sshd_config" ] && cp -f "$BK/sshd_config" "$MAIN" 2>/dev/null || true
  "$bin" -t >/dev/null 2>&1 && log_ok "sshd_config dipulihkan."
  return 1
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
MODE="${1:-}"
case "$MODE" in
  -postboot|--postboot)
    log_info "bagian10 (postboot): menegakkan /etc/hosts + akses SSH"
    ensure_hosts_entry || true
    ensure_ssh || true
    # Rule iptables NAT tidak persist antar-reboot → pulihkan lewat bagian7.
    if [ "${ZT_ENABLE_EXIT_NODE:-Ya}" = "Ya" ] && [ -f "$BASE_DIR/bagian7_network.sh" ]; then
      log_info "Memulihkan NAT/forwarding ZeroTier (bagian7 -postboot)..."
      bash "$BASE_DIR/bagian7_network.sh" -postboot >> "${BASE_DIR}/update.log" 2>&1 \
        && log_ok "NAT ZeroTier dipulihkan." || log_warn "Pemulihan NAT ZeroTier gagal (cek update.log)."
    fi
    ;;
  *)
    # Bila dipanggil dengan argumen path data.ini, hormati itu.
    if [ -n "$MODE" ] && [ -f "$MODE" ]; then
      CONFIG_PATH="$MODE"
      BASE_DIR="$(cd "$(dirname "$MODE")" && pwd)"
    fi
    log_info "== Bagian 10: Entri /etc/hosts + penegakan akses SSH =="
    ensure_hosts_entry || log_warn "Penulisan /etc/hosts tidak sepenuhnya berhasil."
    ensure_ssh || log_warn "Sinkronisasi akses SSH tidak sepenuhnya berhasil."
    log_ok "Bagian 10 selesai."
    ;;
esac
