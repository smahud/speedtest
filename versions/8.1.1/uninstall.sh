#!/usr/bin/env bash
###############################################################################
# uninstall.sh — Cleanup Komprehensif Speedtest OoklaServer
#
# Mengembalikan sistem ke kondisi SEBELUM instalasi repo ini.
#
# Yang DIHAPUS:
#   - OoklaServer (binary, properties, service, cron, log)
#   - Sertifikat Let's Encrypt (domain dari data.ini)
#   - Kredensial Cloudflare
#   - Speedtest CLI (binary + paket)
#   - ZeroTier (binary, symlinks, service, scripts, moon-updater)
#   - File-file di BASE_DIR (kecuali data.ini)
#   - Cron jobs terkait
#   - IP forwarding & iptables NAT rules
#   - Firewall rules
#
# Yang DISISAKAN:
#   - data.ini — agar bisa install ulang tanpa isi ulang konfigurasi
#   - /var/lib/zerotier-one — agar Node ID tetap sama saat install ulang
#
# Penggunaan:
#   bash ./uninstall.sh                      # Auto-detect dari CWD
#   bash ./uninstall.sh /path/ke/data.ini    # Path eksplisit
#   bash ./uninstall.sh --force              # Skip semua konfirmasi
###############################################################################
set -euo pipefail

# ── COLOR & LOGGING ──────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_INFO='\033[0;36m'; C_OK='\033[0;32m'
  C_WARN='\033[0;33m'; C_ERR='\033[0;31m'
else
  C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''
fi

log_info()  { printf "${C_INFO}[INFO]${C_RESET} %s\n" "$1"; }
log_ok()    { printf "${C_OK}[OK]${C_RESET} %s\n" "$1"; }
log_warn()  { printf "${C_WARN}[WARN]${C_RESET} %s\n" "$1"; }
log_error() { printf "${C_ERR}[ERROR]${C_RESET} %s\n" "$1"; }
log_step()  { printf "\n${C_INFO}── %s ──${C_RESET}\n" "$1"; }

# ── ROOT CHECK ───────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  log_error "Script ini harus dijalankan sebagai root."
  exit 1
fi

# ── ARGUMENTS ────────────────────────────────────────────────────────────
FORCE=0
CONFIG_ARG=""

for arg in "$@"; do
  case "$arg" in
    --force|-f|--yes|-y) FORCE=1 ;;
    *) CONFIG_ARG="$arg" ;;
  esac
done

# ── DETECT BASE_DIR ──────────────────────────────────────────────────────
if [ -n "$CONFIG_ARG" ]; then
  [ -d "$CONFIG_ARG" ] && CONFIG_ARG="$CONFIG_ARG/data.ini"
  if [ -f "$CONFIG_ARG" ]; then
    BASE_DIR="$(cd "$(dirname "$CONFIG_ARG")" && pwd)"
    CONFIG_PATH="$BASE_DIR/data.ini"
  else
    log_error "data.ini tidak ditemukan: $CONFIG_ARG"
    exit 1
  fi
elif [ -f "$PWD/data.ini" ]; then
  BASE_DIR="$PWD"
  CONFIG_PATH="$BASE_DIR/data.ini"
elif [ -f "$(dirname "$0")/data.ini" ]; then
  BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
  CONFIG_PATH="$BASE_DIR/data.ini"
else
  log_error "data.ini tidak ditemukan."
  log_error "Gunakan: $0 /path/ke/data.ini"
  log_error "Atau jalankan dari folder yang berisi data.ini"
  exit 1
fi

# ── HELPERS ──────────────────────────────────────────────────────────────
safe_rm() {
  local target="$1"
  local desc="${2:-$1}"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if rm -rf "$target" 2>/dev/null; then
      log_ok "Dihapus: $desc"
    else
      log_warn "Gagal hapus: $target"
    fi
  fi
}

safe_rm_file() {
  local target="$1"
  local desc="${2:-$1}"
  if [ -f "$target" ] || [ -L "$target" ]; then
    if rm -f "$target" 2>/dev/null; then
      log_ok "Dihapus: $desc"
    else
      log_warn "Gagal hapus: $target"
    fi
  fi
}

confirm() {
  if [ "$FORCE" -eq 1 ]; then return 0; fi
  printf '\n%s%s%s\n' "$C_WARN" "$1" "$C_RESET"
  printf '%sLanjutkan? (y/N): %s' "$C_WARN" "$C_RESET"
  read -r answer
  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ── BANNER ────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  UNINSTALL COMPREHENSIVE — Speedtest OoklaServer"
echo "  Kembalikan sistem ke kondisi SEBELUM instalasi"
echo "============================================================"
echo ""
echo "  CONFIG_PATH : $CONFIG_PATH"
echo "  BASE_DIR    : $BASE_DIR"
echo ""
echo "  Yang akan DIHAPUS:"
echo "    • OoklaServer (binary, service, cron, properties)"
echo "    • Sertifikat Let's Encrypt"
echo "    • Kredensial Cloudflare"
echo "    • ZeroTier binary & service (identity DISIMPAN)"
echo "    • Speedtest CLI"
echo "    • File installer di BASE_DIR    (data.ini DISIMPAN)"
echo "    • Cron job MILIK INSTALLER INI saja (tag/path spesifik)"
echo "    • Rule iptables NAT spesifik ZeroTier + entri /etc/hosts terkelola"
echo "    • Konfigurasi SSH terkelola (kunci GitHub & drop-in sshd)"
echo ""
echo "  Yang DISISAKAN:"
echo "    • data.ini                      (konfigurasi)"
echo "    • /var/lib/zerotier-one         (Node ID ZeroTier)"
echo "    • Rule NAT milik layanan lain (Docker/libvirt/K8s TIDAK disentuh)"
echo "    • IP forwarding sistem (tidak dimatikan paksa)"
echo "============================================================"
echo ""

if ! confirm "ANDA YAKIN INGIN MELANJUTKAN?"; then
  log_info "Dibatalkan oleh user."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: STOP ALL RUNNING PROCESSES
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 1: Menghentikan semua proses yang berjalan"

# OoklaServer
if pgrep -x OoklaServer >/dev/null 2>&1; then
  log_info "Menghentikan OoklaServer..."
  pkill -x OoklaServer 2>/dev/null || true
  sleep 2
  if pgrep -x OoklaServer >/dev/null 2>&1; then
    pkill -9 -x OoklaServer 2>/dev/null || true
  fi
  log_ok "OoklaServer dihentikan."
else
  log_info "OoklaServer tidak berjalan."
fi

# ZeroTier — hanya stop proses, JANGAN hapus /var/lib/zerotier-one
if pgrep -x zerotier-one >/dev/null 2>&1; then
  log_info "Menghentikan ZeroTier..."
  pkill -x zerotier-one 2>/dev/null || true
  sleep 2
  if pgrep -x zerotier-one >/dev/null 2>&1; then
    pkill -9 -x zerotier-one 2>/dev/null || true
    sleep 1
  fi
  log_ok "ZeroTier dihentikan."
else
  log_info "ZeroTier tidak berjalan."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: REMOVE SYSTEMD / OPENRC SERVICES
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 2: Menghapus service systemd/openrc"

if command -v systemctl >/dev/null 2>&1; then
  for svc in ooklaserver zerotier-one zt-exitnode; do
    if systemctl is-enabled "$svc.service" >/dev/null 2>&1 2>/dev/null; then
      systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
      log_ok "Service $svc dinonaktifkan."
    fi
  done
  safe_rm_file "/etc/systemd/system/ooklaserver.service" "ooklaserver.service"
  safe_rm_file "/etc/systemd/system/zt-exitnode.service" "zt-exitnode.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

if command -v rc-service >/dev/null 2>&1; then
  for svc in ooklaserver zerotier-one; do
    if [ -f "/etc/init.d/$svc" ]; then
      rc-service "$svc" stop 2>/dev/null || true
      if command -v rc-update >/dev/null 2>&1; then
        rc-update del "$svc" default 2>/dev/null || true
      fi
      safe_rm_file "/etc/init.d/$svc" "OpenRC init: $svc"
      log_ok "OpenRC service $svc dihapus."
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: CLEAN ALL CRON JOBS
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 3: Membersihkan semua cron jobs"

if command -v crontab >/dev/null 2>&1; then
  TMP_CRON="$(mktemp)"
  # HANYA buang baris yang jelas milik installer ini:
  #   - tag penanda unik di repo ini
  #   - pemanggilan script dengan path di BASE_DIR
  #   - wrapper cron yang kita buat di BASE_DIR
  # Sengaja TIDAK memakai pola lebar seperti 'OoklaServer'/'ooklaserver' karena
  # bisa menghapus cron job lain milik pengguna.
  # CATATAN: redirect harus berada DI BARIS TERAKHIR pipeline. Bila ditaruh
  # sebagai baris sendiri setelah tanda '|', shell memperlakukannya sebagai
  # perintah kosong → file hasil menjadi KOSONG → crontab pengguna terhapus!
  crontab -l 2>/dev/null \
    | grep -vF '# speedtest-report (managed)' \
    | grep -vF '# ookla-daily-restart' \
    | grep -vF '# speedtest-autoupdate (managed)' \
    | grep -vF '# speedtest-boot-sync (managed)' \
    | grep -vF '# speedtest-zt-nat-restore (managed)' \
    | grep -vF '# speedtest-boot-fallback (managed)' \
    | grep -vF '/usr/local/bin/zt-exitnode.sh' \
    | grep -vF '# speedtest-cert-renew (managed)' \
    | grep -vF '# speedtest-cert-check (managed)' \
    | grep -vF '# zt-moon-updater (managed)' \
    | grep -vF "$BASE_DIR/cron-speedtest.sh" \
    | grep -vF "$BASE_DIR/cron-speedtest5.sh" \
    | grep -vF "$BASE_DIR/ooklaserver.sh" \
    | grep -vF "$BASE_DIR/speedtest-selfupdate.sh" \
    | grep -vF "$BASE_DIR/bagian10_hosts_ssh.sh" \
    | grep -vF "$BASE_DIR/bagian7_network.sh" \
    | grep -vF "$BASE_DIR/speedtestctl.sh" \
    | grep -vF "$BASE_DIR/certbot-renew.sh" \
    | grep -vF "$BASE_DIR/cert-check.sh" \
    | grep -vF "/usr/local/bin/zt-moon-updater.sh" \
    > "$TMP_CRON" 2>/dev/null || true

  # Pengaman: bila crontab asli BERISI tetapi hasil filter KOSONG, beri tahu
  # jelas (indikasi filter bermasalah atau memang semua isinya milik installer).
  CRON_BEFORE_COUNT="$(crontab -l 2>/dev/null | grep -c '[^[:space:]]' || true)"
  CRON_AFTER_COUNT="$(grep -c '[^[:space:]]' "$TMP_CRON" 2>/dev/null || true)"
  if [ "${CRON_BEFORE_COUNT:-0}" -gt 0 ] && [ "${CRON_AFTER_COUNT:-0}" -eq 0 ]; then
    log_warn "Seluruh isi crontab termasuk milik installer ini (atau filter tidak menemukan sisa)."
    log_warn "Crontab akan menjadi kosong — backup disimpan di ${TMP_CRON}.bak"
    cp -f "$TMP_CRON" "${TMP_CRON}.bak" 2>/dev/null || true
  fi
  crontab "$TMP_CRON" 2>/dev/null || true
  rm -f "$TMP_CRON"
  log_ok "Cron jobs (milik installer ini) dibersihkan."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: REMOVE ZEROTIER (binary only — KEEP identity di /var/lib/zerotier-one)
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 4: Menghapus ZeroTier binary (identity DISIMPAN)"

# Hapus binary & symlinks saja
safe_rm_file "/usr/sbin/zerotier-one"  "ZeroTier binary"
safe_rm_file "/usr/sbin/zerotier-cli"   "ZeroTier CLI symlink"
safe_rm_file "/usr/sbin/zerotier-idtool" "ZeroTier ID tool symlink"

# Hapus script & log
safe_rm_file "/usr/local/bin/zt-exitnode.sh"    "ZT exit node script"
safe_rm_file "/usr/local/bin/zt-moon-updater.sh" "ZT moon updater script"
safe_rm_file "/var/log/zt-moon-updater.log"      "ZT moon updater log"
safe_rm_file "/var/log/zt-moon-updater.log.1"    "ZT moon updater log (rotasi)"

# Hapus paket (best effort) — status dilaporkan SETELAH diverifikasi, bukan
# sekedar "perintahnya dijalankan" (biar tidak ada klaim palsu di log).
pkg_zt_gone() {
  # return 0 = paket SUDAH tidak ada; return 1 = masih ada / tidak bisa dipastikan
  if command -v dpkg >/dev/null 2>&1; then
    if dpkg -s zerotier-one >/dev/null 2>&1; then return 1; fi
  elif command -v rpm >/dev/null 2>&1; then
    if rpm -q zerotier-one >/dev/null 2>&1; then return 1; fi
  elif command -v apk >/dev/null 2>&1; then
    if apk info -e zerotier-one >/dev/null 2>&1; then return 1; fi
  else
    return 1   # tidak ada package manager yang dikenal → jangan klaim "sudah bersih"
  fi
  return 0
}
if command -v dpkg >/dev/null 2>&1 && dpkg -s zerotier-one >/dev/null 2>&1; then
  apt-get remove -y zerotier-one >/dev/null 2>&1 || true
elif command -v rpm >/dev/null 2>&1 && rpm -q zerotier-one >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf remove -y zerotier-one >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum remove -y zerotier-one >/dev/null 2>&1 || true
  fi
elif command -v apk >/dev/null 2>&1 && apk info -e zerotier-one >/dev/null 2>&1; then
  apk del zerotier-one >/dev/null 2>&1 || true
fi
if pkg_zt_gone; then
  log_info "Paket zerotier-one tidak terpasang lagi (atau memang tidak pernah dipasang)."
else
  log_warn "Paket zerotier-one masih terdaftar di package manager — hapus manual bila perlu."
fi

# VERIFIKASI: pastikan identity tetap ada
if [ -d /var/lib/zerotier-one ]; then
  ZT_ID_COUNT=0
  for _idf in /var/lib/zerotier-one/identity.*; do
    [ -e "$_idf" ] && ZT_ID_COUNT=$((ZT_ID_COUNT + 1))
  done
  log_ok "/var/lib/zerotier-one DISIMPAN ($ZT_ID_COUNT file identity) — Node ID TETAP."
else
  log_warn "/var/lib/zerotier-one tidak ditemukan (mungkin belum pernah diinstal)."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: REMOVE SPEEDTEST CLI
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 5: Menghapus Speedtest CLI (Ookla)"

# HANYA CLI Ookla yang dihapus. 'speedtest-cli' (Python/sivel) atau biner lain
# milik operator TIDAK disentuh — versi lama menghapus /usr/bin/speedtest dan
# 'apk del speedtest-cli' secara membabi buta.
is_ookla_cli() {
  [ -x "$1" ] || return 1
  "$1" --version 2>/dev/null | grep -qi 'ookla'
}

for _cli in /usr/local/bin/speedtest /usr/bin/speedtest; do
  if [ -e "$_cli" ] || [ -L "$_cli" ]; then
    if is_ookla_cli "$_cli"; then
      safe_rm_file "$_cli" "Speedtest CLI Ookla ($_cli)"
    else
      log_info "Dilewati (bukan CLI Ookla, milik operator): $_cli"
    fi
  fi
done

# Konfigurasi/lisensi CLI Ookla (dibuat otomatis saat uji pertama)
for _h in "/root" "${HOME:-/root}"; do
  [ -n "$_h" ] || continue
  safe_rm "$_h/.config/ookla" "Konfigurasi CLI Ookla ($_h)"
done

# Paket Ookla (hanya bila memang terpasang sebagai paket distro)
if command -v dpkg >/dev/null 2>&1 && dpkg -l speedtest 2>/dev/null | grep -q '^ii'; then
  apt-get remove -y speedtest 2>/dev/null && log_ok "Paket speedtest dihapus (apt)." || true
elif command -v rpm >/dev/null 2>&1 && rpm -q speedtest >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf remove -y speedtest 2>/dev/null && log_ok "Paket speedtest dihapus (dnf)." || true
  elif command -v yum >/dev/null 2>&1; then
    yum remove -y speedtest 2>/dev/null && log_ok "Paket speedtest dihapus (yum)." || true
  fi
else
  log_info "Tidak ada paket 'speedtest' yang terpasang — tidak ada paket yang dihapus."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: REMOVE SSL CERTIFICATES & CLOUDFLARE CREDENTIALS
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 6: Menghapus sertifikat SSL & kredensial Cloudflare"

safe_rm_file "/etc/letsencrypt/dnscloudflare.ini" "Cloudflare credentials"

if [ -f "$CONFIG_PATH" ]; then
  DOMAIN=$(grep -E '^[[:space:]]*Domain[[:space:]]*=' "$CONFIG_PATH" 2>/dev/null | tail -1 | \
    sed 's/.*=[[:space:]]*//' | tr -d \"\' | xargs)
  if [ -n "$DOMAIN" ] && [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    if confirm "Hapus sertifikat Let's Encrypt untuk domain '$DOMAIN'?"; then
      if command -v certbot >/dev/null 2>&1; then
        certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
      fi
      safe_rm "/etc/letsencrypt/live/$DOMAIN"     "Sertifikat live: $DOMAIN"
      safe_rm "/etc/letsencrypt/archive/$DOMAIN"  "Sertifikat archive: $DOMAIN"
      safe_rm_file "/etc/letsencrypt/renewal/$DOMAIN.conf" "Sertifikat renewal: $DOMAIN"
      log_ok "Sertifikat $DOMAIN dihapus."
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 7: REMOVE IP FORWARDING & IPTABLES NAT
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 7: Membersihkan IP forwarding & iptables NAT"

safe_rm_file "/etc/sysctl.d/99-ipforward.conf" "IP forwarding config"

# PENTING: dulu script ini menjalankan `iptables -t nat -F POSTROUTING`,
# `iptables -F FORWARD`, dan `sysctl -w net.ipv4.ip_forward=0` — ketiganya
# GLOBAL dan bisa merusak jaringan Docker/libvirt/K8s/router di host yang sama.
# Sekarang hanya rule milik kita (spesifik interface) yang dihapus.
# iptables/ip diambil via PATH bila ada, jika tidak pakai path absolut
# (/usr/sbin tidak ada di PATH minimal cron/systemd-timer).
IPT_BIN="$(command -v iptables 2>/dev/null || true)"
[ -n "$IPT_BIN" ] || { [ -x /usr/sbin/iptables ] && IPT_BIN="/usr/sbin/iptables"; }
IP_BIN_LOCAL="$(command -v ip 2>/dev/null || true)"
[ -n "$IP_BIN_LOCAL" ] || { [ -x /usr/sbin/ip ] && IP_BIN_LOCAL="/usr/sbin/ip"; }

# Hapus MAKSIMAL $2 rule yang cocok (default 5).
# Versi lama memakai 'while iptables -C ...; do iptables -D ...; done' TANPA
# batas: bila -C menjawab "ada" tetapi -D tidak benar-benar menghapus (wrapper
# iptables, backend nft, atau rule yang dilindungi), loop berputar SELAMANYA
# dan uninstall menggantung. Sekarang dibatasi + setiap langkah diverifikasi.
ipt_del_max() {
  # shellcheck disable=SC2086  # $spec SENGAJA dipecah menjadi argumen (-t nat POSTROUTING …)
  local spec="$1" max="${2:-5}" i=0
  while [ "$i" -lt "$max" ]; do
    # shellcheck disable=SC2086
    "$IPT_BIN" -C $spec 2>/dev/null || break
    # shellcheck disable=SC2086
    "$IPT_BIN" -D $spec 2>/dev/null || break
    i=$((i + 1))
  done
  return 0
}

if [ -n "$IPT_BIN" ]; then
  log_info "Menghapus rule NAT spesifik ZeroTier (bila ada)..."
  ZT_IF=""; PUB_IF=""; ZT_SUBNET=""
  if [ -n "$IP_BIN_LOCAL" ]; then
    ZT_IF="$("$IP_BIN_LOCAL" -o link show 2>/dev/null | grep -o 'zt[a-z0-9]*' | head -n 1)"
    PUB_IF="$("$IP_BIN_LOCAL" route 2>/dev/null | grep default | awk '{print $5}' | head -n 1)"
    if [ -n "$ZT_IF" ]; then
      ZT_SUBNET="$("$IP_BIN_LOCAL" -4 -o addr show dev "$ZT_IF" 2>/dev/null | awk '{print $4}' | head -n 1)"
    fi
  fi
  if [ -n "$ZT_IF" ] && [ -n "$PUB_IF" ]; then
    NAT_RULES_DELETED=0

    # 1) Rule milik kita (v8.1.1+): masquerade DIBATASI ke subnet ZeroTier.
    if [ -n "$ZT_SUBNET" ] && "$IPT_BIN" -t nat -C POSTROUTING -s "$ZT_SUBNET" -o "$PUB_IF" -j MASQUERADE 2>/dev/null; then
      ipt_del_max "-t nat POSTROUTING -s $ZT_SUBNET -o $PUB_IF -j MASQUERADE" 5
      log_ok "Rule masquerade ZeroTier ($ZT_SUBNET → $PUB_IF) dihapus."
      NAT_RULES_DELETED=1
    fi

    # 2) Rule FORWARD (spesifik interface ZeroTier → jelas milik kita).
    if "$IPT_BIN" -C FORWARD -i "$ZT_IF" -o "$PUB_IF" -j ACCEPT 2>/dev/null; then
      ipt_del_max "FORWARD -i $ZT_IF -o $PUB_IF -j ACCEPT" 5
      NAT_RULES_DELETED=1
    fi
    if "$IPT_BIN" -C FORWARD -i "$PUB_IF" -o "$ZT_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
      ipt_del_max "FORWARD -i $PUB_IF -o $ZT_IF -m state --state RELATED,ESTABLISHED -j ACCEPT" 5
      NAT_RULES_DELETED=1
    fi

    # 3) Kompatibilitas versi lama (rule masquerade GENERIK '# -o $PUB_IF'):
    #    hanya bila tidak ada rule ter-scope di atas. Maksimal SATU rule dihapus
    #    — rule generik tidak bisa dipastikan milik kita (bisa milik
    #    Docker/OpenVPN/libvirt di host yang sama), jadi operator diberi tahu.
    if [ "$NAT_RULES_DELETED" -eq 0 ] && "$IPT_BIN" -t nat -C POSTROUTING -o "$PUB_IF" -j MASQUERADE 2>/dev/null; then
      ipt_del_max "-t nat POSTROUTING -o $PUB_IF -j MASQUERADE" 1
      log_warn "Rule masquerade GENERIK untuk $PUB_IF ditemukan (peninggalan versi lama):"
      log_warn "  satu rule dihapus. Bila host ini memakai NAT sendiri untuk $PUB_IF,"
      log_warn "  periksa ulang: iptables -t nat -L POSTROUTING -n -v"
      NAT_RULES_DELETED=1
    fi

    if [ "$NAT_RULES_DELETED" -eq 1 ]; then
      log_ok "Rule NAT ZeroTier dibersihkan (rule lain tidak disentuh)."
    else
      log_info "Tidak ada rule NAT ZeroTier yang perlu dihapus."
    fi
  else
    log_warn "Interface ZeroTier tidak ditemukan — rule NAT dibiarkan (hapus manual bila perlu)."
  fi
  log_info "Sisa rule FORWARD/POSTROUTING milik layanan lain TIDAK diubah."
else
  log_info "iptables tidak tersedia — dilewati."
fi

# IP forwarding TIDAK dimatikan paksa: host mungkin memakainya untuk Docker/VM/VPN.
log_info "IP forwarding dibiarkan aktif bila dimatikan bisa mengganggu layanan lain."
log_info "Jika ingin mematikan: sysctl -w net.ipv4.ip_forward=0 (setelah cek layanan lain)."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 8: CLEAN BASE_DIR (keep ONLY data.ini)
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 7b: Mengembalikan /etc/hosts & konfigurasi SSH yang dikelola"

# Nilai default (sama dengan speedtest-repo.conf)
UF_HOSTS_FILE="/etc/hosts"
UF_HOSTS_MARKER="speedtest-managed"
UF_SSH_MARKER="speedtest-managed-keys"
UF_SSH_USERS="root"

# Parser nilai: buang komentar inline (# didahului spasi), trim spasi, lepas kutip.
uf_parse_value() {
  local v="$1"
  v="$(printf '%s' "$v" | sed 's/[[:blank:]]\+#.*$//')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "$v"
}

# Baca konfigurasi repo (file ada sebelum Step 8 menghapusnya)
REPO_CONF="$BASE_DIR/speedtest-repo.conf"
if [ -f "$REPO_CONF" ]; then
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"
    case "$key" in *[!A-Za-z0-9_]*) continue ;; esac
    val="$(uf_parse_value "${line#*=}")"
    case "$key" in
      HOSTS_FILE) UF_HOSTS_FILE="$val" ;;
      HOSTS_MARKER) UF_HOSTS_MARKER="$val" ;;
      SSH_MARKER) UF_SSH_MARKER="$val" ;;
      SSH_TARGET_USERS) UF_SSH_USERS="$val" ;;
    esac
  done < "$REPO_CONF"
fi

# ── /etc/hosts ──
if [ -f "$UF_HOSTS_FILE" ] && grep -qF "# $UF_HOSTS_MARKER" "$UF_HOSTS_FILE" 2>/dev/null; then
  cp -p "$UF_HOSTS_FILE" "${UF_HOSTS_FILE}.uninstall.bak" 2>/dev/null || true
  grep -vF "# $UF_HOSTS_MARKER" "$UF_HOSTS_FILE" > "${UF_HOSTS_FILE}.tmp.uninstall" 2>/dev/null || true
  if [ -s "${UF_HOSTS_FILE}.tmp.uninstall" ]; then
    # mv gagal bila file hosts adalah mount point → fallback tulis in-place.
    if ! mv -f "${UF_HOSTS_FILE}.tmp.uninstall" "$UF_HOSTS_FILE" 2>/dev/null; then
      cat "${UF_HOSTS_FILE}.tmp.uninstall" > "$UF_HOSTS_FILE" 2>/dev/null || true
      rm -f "${UF_HOSTS_FILE}.tmp.uninstall" 2>/dev/null || true
    fi
    log_ok "Entri $UF_HOSTS_MARKER dihapus dari $UF_HOSTS_FILE (backup: ${UF_HOSTS_FILE}.uninstall.bak)"
  else
    rm -f "${UF_HOSTS_FILE}.tmp.uninstall"
    log_warn "Tidak menghapus entri hosts untuk keamanan (hasil kosong)."
  fi
else
  log_info "Tidak ada entri hosts yang dikelola ($UF_HOSTS_FILE)."
fi

# ── Kunci SSH yang dikelola (blok penanda) ──
for u in $UF_SSH_USERS root; do
  # Portabel: getent tidak selalu ada (mis. Alpine minimal) → fallback /etc/passwd.
  home_dir=""
  command -v getent >/dev/null 2>&1 && home_dir="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  [ -n "$home_dir" ] || home_dir="$(awk -F: -v u="$u" '$1 == u { print $6; exit }' /etc/passwd 2>/dev/null)"
  [ -n "$home_dir" ] || { [ "$u" = "root" ] && home_dir="/root"; }
  [ -n "$home_dir" ] || continue
  for _junk in "$home_dir"/.ssh/authorized_keys.speedtesttmp.* "$home_dir"/.ssh/authorized_keys.p10tmp; do
    [ -e "$_junk" ] && rm -f "$_junk" 2>/dev/null || true
  done
  ak="$home_dir/.ssh/authorized_keys"
  [ -f "$ak" ] || continue
  grep -qF "# BEGIN $UF_SSH_MARKER" "$ak" 2>/dev/null || continue
  if confirm "Hapus kunci publik yang dikelola installer dari $ak (user '$u')?"; then
    tmp_ak="${ak}.uninstall.tmp"
    if awk -v begin="# BEGIN $UF_SSH_MARKER" -v end="# END $UF_SSH_MARKER" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip { print }
      ' "$ak" > "$tmp_ak" 2>/dev/null; then
      mv -f "$tmp_ak" "$ak"
      chmod 600 "$ak" 2>/dev/null || true
      log_ok "Blok kunci installer dihapus dari $ak."
    else
      rm -f "$tmp_ak"
      log_warn "Gagal memproses $ak — dibiarkan apa adanya."
    fi
  fi
done

# ── Drop-in sshd ──
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-speedtest-managed.conf"
if [ -f "$SSHD_DROPIN" ]; then
  if confirm "Hapus konfigurasi sshd yang dikelola installer ($SSHD_DROPIN)?"; then
    SSHD_BIN=""
    if command -v sshd >/dev/null 2>&1; then SSHD_BIN="$(command -v sshd)"
    elif [ -x /usr/sbin/sshd ]; then SSHD_BIN="/usr/sbin/sshd"; fi
    cp -p "$SSHD_DROPIN" "/tmp/99-speedtest-managed.conf.bak" 2>/dev/null || true
    rm -f "$SSHD_DROPIN"
    if [ -n "$SSHD_BIN" ] && ! "$SSHD_BIN" -t >/dev/null 2>&1; then
      cp -p "/tmp/99-speedtest-managed.conf.bak" "$SSHD_DROPIN" 2>/dev/null || true
      log_warn "Konfigurasi sshd jadi tidak valid tanpa file ini — file dipulihkan."
    else
      if command -v systemctl >/dev/null 2>&1; then
        systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 || true
      elif command -v rc-service >/dev/null 2>&1; then
        rc-service sshd reload >/dev/null 2>&1 || true
      fi
      log_ok "Drop-in sshd dihapus (backup: /tmp/99-speedtest-managed.conf.bak)."
    fi
  fi
else
  log_info "Tidak ada drop-in sshd yang dikelola."
fi

log_step "Step 8: Membersihkan BASE_DIR ($BASE_DIR)"

DATA_INI_BACKUP="$(mktemp)"
cp "$CONFIG_PATH" "$DATA_INI_BACKUP"

# HANYA file yang benar-benar dikelola installer ini (dulu: SEMUA *.sh di
# BASE_DIR dihapus — berbahaya bila BASE_DIR = /root atau /opt).
MANAGED_FILES="
install.sh
common_functions1.sh
auto_update_lib.sh
speedtest-repo.conf
speedtest-selfupdate.sh
VERSION
MANIFEST
checksums.sha256
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
uninstall.sh
speedtestctl.sh
certbot-renew.sh
cert-check.sh
ooklaserver.sh
cron-speedtest.sh
cron-speedtest5.sh
OoklaServer
OoklaServer.properties
OoklaServer.properties.default
OoklaServer.pid
.speedtest-install.state
install.log
update.log
update.log.1
report.log
report.log.1
"
for f in $MANAGED_FILES; do
  safe_rm_file "$BASE_DIR/$f" "$f"
done

# Direktori kerja installer
safe_rm "$BASE_DIR/tmp"            "tmp directory"
safe_rm "$BASE_DIR/.bootstrap-staging" "staging bootstrap"
safe_rm "$BASE_DIR/.backups"       "backup versi lama"
safe_rm "$BASE_DIR/.update-staging" "staging update"
safe_rm "$BASE_DIR/.update.lock"   "lock update"
safe_rm "$BASE_DIR/.ssh-backups"   "backup konfigurasi SSH"

# Sisa archive & file temporer (termasuk *.speedtesttmp.* dari operasi kunci/sshd)
for leftover in "$BASE_DIR"/*.tgz "$BASE_DIR"/*.tar.gz "$BASE_DIR"/OoklaServer-* \
                "$BASE_DIR"/*.tmp.* "$BASE_DIR"/*.speedtesttmp.* "$BASE_DIR"/*.uninstall.tmp \
                "$BASE_DIR"/.version-probe.* "$BASE_DIR"/.version-pin-probe.*; do
  if [ -f "$leftover" ]; then
    safe_rm_file "$leftover" "$(basename "$leftover")"
  fi
done

# Restore data.ini
cp "$DATA_INI_BACKUP" "$CONFIG_PATH"
rm -f "$DATA_INI_BACKUP"
log_ok "data.ini disimpan di $CONFIG_PATH"
log_ok "BASE_DIR dibersihkan."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 9: CERTBOT (OPTIONAL)
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 9: Certbot (opsional)"

if command -v certbot >/dev/null 2>&1; then
  if confirm "Hapus juga certbot? (HANYA jika tidak dipakai aplikasi lain)"; then
    if command -v apk >/dev/null 2>&1; then
      apk del certbot certbot-dns-cloudflare py3-certbot-dns-cloudflare 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get remove -y certbot python3-certbot-dns-cloudflare 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf remove -y certbot python3-certbot-dns-cloudflare 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
      yum remove -y certbot python3-certbot-dns-cloudflare 2>/dev/null || true
    fi
    if command -v snap >/dev/null 2>&1; then
      snap remove certbot 2>/dev/null || true
      snap remove certbot-dns-cloudflare 2>/dev/null || true
    fi
    log_ok "Certbot dihapus."
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "============================================================"
echo "  UNINSTALL SELESAI — Sistem kembali ke kondisi awal"
echo "============================================================"
echo ""
echo "  ✗ Dihapus:"
echo "    ✗ OoklaServer     (binary, service, cron, properties)"
echo "    ✗ ZeroTier        (binary, service, scripts, moon)"
echo "    ✗ Speedtest CLI   (binary, package)"
echo "    ✗ SSL Certificates + Cloudflare credentials"
echo "    ✗ Rule NAT ZeroTier + entri /etc/hosts terkelola"
echo "    ✗ Konfigurasi SSH terkelola (kunci + drop-in sshd)"
echo "    ✗ File installer di BASE_DIR"
echo "    ✗ Cron job milik installer ini"
echo ""
echo "  ✓ Disisakan:"
echo "    ✓ $CONFIG_PATH"
echo "    ✓ /var/lib/zerotier-one  (Node ID TETAP, tidak berubah)"
echo ""
echo "  Isi BASE_DIR sekarang:"
ls -la "$BASE_DIR/" 2>/dev/null || echo "    (direktori kosong)"
echo ""
echo "  Isi /var/lib/zerotier-one:"
if [ -d /var/lib/zerotier-one ]; then
  ls -la /var/lib/zerotier-one/ 2>/dev/null
else
  echo "    (direktori tidak ditemukan — belum pernah install ZeroTier)"
fi
echo ""
echo "============================================================"
echo "  Untuk install ulang:"
echo "    wget -O install.sh bit.ly/ooklaserverlinux"
echo "    bash ./install.sh"
echo ""
echo "  ZeroTier akan menggunakan Node ID yang SAMA."
echo "============================================================"
