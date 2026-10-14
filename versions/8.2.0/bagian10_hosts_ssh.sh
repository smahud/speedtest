#!/usr/bin/env bash
###############################################################################
# bagian10_hosts_ssh.sh — PENEGAK (enforcer) dua hal yang harus SELALU ada:
#   1. Entri HOSTS_FILE (default /etc/hosts) untuk RegisteredSpeedtestURL
#   2. Akses SSH: public key GitHub di authorized_keys + konfigurasi sshd
#
# Dirancang bisa dijalankan TANPA sesi instalasi:
#   bash bagian10_hosts_ssh.sh /path/ke/data.ini
#   bash bagian10_hosts_ssh.sh --postboot      # dipakai cron @reboot & self-update
#
# Karena idempotent, script ini aman dipanggil berkali-kali (mis. setiap kali
# self-update selesai) sehingga konfigurasi tidak pernah "hilang" kalau sistem
# di-reset/reimage, dan kunci baru yang ditambahkan di GitHub ikut tersinkron.
#
# Catatan PATH: script ini dijalankan dari cron (@reboot) yang di
# Debian/Ubuntu/Alpine hanya punya PATH=/usr/bin:/bin. Karena itu PATH
# diperluas eksplisit di bawah (lihat juga $CRON_PATH di speedtest-repo.conf).
###############################################################################
set -uo pipefail

# ── PATH untuk konteks cron (sbin tidak ada di PATH minimal cron) ────────────
# Hanya MENAMBAH ($CRON_PATH), tidak menimpa PATH yang sudah ada.
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

SCRIPT_DIR_SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# ── Environment minimal (tanpa common bila dipanggil dari cron/boot) ─────────
BASE_DIR="${BASE_DIR:-$SCRIPT_DIR_SELF}"
CONFIG_PATH="${CONFIG_PATH:-$BASE_DIR/data.ini}"
TMP_DIR="${TMP_DIR:-$BASE_DIR/tmp}"
mkdir -p "$TMP_DIR" 2>/dev/null || true

# Pustaka shared (self-update + pembaca speedtest-repo.conf + fungsi SSH)
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
# 1) HOSTS_FILE : RegisteredSpeedtestURL → 127.0.0.1
# ═══════════════════════════════════════════════════════════════════════════
ensure_hosts_entry() {
  [ "${HOSTS_MANAGED:-Ya}" = "Ya" ] || { log_info "HOSTS_MANAGED=Tidak → melewati $HOSTS_FILE."; return 0; }

  local URL HOST HOSTS="${HOSTS_FILE:-/etc/hosts}" IP="${HOSTS_TARGET_IP:-127.0.0.1}"
  local MARK="${HOSTS_MARKER:-speedtest-managed}"
  URL="$(p10_registered_url)"
  [ -n "$URL" ] || { log_warn "RegisteredSpeedtestURL kosong di data.ini — lewati $HOSTS."; return 0; }
  HOST="$(p10_hostname "$URL")"
  [ -n "$HOST" ] || { log_warn "Tidak bisa mengekstrak hostname dari '$URL'."; return 0; }

  if [ ! -f "$HOSTS" ]; then
    log_warn "$HOSTS tidak ada — mencoba membuat."
    : > "$HOSTS" 2>/dev/null || { log_error "Tidak bisa membuat $HOSTS"; return 1; }
  fi

  # Sudah dikelola? (baris dengan penanda kita)
  local marker_line="$IP $HOST # $MARK"
  if grep -qF "$marker_line" "$HOSTS" 2>/dev/null; then
    log_ok "Entri $HOSTS sudah ada: $marker_line"
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
# 2) Akses SSH — memakai pustaka bersama di common_functions1.sh (ssh_sync_all)
#    supaya perilakunya IDENTIK dengan bagian9 (tidak ada salinan ganda).
# ═══════════════════════════════════════════════════════════════════════════
ensure_ssh() {
  if ! command -v ssh_sync_all >/dev/null 2>&1; then
    log_error "Pustaka common_functions1.sh/tidak tersedia — sinkronisasi SSH dilewati."
    log_error "Perbaiki dengan menjalankan ulang instalasi (install.sh) atau salin file tersebut ke $BASE_DIR."
    return 1
  fi
  ssh_sync_all
}

# ── Pemulihan NAT/forwarding ZeroTier (rule iptables tidak persist reboot) ───
restore_zt_nat() {
  [ "${ZT_ENABLE_EXIT_NODE:-Ya}" = "Ya" ] || return 0
  [ -f "$BASE_DIR/bagian7_network.sh" ] || { log_warn "bagian7_network.sh tidak ada — NAT tidak dipulihkan."; return 1; }
  log_info "Memulihkan NAT/forwarding ZeroTier (bagian7_network.sh --postboot)..."
  if bash "$BASE_DIR/bagian7_network.sh" --postboot >> "$BASE_DIR/update.log" 2>&1; then
    log_ok "NAT ZeroTier dipulihkan."
    return 0
  fi
  log_warn "Pemulihan NAT ZeroTier gagal — detail di $BASE_DIR/update.log"
  return 1
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
MODE="${1:-}"
case "$MODE" in
  -postboot|--postboot)
    log_info "bagian10 (postboot): menegakkan $HOSTS_FILE + akses SSH + NAT ZeroTier"
    rc=0
    ensure_hosts_entry || rc=1
    ensure_ssh || rc=1
    restore_zt_nat || rc=1
    exit "$rc"
    ;;
  *)
    # Bila dipanggil dengan argumen path data.ini, hormati itu.
    if [ -n "$MODE" ] && [ -f "$MODE" ]; then
      CONFIG_PATH="$MODE"
      BASE_DIR="$(cd "$(dirname "$MODE")" && pwd)"
    fi
    log_info "== Bagian 10: Entri $HOSTS_FILE + penegakan akses SSH =="
    ensure_hosts_entry || log_warn "Penulisan $HOSTS_FILE tidak sepenuhnya berhasil."
    ensure_ssh || log_warn "Sinkronisasi akses SSH tidak sepenuhnya berhasil."
    log_ok "Bagian 10 selesai."
    ;;
esac
