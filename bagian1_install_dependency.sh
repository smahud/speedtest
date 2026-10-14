#!/usr/bin/env bash
###############################################################################
# bagian1_install_dependency.sh
#   - Memasang Speedtest CLI RESMI Ookla (bukan speedtest-cli Python distro!)
#   - Menyiapkan kredensial Cloudflare (jika diperlukan)
#   - Idempotent: lewati bila sudah benar-benar terpasang.
#
# CATATAN PENTING (bug lama): pada Alpine, paket 'speedtest-cli' adalah klien
# PYTHON (sivel/speedtest-cli) yang TIDAK punya opsi '-o/--host' sehingga cron
# reporting di bagian6 selalu gagal. Sekarang: CLI Ookla dipasang dari biner
# resmi ke /usr/local/bin (menang dari /usr/bin) dan diverifikasi lewat
# 'speedtest --version' yang harus memuat kata "Ookla".
###############################################################################
set -uo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
  resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 1: Speedtest CLI & kredensial Cloudflare =="

OOKLA_CLI_VERSION="1.2.0"
OOKLA_CLI_DIR="/usr/local/bin"

# ── Apakah 'speedtest' yang ada benar-benar CLI resmi Ookla? ──────────────────
speedtest_is_ookla() {
  command_exists speedtest || return 1
  speedtest --version 2>/dev/null | grep -qi 'ookla'
}

arch_slug() {
  case "$(uname -m)" in
    x86_64) printf 'x86_64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    armv7l|armhf) printf 'armhf' ;;
    i386|i686) printf 'i386' ;;
    *) return 1 ;;
  esac
}

# ── Pasang biner resmi Ookla ke /usr/local/bin (prioritas PATH) ───────────────
install_ookla_binary() {
  local arch url tgz
  arch="$(arch_slug)" || { log_error "Arsitektur tidak didukung: $(uname -m)"; return 1; }
  url="https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_CLI_VERSION}-linux-${arch}.tgz"
  tgz="$TMP_DIR/speedtest-cli.tgz"

  mkdir -p "$TMP_DIR" "$OOKLA_CLI_DIR" 2>/dev/null || true
  log_info "Mengunduh Speedtest CLI resmi Ookla ($arch)..."
  if command_exists curl; then
    curl -fsSL --max-time 120 -o "$tgz" "$url" || return 1
  elif command_exists wget; then
    wget -q -T 120 -O "$tgz" "$url" || return 1
  else
    log_error "curl/wget tidak tersedia untuk mengunduh Speedtest CLI."
    return 1
  fi

  tar -xzf "$tgz" -C "$TMP_DIR" speedtest 2>/dev/null || tar -xzf "$tgz" -C "$TMP_DIR" 2>/dev/null || {
    log_error "Gagal mengekstrak Speedtest CLI."
    rm -f "$tgz"
    return 1
  }

  if [ -f "$TMP_DIR/speedtest" ]; then
    # 'install' menyalin + set mode 0755 sekaligus.
    install -m 0755 "$TMP_DIR/speedtest" "$OOKLA_CLI_DIR/speedtest" 2>/dev/null || {
      mv -f "$TMP_DIR/speedtest" "$OOKLA_CLI_DIR/speedtest" 2>/dev/null || true
      chmod 0755 "$OOKLA_CLI_DIR/speedtest" 2>/dev/null || true
    }
  fi
  rm -f "$tgz" "$TMP_DIR/speedtest" 2>/dev/null || true
  hash -r 2>/dev/null || true

  if speedtest_is_ookla; then
    log_ok "Speedtest CLI Ookla terpasang: $(command -v speedtest)"
    return 0
  fi
  log_error "Speedtest CLI Ookla gagal dipasang/diverifikasi."
  return 1
}

# ── Terima lisensi CLI secara non-interaktif (WAJIB untuk cron) ──────────────
# CLI Ookla MENOLAK berjalan tanpa TTY selama lisensi belum diterima:
#   "To accept the message please run speedtest interactively or use --accept-license"
# Cron tidak punya TTY → tanpa langkah ini SEMUA laporan cron gagal (rc=1) tanpa
# jejak (bug v8.1.0). Yang menyimpan lisensi ke disk adalah uji pertama yang
# BERHASIL; karena itu wrapper cron (bagian6) SELALU membawa flag lisensi,
# sehingga laporan tetap jalan meski file lisensi belum terbentuk.
accept_ookla_license() {
  local bin
  bin="$(ookla_cli_path)"
  if [ -z "$bin" ]; then
    log_warn "CLI Ookla belum ada — penerimaan lisensi dilewati."
    return 1
  fi
  if ookla_license_accepted; then
    log_ok "Lisensi Ookla sudah diterima sebelumnya ($(ookla_license_file))."
  elif ookla_license_probe "$bin"; then
    log_ok "CLI Ookla menerima flag lisensi non-interaktif (${SPEEDTEST_CLI_LICENSE_FLAGS:-})."
    log_info "Lisensi tersimpan permanen setelah uji speedtest pertama (dilakukan di verifikasi akhir)."
  else
    log_warn "Flag lisensi CLI Ookla tidak diterima — pastikan yang terpasang adalah CLI Ookla resmi."
  fi
  return 0
}

install_speedtest_cli() {
  if speedtest_is_ookla; then
    log_ok "Speedtest CLI Ookla sudah terpasang. Dilewati."
    accept_ookla_license
    return 0
  fi
  if command_exists speedtest; then
    log_warn "Ditemukan 'speedtest' yang BUKAN CLI Ookla (kemungkinan speedtest-cli Python)."
    log_warn "Akan dipasang CLI resmi Ookla di $OOKLA_CLI_DIR (menang di PATH)."
  fi

  case "$OS_FAMILY" in
    debian|rhel)
      # Repositori resmi Ookla (nama paket: speedtest).
      if command_exists curl; then
        if [ "$OS_FAMILY" = "debian" ]; then
          curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh 2>/dev/null | bash >/dev/null 2>&1 || true
        else
          curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh 2>/dev/null | bash >/dev/null 2>&1 || true
        fi
      fi
      pkg_update
      pkg_install speedtest >/dev/null 2>&1 || true
      ;;
    alpine)
      # JANGAN pakai paket 'speedtest-cli' (itu klien Python, tidak kompatibel
      # dengan opsi -o/--host yang dipakai cron reporting bagian6).
      log_info "Alpine: memakai biner resmi Ookla (static musl)."
      ;;
    suse|*)
      log_info "OS family '$OS_FAMILY': memakai biner resmi Ookla."
      ;;
  esac

  if speedtest_is_ookla; then
    log_ok "Speedtest CLI Ookla terpasang via paket: $(command -v speedtest)"
    accept_ookla_license
    return 0
  fi

  if install_ookla_binary; then
    accept_ookla_license
  else
    log_warn "Speedtest CLI Ookla tidak terpasang — cron reporting tidak akan berfungsi."
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Kredensial Cloudflare (hanya jika ApakahPakaiCloudflare=Ya)
# -----------------------------------------------------------------------------
setup_cloudflare_credentials() {
  if [ "${ApakahPakaiCloudflare:-Tidak}" != "Ya" ]; then
    log_info "Cloudflare tidak diaktifkan, melewati setup kredensial."
    return 0
  fi

  local cf_cred="/etc/letsencrypt/dnscloudflare.ini"

  if [ -z "${APICloudFlare:-}" ]; then
    log_warn "APICloudFlare kosong, melewati setup kredensial Cloudflare."
    return 0
  fi

  log_info "Menyiapkan kredensial Cloudflare..."
  local cf_tmp
  cf_tmp="$(mktemp)"
  {
    if [ -n "${EmailCloudFlare:-}" ]; then
      echo "dns_cloudflare_email = $EmailCloudFlare"
      echo "dns_cloudflare_api_key = $APICloudFlare"
    else
      echo "dns_cloudflare_api_token = $APICloudFlare"
    fi
  } > "$cf_tmp"

  mkdir -p "$(dirname "$cf_cred")" 2>/dev/null || true
  chmod 600 "$cf_tmp" 2>/dev/null || true
  if ! mv -f "$cf_tmp" "$cf_cred" 2>/dev/null; then
    # Fallback bila /etc/letsencrypt adalah mount point.
    cat "$cf_tmp" > "$cf_cred" 2>/dev/null || log_error "Gagal menulis $cf_cred"
    rm -f "$cf_tmp" 2>/dev/null || true
  fi
  chmod 600 "$cf_cred" 2>/dev/null || true

  log_ok "Kredensial Cloudflare disimpan di $cf_cred"
  log_info "Token disamarkan: $(mask_secret "$APICloudFlare")"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
install_speedtest_cli

# Ringkasan path CLI untuk audit operator — bagian6 memakai path yang sama
# secara eksplisit agar cron (PATH minimal) tetap menemukannya.
if [ -n "$(ookla_cli_path)" ]; then
  log_info "Path CLI Ookla: $(ookla_cli_path) (dipakai eksplisit oleh cron reporting)."
else
  log_warn "CLI Ookla tidak ditemukan di ${SPEEDTEST_CLI_PATH:-/usr/local/bin/speedtest}."
fi

setup_cloudflare_credentials

log_ok "Bagian 1 selesai."
