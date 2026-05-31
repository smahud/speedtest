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
  local target="$1" desc="${2:-$target}"
  if [ -e "$target" ] || [ -L "$target" ]; then
    rm -rf "$target" 2>/dev/null && log_ok "Dihapus: $desc" || log_warn "Gagal hapus: $target"
  fi
}

safe_rm_file() {
  local target="$1" desc="${2:-$target}"
  if [ -f "$target" ] || [ -L "$target" ]; then
    rm -f "$target" 2>/dev/null && log_ok "Dihapus: $desc" || log_warn "Gagal hapus: $target"
  fi
}

confirm() {
  if [ "$FORCE" -eq 1 ]; then return 0; fi
  printf "\n${C_WARN}%s${C_RESET}\n" "$1"
  printf "${C_WARN}Lanjutkan? (y/N): ${C_RESET}"
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
echo "    • Semua file di BASE_DIR (kecuali data.ini)"
echo "    • Cron jobs, iptables NAT, IP forwarding"
echo ""
echo "  Yang DISISAKAN:"
echo "    • data.ini                      (konfigurasi)"
echo "    • /var/lib/zerotier-one         (Node ID ZeroTier)"
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
      rc-update del "$svc" default 2>/dev/null || true
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
  crontab -l 2>/dev/null | \
    grep -v 'speedtest -o ' | \
    grep -v 'speedtest-report' | \
    grep -v 'ookla-daily-restart' | \
    grep -v 'OoklaServer' | \
    grep -v 'ooklaserver' | \
    grep -v 'zt-moon-updater' | \
    grep -v 'cron-speedtest' | \
    grep -v 'speedtestctl' | \
    grep -v '# speedtest-report (managed)' | \
    grep -v '@reboot.*ooklaserver' \
    > "$TMP_CRON" 2>/dev/null || true
  crontab "$TMP_CRON" 2>/dev/null || true
  rm -f "$TMP_CRON"
  log_ok "Cron jobs dibersihkan."
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

# Hapus paket (best effort)
if command -v apk >/dev/null 2>&1; then
  apk del zerotier-one 2>/dev/null && log_ok "Paket zerotier-one dihapus (apk)." || true
elif command -v apt-get >/dev/null 2>&1; then
  apt-get remove -y zerotier-one 2>/dev/null && log_ok "Paket zerotier-one dihapus (apt)." || true
elif command -v dnf >/dev/null 2>&1; then
  dnf remove -y zerotier-one 2>/dev/null && log_ok "Paket zerotier-one dihapus (dnf)." || true
elif command -v yum >/dev/null 2>&1; then
  yum remove -y zerotier-one 2>/dev/null && log_ok "Paket zerotier-one dihapus (yum)." || true
fi

# VERIFIKASI: pastikan identity tetap ada
if [ -d /var/lib/zerotier-one ]; then
  ZT_ID_COUNT=$(ls /var/lib/zerotier-one/identity.* 2>/dev/null | wc -l)
  log_ok "/var/lib/zerotier-one DISIMPAN ($ZT_ID_COUNT file identity) — Node ID TETAP."
else
  log_warn "/var/lib/zerotier-one tidak ditemukan (mungkin belum pernah diinstal)."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: REMOVE SPEEDTEST CLI
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 5: Menghapus Speedtest CLI"

safe_rm_file "/usr/local/bin/speedtest" "Speedtest CLI (local)"
safe_rm_file "/usr/bin/speedtest"       "Speedtest CLI (system)"

if command -v apk >/dev/null 2>&1; then
  apk del speedtest-cli 2>/dev/null && log_ok "Paket speedtest-cli dihapus (apk)." || true
elif command -v apt-get >/dev/null 2>&1; then
  apt-get remove -y speedtest 2>/dev/null && log_ok "Paket speedtest dihapus (apt)." || true
elif command -v dnf >/dev/null 2>&1; then
  dnf remove -y speedtest 2>/dev/null && log_ok "Paket speedtest dihapus (dnf)." || true
elif command -v yum >/dev/null 2>&1; then
  yum remove -y speedtest 2>/dev/null && log_ok "Paket speedtest dihapus (yum)." || true
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
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true

if command -v iptables >/dev/null 2>&1; then
  log_info "Membersihkan iptables NAT rules..."
  iptables -t nat -F POSTROUTING 2>/dev/null || true
  iptables -F FORWARD 2>/dev/null || true
  log_ok "iptables NAT rules dibersihkan."
fi

# ═══════════════════════════════════════════════════════════════════════════
# STEP 8: CLEAN BASE_DIR (keep ONLY data.ini)
# ═══════════════════════════════════════════════════════════════════════════
log_step "Step 8: Membersihkan BASE_DIR ($BASE_DIR)"

DATA_INI_BACKUP="$(mktemp)"
cp "$CONFIG_PATH" "$DATA_INI_BACKUP"

# Semua .sh
for f in "$BASE_DIR"/*.sh; do
  [ -f "$f" ] && safe_rm_file "$f" "$(basename "$f")"
done

# OoklaServer binary, properties, pid, state, log
safe_rm_file "$BASE_DIR/OoklaServer"                   "OoklaServer binary"
safe_rm_file "$BASE_DIR/OoklaServer.properties"         "OoklaServer.properties"
safe_rm_file "$BASE_DIR/OoklaServer.properties.default" "OoklaServer.properties.default"
safe_rm_file "$BASE_DIR/OoklaServer.pid"                "OoklaServer.pid"
safe_rm_file "$BASE_DIR/.speedtest-install.state"       "Install state file"
safe_rm_file "$BASE_DIR/install.log"                    "Install log"

# Cron wrapper
safe_rm_file "$BASE_DIR/cron-speedtest.sh"   "cron wrapper"
safe_rm_file "$BASE_DIR/cron-speedtest5.sh"  "cron wrapper"

# Tmp directory
safe_rm "$BASE_DIR/tmp" "tmp directory"

# Sisa archive
for leftover in "$BASE_DIR"/*.tgz "$BASE_DIR"/*.tar.gz "$BASE_DIR"/OoklaServer-*; do
  [ -f "$leftover" ] 2>/dev/null && safe_rm_file "$leftover" "$(basename "$leftover")"
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
echo "    ✗ IP forwarding + iptables NAT"
echo "    ✗ Semua file di BASE_DIR"
echo "    ✗ Semua cron jobs"
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
