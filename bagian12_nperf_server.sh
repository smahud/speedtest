#!/usr/bin/env bash
###############################################################################
# bagian12_nperf_server.sh — Memasang & menegakkan nPerf Server (layanan kedua)
#
#   nPerf (https://www.nperf.com) adalah platform speedtest lain. Paket resmi
#   `nperf-server` dipasang BERDAMPINGAN dengan OoklaServer di host yang sama:
#
#     Ookla  : HTTP 8080 / UDP 5060   (+ TLS Ookla)
#     nPerf  : HTTP 8081 (PORT)  / TLS 8443 (TLS_PORT)
#              redirect 80 → 8081 dan 443 → 8443 via nftables (default nPerf)
#
#   Catatan penting hasil bedah paket resmi nperf-server 2.2.11:
#     * Path paket bersifat TETAP (tidak bisa di-relokasi): /usr/bin/nPerfServer,
#       /etc/nperf/nperf-server.conf, /var/lib/nperf-server/ (PID + UUID),
#       unit systemd `nperf-server.service`. Yang mengikuti BASE_DIR adalah
#       artefak repo ini: $BASE_DIR/nperf/ (log, backup config, state).
#     * `PORT` di config wajib 8080 atau 8081 (komentar resmi di config paket);
#       karena 8080 dipakai Ookla, nilai default di sini 8081.
#     * Redirect 80/443 memakai **nftables** (v2.2.11+, bukan iptables lagi).
#     * Anti-DOS: init script menambah rule GLOBAL
#       `inet filter input tcp flags syn limit rate over 260/second drop
#        comment "nPerfServer"` — rule ini TIDAK dihapus saat service berhenti,
#       jadi pembersihannya dilakukan uninstall.sh (helper nft_del_nperf).
#     * Sertifikat TLS 8443 dikelola nPerfServer sendiri (CERT-UPDATE) —
#       certbot/Let's Encrypt repo ini TIDAK menyentuh nPerf.
#     * nPerfServer melayani file test-nya sendiri (/latency.txt, /upload.php,
#       /10MiB.dat, /100MiB.dat, /1GiB.dat, /download-*.dat) sehingga TIDAK
#       butuh web server eksternal; ramdisk 1,2 GB hanya opsi (default Tidak).
#     * Alpine TIDAK didukung (tidak ada paket apk) → modul dilewati berpesan.
#
# Mode:
#   bash bagian12_nperf_server.sh [data.ini]     # pasang/tegakkan penuh
#   bash bagian12_nperf_server.sh --config-only  # hanya pastikan config+service
#                                                # (dipakai self-update harian;
#                                                #  bila paket belum ada → pasang)
#   bash bagian12_nperf_server.sh --status       # ringkasan status (read-only)
#
# Versi: 8.2.0
###############################################################################
set -uo pipefail

MODE="install"
CONFIG_ARG=""
for arg in "$@"; do
  case "$arg" in
    --config-only|--enforce) MODE="config" ;;
    --status)                MODE="status" ;;
    -*)                      : ;;   # flag lain diabaikan
    *)                       CONFIG_ARG="$arg" ;;
  esac
done

SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR

# Source pustaka pendukung (wajib; skrip ini bukan skrip @reboot).
if [ -f "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh" ]; then
  # shellcheck source=common_functions1.sh
  . "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"
fi

# Fallback minimal bila pustaka tidak termuat (mis. dijalankan terpisah).
if ! command -v log_info >/dev/null 2>&1; then
  log_info()  { printf '[INFO] %s\n' "$1"; }
  log_ok()    { printf '[OK] %s\n' "$1"; }
  log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
  log_error() { printf '[ERROR] %s\n' "$1" >&2; }
  die()       { log_error "$1"; exit "${2:-1}"; }
  command_exists() { command -v "$1" >/dev/null 2>&1; }
fi
if ! command -v network_bin >/dev/null 2>&1; then
  network_bin() {
    local name="$1" cand p=""
    shift
    for cand in "$@"; do
      if [ -n "$cand" ] && [ -x "$cand" ]; then p="$cand"; break; fi
    done
    [ -n "$p" ] || p="$(command -v "$name" 2>/dev/null || true)"
    printf '%s' "$p"
  }
fi

# ── Konteks instalasi (BASE_DIR = direktori data.ini) ────────────────────────
if [ -z "${BASE_DIR:-}" ]; then
  if command -v resolve_config_path >/dev/null 2>&1; then
    resolve_config_path "$CONFIG_ARG"; init_paths; detect_os; load_and_validate_config
  else
    die "BASE_DIR tidak diketahui dan pustaka common_functions1.sh tidak tersedia."
  fi
fi

# ── Kebijakan nPerf (speedtest-repo.conf; bukan data.ini) ────────────────────
NPERF_ENABLED="${NPERF_ENABLED:-Ya}"
NPERF_HTTP_PORT="${NPERF_HTTP_PORT:-8081}"
NPERF_TLS_PORT="${NPERF_TLS_PORT:-8443}"
NPERF_REDIRECT_80="${NPERF_REDIRECT_80:-1}"
NPERF_REDIRECT_443="${NPERF_REDIRECT_443:-1}"
NPERF_AUTOSTART="${NPERF_AUTOSTART:-Ya}"
NPERF_HTTP_FILES_TMPFS="${NPERF_HTTP_FILES_TMPFS:-Tidak}"
NPERF_TMPFS_SIZE="${NPERF_TMPFS_SIZE:-1200M}"
# Ukuran berkas uji (MiB) untuk mode ramdisk — default mengikuti panduan nPerf
# (10/100/1024). Bisa diperkecil bila RAM/disk terbatas.
NPERF_HTTP_FILES_MIB="${NPERF_HTTP_FILES_MIB:-10 100 1024}"

NPERF_CONF="/etc/nperf/nperf-server.conf"
NPERF_UUID_DIR="/var/lib/nperf-server"
NPERF_UUID_FILE="$NPERF_UUID_DIR/nPerfServer.uuid"
NPERF_PID_FILE="$NPERF_UUID_DIR/nPerfServer.pid"
NPERF_DAEMON="/usr/bin/nPerfServer"
NPERF_DIR="$BASE_DIR/nperf"
NPERF_BACKUP_DIR="$NPERF_DIR/backup"
NPERF_LOG="$NPERF_DIR/install-nperf.log"
NPERF_STATE="$NPERF_DIR/.nperf-state"
NPERF_SERVICE="nperf-server"

NFT_BIN="$(network_bin nft /usr/sbin/nft /sbin/nft)"
IPTABLES_BIN="${IPTABLES_BIN:-$(network_bin iptables /usr/sbin/iptables /sbin/iptables)}"

nperf_log() {
  mkdir -p "$NPERF_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$NPERF_LOG" 2>/dev/null || true
}

# Validasi ringan nilai port.
case "$NPERF_HTTP_PORT" in
  8080|8081) ;;
  '') NPERF_HTTP_PORT="8081" ;;
  *)
    log_warn "NPERF_HTTP_PORT='$NPERF_HTTP_PORT' tidak valid (paket nPerf mensyaratkan 8080 atau 8081) → memakai 8081."
    NPERF_HTTP_PORT="8081" ;;
esac
case "$NPERF_TLS_PORT" in
  ''|*[!0-9]*) NPERF_TLS_PORT="8443" ;;
  *) [ "$NPERF_TLS_PORT" -ge 1 ] && [ "$NPERF_TLS_PORT" -le 65535 ] || NPERF_TLS_PORT="8443" ;;
esac

# ── Helper: paket terpasang? ─────────────────────────────────────────────────
nperf_pkg_installed() {
  if command_exists dpkg; then
    dpkg -s nperf-server >/dev/null 2>&1 && return 0
  fi
  if command_exists rpm; then
    rpm -q nperf-server >/dev/null 2>&1 && return 0
  fi
  [ -x "$NPERF_DAEMON" ] && return 0
  command_exists nPerfServer && return 0
  return 1
}

# ── Helper: tulis/ganti kunci di config nPerf (idempotent) ───────────────────
# conf_set_kv <file> <KEY> <VALUE> [quoted|raw]
conf_set_kv() {
  local file="$1" key="$2" val="$3" style="${4:-quoted}" line
  case "$style" in
    raw) line="${key}=${val}" ;;
    *)   line="${key}=\"${val}\"" ;;
  esac
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${line}|" "$file"
  else
    printf '%s\n' "$line" >> "$file"
  fi
}

# ── Tambah repo resmi nPerf (deb) ────────────────────────────────────────────
nperf_repo_add_deb() {
  local base="https://repository.nperf.com/api/packages/public/debian"
  local keydir="/etc/apt/keyrings" codename="" tmpkey="" line="" listfile="/etc/apt/sources.list.d/nperf.list"

  [ -d "$keydir" ] || keydir="/usr/share/keyrings"
  mkdir -p "$keydir" /etc/apt/sources.list.d 2>/dev/null || true

  # Codename: lsb_release bila ada, kalau tidak dari /etc/os-release.
  if command_exists lsb_release; then
    codename="$(lsb_release -sc 2>/dev/null || true)"
  fi
  if [ -z "$codename" ] && [ -f /etc/os-release ]; then
    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"' | head -n1)"
  fi
  if [ -z "$codename" ]; then
    log_warn "Codename distro tidak terdeteksi — repo nPerf dilewati."
    return 1
  fi

  # Baris repo. Debian 13 (trixie) direkomendasikan memakai trusted=yes
  # (kunci repo dirotasi; mengikuti instruksi resmi nPerf untuk trixie).
  case "$codename" in
    trixie) line="deb [arch=amd64 trusted=yes] $base $codename main" ;;
    *)      line="deb [arch=amd64 signed-by=$keydir/nperf.asc] $base $codename main" ;;
  esac

  # Sudah benar (termasuk kunci untuk mode signed-by) → keluar TANPA jaringan.
  # Idempotent & hemat; dipanggil juga setiap kali paket sudah terpasang untuk
  # memastikan repo tidak hilang / kunci tidak terhapus.
  key_needed=1
  case "$codename" in trixie) key_needed=0 ;; esac
  if [ -f "$listfile" ] && [ "$(cat "$listfile" 2>/dev/null)" = "$line" ] \
     && { [ "$key_needed" -eq 0 ] || [ -s "$keydir/nperf.asc" ]; }; then
    log_info "Repo nPerf (deb) sudah benar — tidak diubah."
    return 0
  fi

  # Kunci GPG (resmi). repository.key sudah dalam bentuk armor ASCII.
  tmpkey="$(mktemp 2>/dev/null || echo "/tmp/nperf-key.$$")"
  if command_exists curl; then
    curl -fsSL --max-time 60 -o "$tmpkey" "https://repository.nperf.com/api/packages/public/debian/repository.key" || true
  elif command_exists wget; then
    wget -q -T 60 -O "$tmpkey" "https://repository.nperf.com/api/packages/public/debian/repository.key" || true
  else
    log_warn "curl/wget tidak tersedia — kunci repo nPerf tidak bisa diunduh."
    rm -f "$tmpkey" 2>/dev/null || true
    return 1
  fi
  if [ ! -s "$tmpkey" ]; then
    log_warn "Unduhan kunci repo nPerf gagal (jaringan?) — repo dilewati."
    rm -f "$tmpkey" 2>/dev/null || true
    return 1
  fi
  if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmpkey" 2>/dev/null && command_exists gpg; then
    if ! gpg --dearmor -o "$keydir/nperf.asc" < "$tmpkey" 2>/dev/null; then
      # Bila dearmor gagal (mis. kunci sudah biner), pakai apa adanya.
      cp -f "$tmpkey" "$keydir/nperf.asc" 2>/dev/null || true
    fi
  else
    cp -f "$tmpkey" "$keydir/nperf.asc" 2>/dev/null || true
  fi
  rm -f "$tmpkey" 2>/dev/null || true
  chmod 644 "$keydir/nperf.asc" 2>/dev/null || true

  mkdir -p "$NPERF_BACKUP_DIR" 2>/dev/null || true
  [ -f "$listfile" ] && cp -f "$listfile" "$NPERF_BACKUP_DIR/nperf.list.bak" 2>/dev/null || true
  printf '%s\n' "$line" > "$listfile"
  log_ok "Repo nPerf (deb) ditambahkan: $line"
  nperf_log "repo deb: $line"
  return 0
}

# ── Tambah repo resmi nPerf (rpm/dnf/zypper) ─────────────────────────────────
nperf_repo_add_rpm() {
  local major="7" repofile="/etc/yum.repos.d/nperf-server.repo" url
  if [ -f /etc/os-release ]; then
    major="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | cut -d. -f1 | head -n1)"
  fi
  case "$major" in ''|*[!0-9]*) major="7" ;; esac
  url="https://repository.nperf.com/api/packages/public/rpm/rhel/${major}.repo"

  mkdir -p /etc/yum.repos.d 2>/dev/null || true
  if [ -s "$repofile" ] && grep -q 'nperf' "$repofile" 2>/dev/null; then
    log_info "Repo nPerf (rpm) sudah benar ($repofile) — tidak diubah."
    return 0
  fi
  if command_exists rpm; then
    if command_exists curl; then
      curl -fsSL --max-time 60 "https://repository.nperf.com/api/packages/public/rpm/rhel/${major}.repo" >/dev/null 2>&1 \
        || log_warn "Repo RPM rhel/${major}.repo tidak bisa diverifikasi (lanjut dengan berkas lokal)."
    fi
  fi
  if command_exists curl; then
    if curl -fsSL --max-time 60 -o "$repofile.new" "$url" 2>/dev/null && [ -s "$repofile.new" ]; then
      mkdir -p "$NPERF_BACKUP_DIR" 2>/dev/null || true
      [ -f "$repofile" ] && cp -f "$repofile" "$NPERF_BACKUP_DIR/nperf-server.repo.bak" 2>/dev/null || true
      mv -f "$repofile.new" "$repofile"
      log_ok "Repo nPerf (rpm) ditambahkan: $repofile"
      nperf_log "repo rpm: $url"
      return 0
    fi
    rm -f "$repofile.new" 2>/dev/null || true
  fi
  log_warn "Repo RPM nPerf gagal dipasang (jaringan?) — instalasi paket dilewati."
  return 1
}

# ── Pasang paket nperf-server ────────────────────────────────────────────────
nperf_install_pkg() {
  case "${OS_FAMILY:-unknown}" in
    debian) nperf_repo_add_deb || return 1 ;;
    rhel|suse) nperf_repo_add_rpm || return 1 ;;
    *) return 1 ;;
  esac
  if command_exists pkg_update; then pkg_update || true; fi
  log_info "Memasang paket nperf-server ..."
  if command_exists pkg_install; then
    pkg_install nperf-server || {
      log_warn "Instalasi paket nperf-server GAGAL (repo/jaringan?). Percobaan ulang otomatis oleh self-update harian."
      return 1
    }
  else
    return 1
  fi
  if nperf_pkg_installed; then
    log_ok "Paket nperf-server terpasang."
    nperf_log "paket nperf-server terpasang"
    return 0
  fi
  log_warn "Paket nperf-server belum terdeteksi setelah instalasi."
  return 1
}

# ── Terapkan config nPerf (idempotent; hanya 4 kunci kebijakan) ──────────────
# return 0 = berubah (perlu restart), 1 = tidak berubah, 2 = gagal
nperf_conf_apply() {
  local before="" after="" changed=0
  mkdir -p "$(dirname "$NPERF_CONF")" 2>/dev/null || true
  [ -f "$NPERF_CONF" ] || {
    log_warn "$NPERF_CONF tidak ada (paket belum terpasang?) — config tidak diterapkan."
    return 2
  }
  before="$(cat "$NPERF_CONF")"

  conf_set_kv "$NPERF_CONF" PORT "$NPERF_HTTP_PORT" quoted
  conf_set_kv "$NPERF_CONF" TLS_PORT "$NPERF_TLS_PORT" quoted
  conf_set_kv "$NPERF_CONF" REDIRECT_PORT_80 "$NPERF_REDIRECT_80" raw
  conf_set_kv "$NPERF_CONF" REDIRECT_PORT_443 "$NPERF_REDIRECT_443" raw

  after="$(cat "$NPERF_CONF")"
  if [ "$before" != "$after" ]; then
    changed=1
    mkdir -p "$NPERF_BACKUP_DIR" 2>/dev/null || true
    printf '%s' "$before" > "$NPERF_BACKUP_DIR/nperf-server.conf.bak" 2>/dev/null || true
    log_ok "Config nPerf diperbarui: PORT=$NPERF_HTTP_PORT TLS_PORT=$NPERF_TLS_PORT REDIRECT_80=$NPERF_REDIRECT_80 REDIRECT_443=$NPERF_REDIRECT_443"
    nperf_log "config diperbarui"
  else
    log_info "Config nPerf sudah sesuai (PORT=$NPERF_HTTP_PORT, TLS_PORT=$NPERF_TLS_PORT)."
  fi
  [ "$changed" -eq 1 ] && return 0
  return 1
}

# ── Opsional: ramdisk 1,2 GB + berkas HTTP (pola resmi nPerf) ────────────────
nperf_tmpfs_setup() {
  [ "$NPERF_HTTP_FILES_TMPFS" = "Ya" ] || return 0
  log_info "Menyiapkan ramdisk nPerf ($NPERF_TMPFS_SIZE) di /var/www/html/nperf ..."
  mkdir -p /var/www/html/nperf "$NPERF_DIR/http-files" 2>/dev/null || true
  if command_exists mountpoint && mountpoint -q /var/www/html/nperf 2>/dev/null; then
    log_info "Ramdisk /var/www/html/nperf sudah ter-mount."
  else
    mount -t tmpfs -o "defaults,size=${NPERF_TMPFS_SIZE}" tmpfs /var/www/html/nperf 2>/dev/null \
      || log_warn "Gagal me-mount tmpfs di /var/www/html/nperf (lanjut tanpa ramdisk)."
  fi
  # Berkas wajib (unduh upload.php resmi; sisanya dibuat lokal).
  if command_exists curl; then
    curl -fsSL --max-time 60 -o "$NPERF_DIR/http-files/upload.php" \
      "https://repository.nperf.com/conf/upload.php.src" 2>/dev/null || true
  fi
  printf 'OK\n' > "$NPERF_DIR/http-files/latency.txt" 2>/dev/null || true
  local sz
  for sz in $NPERF_HTTP_FILES_MIB; do
    case "$sz" in ''|*[!0-9]*) continue ;; esac
    [ -s "$NPERF_DIR/http-files/${sz}MiB.dat" ] || \
      head -c "$((sz * 1024 * 1024))" /dev/urandom > "$NPERF_DIR/http-files/${sz}MiB.dat" 2>/dev/null || true
  done
  cp -pu "$NPERF_DIR"/http-files/* /var/www/html/nperf/ 2>/dev/null || true
  # Salin ulang saat reboot (ramdisk bersifat volatil) — pakai path absolut.
  if command_exists cron_apply; then
    cron_apply "# nperf-ramdisk (managed)" \
      "@reboot /bin/cp -pu $NPERF_DIR/http-files/* /var/www/html/nperf/ >/dev/null 2>&1" || true
  fi
  log_ok "Ramdisk nPerf siap ($NPERF_TMPFS_SIZE)."
  nperf_log "ramdisk tmpfs aktif"
}

# ── Service: enable + start/restart ──────────────────────────────────────────
nperf_service_apply() {
  local need_restart="$1"
  if command_exists systemctl && [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$NPERF_AUTOSTART" = "Ya" ]; then
      systemctl enable "$NPERF_SERVICE" >/dev/null 2>&1 || true
    fi
    # Watchdog cron bawaan paket (dibuat hanya oleh 'setup-initd-autostart')
    # akan bertabrakan dengan systemd → hapus bila ada.
    if [ -f /etc/cron.d/nperf-server ]; then
      rm -f /etc/cron.d/nperf-server 2>/dev/null || true
      log_info "Watchdog cron bawaan nPerf (/etc/cron.d/nperf-server) dihapus (memakai systemd)."
    fi
    if [ "$need_restart" = "1" ]; then
      systemctl restart "$NPERF_SERVICE" >/dev/null 2>&1 || systemctl start "$NPERF_SERVICE" >/dev/null 2>&1 || true
    else
      systemctl start "$NPERF_SERVICE" >/dev/null 2>&1 || true
    fi
    nperf_log "service systemd: enable/start (restart=$need_restart)"
    return 0
  fi
  # Tanpa systemd → init script + autostart via cron (@reboot) yang kita kelola.
  if [ -x /etc/init.d/nperf-server ]; then
    /etc/init.d/nperf-server start >/dev/null 2>&1 || true
    if [ "$NPERF_AUTOSTART" = "Ya" ] && command_exists cron_apply; then
      cron_apply "# nperf-server (managed)" \
        "@reboot /etc/init.d/nperf-server start >/dev/null 2>&1" || true
    fi
    nperf_log "service init.d: start"
    return 0
  fi
  log_warn "Service nPerf tidak bisa dijalankan (systemd & init.d tidak ada)."
  return 1
}

# ── Verifikasi (dipakai instalasi & --status) ────────────────────────────────
nperf_verify() {
  local rc=0 out=""

  if command_exists curl; then
    out="$(curl -s -m 5 -i "http://127.0.0.1:${NPERF_HTTP_PORT}/" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -q 'Server: nPerf'; then
      log_ok "  nPerf menjawab HTTP di 127.0.0.1:${NPERF_HTTP_PORT} (Server: nPerf)."
    else
      log_warn "  nPerf belum menjawab di 127.0.0.1:${NPERF_HTTP_PORT} (cek: /etc/init.d/nperf-server status)."
      rc=1
    fi
  else
    log_warn "  curl tidak tersedia — verifikasi HTTP nPerf dilewati."
  fi

  if command_exists openssl; then
    if command_exists timeout; then
      out="$(timeout 8 openssl s_client -connect "127.0.0.1:${NPERF_TLS_PORT}" -servername localhost </dev/null 2>&1 || true)"
    else
      out="$(openssl s_client -connect "127.0.0.1:${NPERF_TLS_PORT}" -servername localhost </dev/null 2>&1 || true)"
    fi
    if printf '%s' "$out" | grep -qE 'BEGIN CERTIFICATE|Server certificate'; then
      log_ok "  TLS nPerf aktif di 127.0.0.1:${NPERF_TLS_PORT} (sertifikat dikelola nPerf)."
    else
      log_warn "  TLS nPerf belum menjawab di 127.0.0.1:${NPERF_TLS_PORT} (normal sesaat setelah start)."
    fi
  fi

  if [ -s "$NPERF_UUID_FILE" ]; then
    log_ok "  Identitas nPerf tersimpan (UUID: $(cut -c1-8 "$NPERF_UUID_FILE" 2>/dev/null)…)."
  else
    log_warn "  UUID nPerf belum ada di $NPERF_UUID_FILE (dibuat saat daemon pertama jalan)."
  fi

  # Rule redirect nftables (bila diaktifkan).
  if [ -n "$NFT_BIN" ]; then
    local rules=""
    rules="$("$NFT_BIN" list ruleset 2>/dev/null || true)"
    if [ "$NPERF_REDIRECT_80" = "1" ]; then
      if printf '%s' "$rules" | grep -qE "dport 80 redirect to ${NPERF_HTTP_PORT}"; then
        log_ok "  Redirect 80 → ${NPERF_HTTP_PORT} aktif (nftables)."
      else
        log_warn "  Redirect 80 → ${NPERF_HTTP_PORT} tidak terlihat di nftables."
      fi
    fi
    if [ "$NPERF_REDIRECT_443" = "1" ]; then
      if printf '%s' "$rules" | grep -qE "dport 443 redirect to ${NPERF_TLS_PORT}"; then
        log_ok "  Redirect 443 → ${NPERF_TLS_PORT} aktif (nftables)."
      else
        log_warn "  Redirect 443 → ${NPERF_TLS_PORT} tidak terlihat di nftables."
      fi
    fi
    if printf '%s' "$rules" | grep -q 'comment "nPerfServer"'; then
      log_ok "  Rule anti-DOS/redirect nPerfServer terpasang di nftables."
    else
      log_warn "  Rule ber-comment \"nPerfServer\" tidak ditemukan di nftables."
    fi
  else
    log_warn "  nftables (nft) tidak terdeteksi — redirect 80/443 tidak akan berjalan."
  fi
  return "$rc"
}

nperf_state_write() {
  local ver="" uuid=""
  if command_exists dpkg; then
    ver="$(dpkg-query -W -f='${Version}' nperf-server 2>/dev/null || true)"
  fi
  if [ -z "$ver" ] && command_exists rpm; then
    ver="$(rpm -q --qf '%{VERSION}-%{RELEASE}' nperf-server 2>/dev/null || true)"
  fi
  [ -n "$ver" ] || ver="unknown"
  [ -s "$NPERF_UUID_FILE" ] && uuid="$(cat "$NPERF_UUID_FILE" 2>/dev/null)"

  mkdir -p "$NPERF_DIR" 2>/dev/null || true
  cat > "$NPERF_STATE" <<STATEOF
# nPerf state - generated by bagian12_nperf_server.sh (jangan diedit manual)
NPERF_VERSION=$ver
NPERF_HTTP_PORT=$NPERF_HTTP_PORT
NPERF_TLS_PORT=$NPERF_TLS_PORT
NPERF_REDIRECT_80=$NPERF_REDIRECT_80
NPERF_REDIRECT_443=$NPERF_REDIRECT_443
NPERF_AUTOSTART=$NPERF_AUTOSTART
NPERF_HTTP_FILES_TMPFS=$NPERF_HTTP_FILES_TMPFS
NPERF_UUID=$uuid
NPERF_UPDATED_AT=$(date '+%Y-%m-%d %H:%M:%S')
STATEOF
  chmod 600 "$NPERF_STATE" 2>/dev/null || true
}

nperf_status_print() {
  local ver=""
  if command_exists dpkg; then ver="$(dpkg-query -W -f='${Version}' nperf-server 2>/dev/null || true)"; fi
  [ -n "$ver" ] || { command_exists rpm && ver="$(rpm -q --qf '%{VERSION}' nperf-server 2>/dev/null || true)"; }
  printf 'nPerf Server (layanan speedtest kedua)\n'
  printf '  status     : %s\n' "$(nperf_pkg_installed && echo "paket terpasang (versi ${ver:-?})" || echo 'paket TIDAK terpasang')"
  printf '  port HTTP  : %s\n' "$NPERF_HTTP_PORT"
  printf '  port TLS   : %s\n' "$NPERF_TLS_PORT"
  printf '  redirect   : 80→%s (%s), 443→%s (%s)\n' "$NPERF_HTTP_PORT" "$NPERF_REDIRECT_80" "$NPERF_TLS_PORT" "$NPERF_REDIRECT_443"
  printf '  UUID       : %s\n' "$([ -s "$NPERF_UUID_FILE" ] && cut -c1-8 "$NPERF_UUID_FILE" || echo '(belum ada)')…"
  if [ -n "$NFT_BIN" ]; then
    printf '  nftables   : %s rule nPerfServer\n' "$("$NFT_BIN" list ruleset 2>/dev/null | grep -c 'nPerfServer' || echo 0)"
  fi
  if command_exists systemctl && [ -d /run/systemd/system ]; then
    printf '  service    : %s\n' "$(systemctl is-active "$NPERF_SERVICE" 2>/dev/null || echo unknown)"
  fi
  [ -f "$NPERF_STATE" ] && { printf '  state file : %s\n' "$NPERF_STATE"; }
}

# ── Alur utama ───────────────────────────────────────────────────────────────
main() {
  log_info "== Bagian 12: nPerf Server (layanan kedua) =="

  if [ "$NPERF_ENABLED" != "Ya" ]; then
    log_info "NPERF_ENABLED=Tidak → modul nPerf dilewati."
    return 0
  fi
  case "${OS_FAMILY:-unknown}" in
    alpine)
      log_warn "nPerf TIDAK menyediakan paket untuk Alpine — modul dilewati."
      log_warn "  (nPerf hanya mendukung Debian/Ubuntu & RHEL/CentOS/SUSE 64-bit.)"
      return 0 ;;
    debian|rhel|suse) ;;
    *)
      log_warn "OS family '${OS_FAMILY:-unknown}' belum dipetakan — modul nPerf dilewati."
      return 0 ;;
  esac

  mkdir -p "$NPERF_DIR" "$NPERF_BACKUP_DIR" 2>/dev/null || true
  nperf_log "=== bagian12 mulai (mode=$MODE) ==="

  # Peringatan bentrok port dengan OoklaServer (bila operator mengubah default).
  if command_exists ookla_props_ports && [ -n "${OOKLA_PROPERTIES:-}" ]; then
    local p
    for p in $(ookla_props_ports "$OOKLA_PROPERTIES" 2>/dev/null || true); do
      if [ "$p" = "$NPERF_HTTP_PORT" ] || [ "$p" = "$NPERF_TLS_PORT" ]; then
        log_warn "Port nPerf $p juga dipakai OoklaServer menurut $OOKLA_PROPERTIES — ubah salah satu!"
      fi
    done
  fi

  # 1) Paket — dilewati bila sudah terpasang (idempotent).
  if ! nperf_pkg_installed; then
    # Kegagalan di sini bersifat DEFERRABLE: penyebab tersering adalah repo/
    # jaringan nPerf yang belum bisa dihubungi. Instalasi utama (OoklaServer)
    # TIDAK boleh digagalkan karena layanan kedua; self-update harian mencoba
    # lagi otomatis. Karena itu rc tetap 0 (install.sh berhenti bila rc != 0).
    if ! nperf_install_pkg; then
      log_warn "nPerf belum terpasang. Bagian lain tetap jalan; percobaan ulang"
      log_warn "dilakukan otomatis oleh self-update harian, atau manual:"
      log_warn "  bash $BASE_DIR/bagian12_nperf_server.sh"
      nperf_state_write
      return 0
    fi
  else
    log_info "Paket nperf-server sudah terpasang — melewati instalasi paket."
    # Repo resmi tetap dipastikan ada (mis. berkas repo terhapus manual) agar
    # pembaruan paket nPerf tetap mengalir. Tanpa jaringan bila sudah benar.
    case "${OS_FAMILY:-unknown}" in
      debian)     nperf_repo_add_deb || true ;;
      rhel|suse)  nperf_repo_add_rpm || true ;;
    esac
  fi

  # Mode config-only: cukup pastikan config + service (self-update harian).
  if [ "$MODE" = "config" ]; then
    local ch=0
    nperf_conf_apply && ch=1        # ch=1 → config berubah → service perlu restart
    nperf_tmpfs_setup
    nperf_service_apply "$ch"
    nperf_state_write
    log_ok "Penegakan konfigurasi nPerf selesai (mode --config-only)."
    return 0
  fi

  # 2) Config + 3) service + 4) ramdisk opsional
  local conf_changed=0
  nperf_conf_apply && conf_changed=1   # 1 = config berubah → restart
  nperf_tmpfs_setup
  nperf_service_apply "$conf_changed"

  # 5) Verifikasi
  log_info "Verifikasi nPerf:"
  nperf_verify || true
  nperf_state_write

  log_ok "Bagian 12 selesai — nPerf Server aktif (HTTP ${NPERF_HTTP_PORT}, TLS ${NPERF_TLS_PORT})."
  log_info "Validasi server di port standar: https://server-check.nperf.com/"
  log_info "Pendaftaran server ke daftar publik nPerf: ajukan ke nPerf (bukan otomatis)."
  nperf_log "=== bagian12 selesai ==="
  return 0
}

if [ "$MODE" = "status" ]; then
  nperf_status_print
  exit 0
fi

if main; then
  exit 0
else
  exit 1
fi
