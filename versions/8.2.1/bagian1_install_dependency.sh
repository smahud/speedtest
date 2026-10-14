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

# ── PIN SHA-256 tarball CLI Ookla (integritas; hardening v8.2.1) ─────────────
# Nilai dihitung dari unduhan resmi install.speedtest.net untuk versi di atas.
# Override: OOKLA_CLI_SHA256 di speedtest-repo.conf (mis. saat naik versi).
# Bila hash untuk arsitektur tidak dikenal → pemasangan biner DITOLAK kecuali
# OOKLA_CLI_ALLOW_UNVERIFIED="Ya".
OOKLA_CLI_SHA256="${OOKLA_CLI_SHA256:-}"
OOKLA_CLI_ALLOW_UNVERIFIED="${OOKLA_CLI_ALLOW_UNVERIFIED:-Tidak}"
OOKLA_CLI_SHA256_X86_64="5690596c54ff9bed63fa3732f818a05dbc2db19ad36ed68f21ca5f64d5cfeeb7"
OOKLA_CLI_SHA256_AARCH64="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
OOKLA_CLI_SHA256_ARMHF="e45fcdebbd8a185553535533dd032d6b10bc8c64eee4139b1147b9c09835d08d"
OOKLA_CLI_SHA256_I386="9ff7e18dbae7ee0e03c66108445a2fb6ceea6c86f66482e1392f55881b772fe8"

ookla_cli_expected_sha256() {
  local arch="$1"
  if [ -n "$OOKLA_CLI_SHA256" ]; then printf '%s' "$OOKLA_CLI_SHA256"; return 0; fi
  case "$arch" in
    x86_64)  printf '%s' "$OOKLA_CLI_SHA256_X86_64" ;;
    aarch64) printf '%s' "$OOKLA_CLI_SHA256_AARCH64" ;;
    armhf)   printf '%s' "$OOKLA_CLI_SHA256_ARMHF" ;;
    i386)    printf '%s' "$OOKLA_CLI_SHA256_I386" ;;
    *)       printf '' ;;
  esac
}

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

  # ── Verifikasi SHA-256 tarball SEBELUM diekstrak (mencegah eksekusi biner
  #    yang korrupt/ditukar). Gagal verifikasi = tolak, bukan hanya peringatan.
  local want_sum got_sum
  want_sum="$(ookla_cli_expected_sha256 "$arch")"
  got_sum=""
  if command -v sha256_of_file >/dev/null 2>&1; then
    got_sum="$(sha256_of_file "$tgz")"
  elif command -v sha256sum >/dev/null 2>&1; then
    got_sum="$(sha256sum "$tgz" 2>/dev/null | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    got_sum="$(openssl dgst -sha256 "$tgz" 2>/dev/null | awk '{print $NF}')"
  fi
  if [ -z "$want_sum" ]; then
    if [ "$OOKLA_CLI_ALLOW_UNVERIFIED" != "Ya" ]; then
      log_error "PIN hash CLI Ookla untuk arsitektur '$arch' belum tersedia —"
      log_error "biner TIDAK dipasang. Set OOKLA_CLI_SHA256 (hash resmi) atau"
      log_error "OOKLA_CLI_ALLOW_UNVERIFIED=\"Ya\" di speedtest-repo.conf bila setuju."
      rm -f "$tgz"
      return 1
    fi
    log_warn "PIN hash CLI Ookla tidak tersedia & verifikasi diizinkan dilewati (OOKLA_CLI_ALLOW_UNVERIFIED=Ya)."
  elif [ -z "$got_sum" ]; then
    log_warn "Tidak ada tool SHA-256 untuk memverifikasi tarball CLI Ookla — dilewati."
  elif [ "$want_sum" != "$got_sum" ]; then
    log_error "SHA-256 tarball CLI Ookla TIDAK cocok (diharap ${want_sum:0:12}…, dapat ${got_sum:0:12}…) — dibatalkan."
    rm -f "$tgz"
    return 1
  else
    log_ok "SHA-256 tarball CLI Ookla terverifikasi (${got_sum:0:12}…)."
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
