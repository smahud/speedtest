#!/usr/bin/env bash
###############################################################################
# bagian7_network.sh — ZeroTier MANDATORY (jaringan kontrol operator)
#
#   - Network ID / Moon ID / Moon URL DI-HARDCODE DI REPO (speedtest-repo.conf),
#     bukan di data.ini. Semua server yang diinstal dari repo ini WAJIB
#     tergabung ke jaringan ZeroTier operator.
#   - Instalasi GAGAL (exit 1) bila ZeroTier tidak bisa dipasang, tidak online,
#     atau (bila ZT_REQUIRE_AUTHORIZATION=Ya) node belum di-authorize.
#     Karena install.sh idempotent dan dijalankan berkala oleh self-update,
#     instalasi akan otomatis mengulang sampai Anda meng-authorize node-nya.
#   - Exit node (IP forwarding + NAT) hanya bila ZT_ENABLE_EXIT_NODE=Ya.
#   - Rule NAT dibuat IDEMPOTENT (dicek dulu) dan bisa ditegakkan ulang dengan
#     `bagian7_network.sh -postboot` (dipasang sebagai cron @reboot oleh bagian11).
#
# Versi: 8.0
###############################################################################
set -uo pipefail

SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR

# Source pustaka pendukung
if [ -f "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh" ]; then
  # shellcheck source=common_functions1.sh
  . "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"
fi

# Fallback logger jika common tidak termuat (skenario postboot)
if ! command -v log_info >/dev/null 2>&1; then
  log_info()  { printf '[INFO] %s\n' "$1"; }
  log_ok()    { printf '[OK] %s\n' "$1"; }
  log_warn()  { printf '[WARN] %s\n' "$1" >&2; }
  log_error() { printf '[ERROR] %s\n' "$1" >&2; }
  die()       { log_error "$1"; exit "${2:-1}"; }
fi
if ! command -v command_exists >/dev/null 2>&1; then
  command_exists() { command -v "$1" >/dev/null 2>&1; }
fi

MODE="${1:-}"

if [ -z "${BASE_DIR:-}" ]; then
  if [ "$MODE" != "-postboot" ] && command -v resolve_config_path >/dev/null 2>&1; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
  fi
fi

# Bila konfigurasi repo belum termuat (common tidak ada), baca langsung.
if [ -z "${ZT_NETWORK_ID:-}" ] && [ -n "${BASE_DIR:-}" ] && [ -f "$BASE_DIR/auto_update_lib.sh" ]; then
  # shellcheck source=auto_update_lib.sh
  . "$BASE_DIR/auto_update_lib.sh"
  au_load_repo_config "$BASE_DIR" >/dev/null
fi

# ===============================
# KONFIGURASI UTAMA (HARDCODE REPO)
# ===============================
NETWORK_ID="${ZT_NETWORK_ID:-${ZeroTierNetworkID:-72ff30f9733a82d9}}"
MOON_ID="${ZT_MOON_ID:-${ZeroTierMoonID:-72ff30f973}}"
MOON_CONFIG_URL="${ZT_MOON_CONFIG_URL:-${ZeroTierMoonConfigURL:-https://moon.zerotier.my.id/moon.json}}"
ZT_ENABLE_EXIT_NODE="${ZT_ENABLE_EXIT_NODE:-Ya}"
ZT_REQUIRE_AUTHORIZATION="${ZT_REQUIRE_AUTHORIZATION:-Ya}"
ZT_AUTH_TIMEOUT="${ZT_AUTH_TIMEOUT:-180}"
ZT_INSTALL_IF_MISSING="${ZT_INSTALL_IF_MISSING:-Ya}"

ZEROTIER_BIN="/usr/sbin/zerotier-one"
ZEROTIER_CLI="/usr/sbin/zerotier-cli"
UPDATER_SCRIPT="/usr/local/bin/zt-moon-updater.sh"
UPDATER_LOG="/var/log/zt-moon-updater.log"
UPDATER_CRON_TAG="# zt-moon-updater (managed)"

# zerotier-cli tidak selalu ada di PATH (mis. cron: PATH=/usr/bin:/bin).
zt_cli_path() {
  if [ -x "$ZEROTIER_CLI" ]; then printf '%s' "$ZEROTIER_CLI"
  elif command_exists zerotier-cli; then command -v zerotier-cli
  else printf ''
  fi
}

# ===============================
# HELPER: Stop / Start ZeroTier
# ===============================
stop_zerotier() {
  if command_exists systemctl && [ -d /run/systemd/system ]; then
    systemctl stop zerotier-one 2>/dev/null || true
  elif command_exists rc-service; then
    rc-service zerotier-one stop 2>/dev/null || true
  fi
  if command_exists pgrep && pgrep -x zerotier-one >/dev/null 2>&1; then
    pkill zerotier-one 2>/dev/null || true
    sleep 2
  fi
  return 0
}

start_zerotier_service() {
  if command_exists systemctl && [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable zerotier-one >/dev/null 2>&1 || true
    systemctl start zerotier-one >/dev/null 2>&1 || true
  elif command_exists rc-service; then
    if [ ! -f /etc/init.d/zerotier-one ]; then
      cat > /etc/init.d/zerotier-one <<'EOF'
#!/sbin/openrc-run
description="ZeroTier One"
command="/usr/sbin/zerotier-one"
command_args="-d"
pidfile="/run/zerotier-one.pid"
depend() {
  need net
  after bootmisc
}
EOF
      chmod +x /etc/init.d/zerotier-one
    fi
    rc-update add zerotier-one default >/dev/null 2>&1 || true
    rc-service zerotier-one start >/dev/null 2>&1 || true
  else
    "$ZEROTIER_BIN" -d >/dev/null 2>&1 || true
  fi
  return 0
}

# ===============================
# INSTALL ZEROTIER (WAJIB)
# ===============================
install_zerotier() {
  if [ -x "$ZEROTIER_BIN" ]; then
    log_ok "Binary ZeroTier sudah ada: $ZEROTIER_BIN"
  else
    if [ "$ZT_INSTALL_IF_MISSING" != "Ya" ]; then
      log_error "ZeroTier belum terpasang dan ZT_INSTALL_IF_MISSING=Tidak."
      return 1
    fi
    log_info "Memasang ZeroTier (metode resmi / packet manager / binary statis)..."
    stop_zerotier

    if [ "${OS_FAMILY:-}" = "alpine" ]; then
      local alpine_ver repo_added=0 repo_url arch raw_url remote_bin tmp_bin
      alpine_ver="$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || echo 'latest-stable')"

      if [ -f /etc/apk/repositories ]; then
        for repo_url in \
          "https://dl-cdn.alpinelinux.org/alpine/v$alpine_ver/community" \
          "https://dl-cdn.alpinelinux.org/alpine/edge/community"; do
          if ! grep -q "$repo_url" /etc/apk/repositories; then
            echo "$repo_url" >> /etc/apk/repositories
            repo_added=1
          fi
        done
        if [ "$repo_added" -eq 1 ]; then
          apk update >/dev/null 2>&1 || true
        fi
      fi

      if apk add --no-cache zerotier-one >/dev/null 2>&1; then
        log_ok "ZeroTier terpasang via apk."
      else
        log_warn "apk gagal, mencoba binary statis dari repo..."
        arch="$(uname -m)"
        raw_url="${REPO_RAW_BASE_DEFAULT:-https://raw.githubusercontent.com/smahud/speedtest/main}"
        remote_bin="$raw_url/zerotier/zerotier-one-$arch-alpine"
        tmp_bin="$(mktemp)"
        if wget -q -O "$tmp_bin" "$remote_bin" 2>/dev/null; then
          # Verifikasi SHA-256 bila file checksum tersedia di repo (mencegah
          # mengeksekusi biner yang korrupt/ditukar).
          sum_url="$remote_bin.sha256"
          tmp_sum="$(mktemp)"
          if wget -q -O "$tmp_sum" "$sum_url" 2>/dev/null && [ -s "$tmp_sum" ]; then
            want_sum="$(awk 'NR==1{print $1}' "$tmp_sum" 2>/dev/null)"
            if command -v sha256sum >/dev/null 2>&1; then
              got_sum="$(sha256sum "$tmp_bin" | awk '{print $1}')"
            elif command -v busybox >/dev/null 2>&1; then
              got_sum="$(busybox sha256sum "$tmp_bin" | awk '{print $1}')"
            else
              got_sum=""
            fi
            if [ -n "$want_sum" ] && [ -n "$got_sum" ] && [ "$want_sum" != "$got_sum" ]; then
              rm -f "$tmp_bin" "$tmp_sum"
              log_error "Checksum biner ZeroTier TIDAK cocok — dibatalkan."
              return 1
            fi
            log_ok "Checksum biner ZeroTier terverifikasi."
          else
            log_warn "File checksum biner ZeroTier tidak tersedia — melanjutkan tanpa verifikasi."
          fi
          rm -f "$tmp_sum" 2>/dev/null || true

          mkdir -p "$(dirname "$ZEROTIER_BIN")" 2>/dev/null || true
          mv -f "$tmp_bin" "$ZEROTIER_BIN"
          chmod +x "$ZEROTIER_BIN"
          [ -L /usr/sbin/zerotier-cli ] || ln -sf "$ZEROTIER_BIN" /usr/sbin/zerotier-cli
          [ -L /usr/sbin/zerotier-idtool ] || ln -sf "$ZEROTIER_BIN" /usr/sbin/zerotier-idtool
          mkdir -p /var/lib/zerotier-one
          log_ok "ZeroTier terpasang via binary statis ($arch)."
        else
          rm -f "$tmp_bin"
          log_error "Gagal mengunduh binary ZeroTier: $remote_bin"
          return 1
        fi
      fi
    else
      log_info "Memakai installer resmi ZeroTier (Debian/RedHat)..."
      if curl -fsSL https://install.zerotier.com 2>/dev/null | bash >/dev/null 2>&1; then
        log_ok "ZeroTier terpasang via installer resmi."
      else
        log_warn "Installer resmi gagal, mencoba packet manager..."
        local ok=0
        if command_exists apt-get; then
          DEBIAN_FRONTEND=noninteractive apt-get install -y zerotier-one >/dev/null 2>&1 && ok=1
        elif command_exists dnf; then
          dnf install -y zerotier-one >/dev/null 2>&1 && ok=1
        elif command_exists yum; then
          yum install -y zerotier-one >/dev/null 2>&1 && ok=1
        fi
        if [ "$ok" -ne 1 ]; then
          log_error "Semua metode pemasangan ZeroTier gagal."
          return 1
        fi
        log_ok "ZeroTier terpasang via packet manager."
      fi
    fi
  fi

  start_zerotier_service
  sleep 3
  if [ ! -x "$ZEROTIER_BIN" ]; then
    log_error "Binary ZeroTier tidak ditemukan di $ZEROTIER_BIN setelah pemasangan."
    return 1
  fi
  return 0
}

# ===============================
# VERIFY SERVICE
# ===============================
verify_zerotier_service() {
  log_info "Memverifikasi service ZeroTier..."
  local cli status_output
  cli="$(zt_cli_path)"
  if [ -z "$cli" ]; then
    log_error "zerotier-cli tidak ditemukan."
    return 1
  fi

  status_output="$("$cli" info 2>/dev/null || true)"
  if printf '%s' "$status_output" | grep -qE 'ONLINE|TUNNELED'; then
    log_ok "ZeroTier online."
    return 0
  fi

  log_warn "ZeroTier belum online, mencoba start ulang..."
  stop_zerotier
  sleep 2
  start_zerotier_service
  sleep 5
  status_output="$("$cli" info 2>/dev/null || true)"
  if printf '%s' "$status_output" | grep -qE 'ONLINE|TUNNELED'; then
    log_ok "ZeroTier online setelah restart."
    return 0
  fi
  log_error "Service ZeroTier tidak online. Status: ${status_output:-<kosong>}"
  return 1
}

# ===============================
# JOIN NETWORK
# ===============================
join_network() {
  local cli
  cli="$(zt_cli_path)"
  [ -n "$cli" ] || return 1

  log_info "Memastikan join ke network kontrol $NETWORK_ID ..."
  if "$cli" listnetworks 2>/dev/null | grep -q "$NETWORK_ID"; then
    log_ok "Sudah tergabung ke network $NETWORK_ID."
    return 0
  fi
  if "$cli" join "$NETWORK_ID" >/dev/null 2>&1; then
    log_ok "Berhasil join ke network $NETWORK_ID."
    return 0
  fi
  log_error "Gagal join ke network $NETWORK_ID."
  return 1
}

# ===============================
# AUTHORIZATION (dengan waktu tunggu)
# ===============================
network_status_line() {
  local cli="$1"
  "$cli" listnetworks 2>/dev/null | grep "$NETWORK_ID" || true
}

is_authorized() {
  local cli line
  cli="$(zt_cli_path)"
  [ -n "$cli" ] || return 1
  line="$(network_status_line "$cli")"
  printf '%s' "$line" | grep -q ' OK '
}

wait_authorization() {
  local cli node_id line waited=0 timeout="$ZT_AUTH_TIMEOUT"
  cli="$(zt_cli_path)"
  node_id="$("$cli" info 2>/dev/null | awk '{print $3}')"

  log_info "Menunggu authorization node $node_id di jaringan $NETWORK_ID (maks ${timeout}s)..."
  while [ "$waited" -lt "$timeout" ]; do
    if is_authorized; then
      log_ok "Node ter-authorize (status OK)."
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    if [ $((waited % 30)) -eq 0 ]; then
      line="$(network_status_line "$cli")"
      log_info "  ... ${waited}s — status: ${line:-<belum terlihat>}"
    fi
  done

  line="$(network_status_line "$cli")"
  log_error "Node BELUM di-authorize setelah ${timeout}s (Node ID: $node_id, status: ${line:-<kosong>})."
  log_error "Buka controller ZeroTier Anda → network $NETWORK_ID → AUTHORIZE node $node_id"
  log_error "atau (bila node diketahui lewat API/CLI controller): authorize by node ID."
  return 1
}

# ===============================
# IP FORWARDING + NAT (idempotent)
# ===============================
enable_ip_forwarding() {
  log_info "Mengaktifkan IP forwarding..."
  if [ -d /etc/sysctl.d ]; then
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
    sysctl -p /etc/sysctl.d/99-ipforward.conf >/dev/null 2>&1 || true
  else
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null \
      || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  local cur
  cur="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  if [ "$cur" = "1" ]; then
    log_ok "IP forwarding aktif."
    return 0
  fi
  log_warn "IP forwarding belum aktif (nilai: $cur)."
  return 1
}

# Tambah rule hanya bila belum ada (mencegah penumpukan saat dijalankan ulang).
ipt_ensure() {
  # $1 = chain spec, $2.. = rule args
  local spec="$1"; shift
  if iptables -C "$spec" "$@" 2>/dev/null; then
    return 0
  fi
  iptables -A "$spec" "$@" 2>/dev/null || return 1
  return 0
}

setup_nat() {
  log_info "Konfigurasi NAT masquerade (idempotent)..."
  if ! command_exists iptables; then
    log_warn "iptables tidak tersedia — NAT dilewati."
    return 1
  fi

  local ZT_INTERFACE PUBLIC_INTERFACE
  ZT_INTERFACE="$(ip -o link show 2>/dev/null | grep -o 'zt[a-z0-9]*' | head -n 1)"
  PUBLIC_INTERFACE="$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n 1)"

  if [ -z "$ZT_INTERFACE" ] || [ -z "$PUBLIC_INTERFACE" ]; then
    log_warn "Interface tidak ditemukan (ZT='${ZT_INTERFACE}', PUBLIC='${PUBLIC_INTERFACE}'). NAT dilewati."
    return 1
  fi

  ipt_ensure POSTROUTING -t nat -o "$PUBLIC_INTERFACE" -j MASQUERADE || true
  ipt_ensure FORWARD -i "$ZT_INTERFACE" -o "$PUBLIC_INTERFACE" -j ACCEPT || true
  ipt_ensure FORWARD -i "$PUBLIC_INTERFACE" -o "$ZT_INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT || true
  log_ok "NAT: $ZT_INTERFACE → $PUBLIC_INTERFACE (masquerade)."
  return 0
}

# ===============================
# MOON UPDATER (script mandiri + cron)
# ===============================
write_moon_updater() {
  # PENTING: heredoc TANPA kutip sehingga nilai MOON_ID/MOON_CONFIG_URL dari
  # speedtest-repo.conf benar-benar tertanam (sebelumnya di-quote → nilai
  # data.ini/env selalu diabaikan dan jatuh ke default).
  cat > "$UPDATER_SCRIPT" <<SCRIPTEOF
#!/bin/sh
# Dikelola otomatis oleh speedtest installer (bagian7). Jangan diedit manual.
MOON_ID="$MOON_ID"
MOON_CONFIG_URL="$MOON_CONFIG_URL"
ZT_CLI="$ZEROTIER_CLI"
LOG_FILE="$UPDATER_LOG"

log() { printf '%s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$1" >> "\$LOG_FILE" 2>/dev/null || true; }

[ -x "\$ZT_CLI" ] || ZT_CLI="\$(command -v zerotier-cli 2>/dev/null)"
if [ -z "\$ZT_CLI" ]; then
  log "FAILED: zerotier-cli tidak ditemukan"
  exit 1
fi

MOON_FILE="/tmp/zt-moon.json.\$\$"
if ! wget -q -O "\$MOON_FILE" "\$MOON_CONFIG_URL" 2>/dev/null; then
  rm -f "\$MOON_FILE"
  log "FAILED: tidak bisa mengunduh \$MOON_CONFIG_URL"
  exit 1
fi

# Ambil endpoint pertama dari stableEndpoints (pakai jq bila ada, jika tidak
# pakai ekstraksi teks sederhana agar tidak bergantung pada paket tambahan).
ENDPOINT=""
if command -v jq >/dev/null 2>&1; then
  ENDPOINT="\$(jq -r '.roots[0].stableEndpoints[0] // empty' "\$MOON_FILE" 2>/dev/null)"
fi
if [ -z "\$ENDPOINT" ]; then
  ENDPOINT="\$(tr -d ' \n\t' < "\$MOON_FILE" | sed -n 's/.*"stableEndpoints":\\["\([^"]*\)".*/\1/p')"
fi
rm -f "\$MOON_FILE"

if [ -z "\$ENDPOINT" ]; then
  log "FAILED: endpoint moon tidak ditemukan di \$MOON_CONFIG_URL"
  exit 1
fi

if "\$ZT_CLI" orbit "\$MOON_ID" "\$ENDPOINT" >/dev/null 2>&1; then
  log "OK: orbit \$MOON_ID via \$ENDPOINT"
  exit 0
fi
log "FAILED: orbit \$MOON_ID via \$ENDPOINT gagal"
exit 1
SCRIPTEOF
  chmod +x "$UPDATER_SCRIPT" 2>/dev/null || true
}

install_moon_updater() {
  log_info "Menyiapkan moon updater (moon: $MOON_ID)..."
  write_moon_updater

  if ! command_exists crontab; then
    log_warn "crontab tidak tersedia — moon updater tidak dijadwalkan."
    return 0
  fi

  if cron_apply "$UPDATER_CRON_TAG" "*/15 * * * * $UPDATER_SCRIPT >/dev/null 2>&1"; then
    log_ok "Moon updater dijadwalkan tiap 15 menit."
  else
    log_warn "Gagal menjadwalkan moon updater."
  fi
  return 0
}

run_moon_updater_now() {
  [ -x "$UPDATER_SCRIPT" ] || return 0
  log_info "Menjalankan orbit moon sekali sekarang..."
  if "$UPDATER_SCRIPT" >/dev/null 2>&1; then
    log_ok "Orbit moon berhasil (detail: $UPDATER_LOG)."
  else
    log_warn "Orbit moon gagal (detail: $UPDATER_LOG) — akan dicoba lagi via cron."
  fi
  return 0
}

# ===============================
# MAIN
# ===============================
main() {
  log_info "== Bagian 7: ZeroTier (wajib) — network kontrol =="
  log_info "Network ID : $NETWORK_ID"
  log_info "Moon ID    : $MOON_ID"
  log_info "Exit node  : $ZT_ENABLE_EXIT_NODE"

  # 1) Instalasi — MANDATORY
  if ! install_zerotier; then
    log_error "ZeroTier GAGAL dipasang. Modul ini WAJIB (jaringan kontrol)."
    return 1
  fi

  # 2) Service online — MANDATORY
  if ! verify_zerotier_service; then
    log_error "Service ZeroTier tidak online. Modul ini WAJIB."
    return 1
  fi

  # 3) Join network — MANDATORY
  if ! join_network; then
    log_error "Gagal join ke jaringan kontrol $NETWORK_ID."
    return 1
  fi

  # 4) Authorization — MANDATORY bila ZT_REQUIRE_AUTHORIZATION=Ya
  if [ "$ZT_REQUIRE_AUTHORIZATION" = "Ya" ]; then
    if ! wait_authorization; then
      log_error "ZeroTier belum ter-authorize. Authorize node di controller, lalu"
      log_error "jalankan ulang: bash $BASE_DIR/speedtest-selfupdate.sh"
      return 1
    fi
  else
    log_warn "ZT_REQUIRE_AUTHORIZATION=Tidak → node boleh belum ter-authorize."
  fi

  # 5) Exit node (opsional via konfigurasi repo)
  if [ "$ZT_ENABLE_EXIT_NODE" = "Ya" ]; then
    enable_ip_forwarding || log_warn "IP forwarding belum aktif."
    setup_nat || log_warn "NAT belum terkonfigurasi (cek interface/tabel iptables)."
  else
    log_info "ZT_ENABLE_EXIT_NODE=Tidak → IP forwarding & NAT dilewati."
  fi

  # 6) Moon updater
  install_moon_updater
  run_moon_updater_now

  log_ok "Bagian 7 selesai — node terhubung ke jaringan kontrol ZeroTier."
  return 0
}

if [ "$MODE" = "-postboot" ]; then
  # Dipanggil cron @reboot: tegakkan kembali NAT/forwarding (rule iptables tidak
  # persist antar-reboot) tanpa mengulang instalasi.
  if [ "$ZT_ENABLE_EXIT_NODE" = "Ya" ]; then
    enable_ip_forwarding || true
    setup_nat || true
  fi
  exit 0
fi

if main; then
  exit 0
else
  exit 1
fi
