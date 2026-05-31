#!/usr/bin/env bash
###############################################################################
# bagian1_install_dependency.sh
# - Memasang Speedtest CLI (Ookla)
# - Menyiapkan kredensial Cloudflare (jika diperlukan)
# - Idempotent: lewati jika sudah terpasang.
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
  resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 1: Instalasi Speedtest CLI & Kredensial Cloudflare =="

# -----------------------------------------------------------------------------
# 1. Instalasi Speedtest CLI
# -----------------------------------------------------------------------------
install_speedtest_cli() {
  if command_exists speedtest; then
    log_ok "Speedtest CLI sudah terpasang. Melewati instalasi."
    return 0
  fi

  log_info "Memasang Speedtest CLI..."

  case "$OS_FAMILY" in
    debian|rhel)
      # Gunakan repository resmi Ookla
      if command -v curl >/dev/null 2>&1; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1 || true
      fi
      pkg_update
      pkg_install speedtest || {
        log_warn "Gagal memasang speedtest via package manager, mencoba binary langsung..."
        local arch
        arch=$(uname -m)
        case "$arch" in
          x86_64) arch="x86_64" ;;
          aarch64|arm64) arch="aarch64" ;;
          armv7l|armhf) arch="armhf" ;;
          i386|i686) arch="i386" ;;
          *) log_error "Arsitektur tidak didukung: $arch"; return 1 ;;
        esac
        local url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${arch}.tgz"
        mkdir -p "$TMP_DIR"
        wget -q -O "$TMP_DIR/speedtest.tgz" "$url" || curl -fsSL -o "$TMP_DIR/speedtest.tgz" "$url" || {
          log_error "Gagal mengunduh Speedtest CLI."; return 1
        }
        tar -xzf "$TMP_DIR/speedtest.tgz" -C "$TMP_DIR"
        mv -f "$TMP_DIR/speedtest" /usr/local/bin/speedtest 2>/dev/null || mv -f "$TMP_DIR/speedtest" /usr/bin/speedtest 2>/dev/null || true
        chmod +x /usr/local/bin/speedtest 2>/dev/null || chmod +x /usr/bin/speedtest 2>/dev/null || true
        rm -f "$TMP_DIR/speedtest.tgz"
      }
      ;;
    alpine)
      pkg_update
      # Alpine: speedtest-cli ada di community
      if ! grep -q '/community' /etc/apk/repositories 2>/dev/null; then
        echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories
        pkg_update
      fi
      pkg_install speedtest-cli || {
        log_warn "Gagal via apk, mencoba binary langsung..."
        local arch
        arch=$(uname -m)
        case "$arch" in
          x86_64) arch="x86_64" ;;
          aarch64|arm64) arch="aarch64" ;;
          armv7l|armhf) arch="armhf" ;;
          i386|i686) arch="i386" ;;
          *) log_error "Arsitektur tidak didukung: $arch"; return 1 ;;
        esac
        local url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${arch}.tgz"
        mkdir -p "$TMP_DIR"
        wget -q -O "$TMP_DIR/speedtest.tgz" "$url" || curl -fsSL -o "$TMP_DIR/speedtest.tgz" "$url" || {
          log_error "Gagal mengunduh Speedtest CLI."; return 1
        }
        tar -xzf "$TMP_DIR/speedtest.tgz" -C "$TMP_DIR"
        mv -f "$TMP_DIR/speedtest" /usr/local/bin/speedtest 2>/dev/null || mv -f "$TMP_DIR/speedtest" /usr/bin/speedtest 2>/dev/null || true
        chmod +x /usr/local/bin/speedtest 2>/dev/null || chmod +x /usr/bin/speedtest 2>/dev/null || true
        rm -f "$TMP_DIR/speedtest.tgz"
      }
      ;;
    *)
      log_warn "OS family '$OS_FAMILY', mencoba binary langsung..."
      local arch
      arch=$(uname -m)
      case "$arch" in
        x86_64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        armv7l|armhf) arch="armhf" ;;
        i386|i686) arch="i386" ;;
        *) log_error "Arsitektur tidak didukung: $arch"; return 1 ;;
      esac
      local url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${arch}.tgz"
      mkdir -p "$TMP_DIR"
      wget -q -O "$TMP_DIR/speedtest.tgz" "$url" || curl -fsSL -o "$TMP_DIR/speedtest.tgz" "$url" || {
        log_error "Gagal mengunduh Speedtest CLI."; return 1
      }
      tar -xzf "$TMP_DIR/speedtest.tgz" -C "$TMP_DIR"
      mv -f "$TMP_DIR/speedtest" /usr/local/bin/speedtest 2>/dev/null || mv -f "$TMP_DIR/speedtest" /usr/bin/speedtest 2>/dev/null || true
      chmod +x /usr/local/bin/speedtest 2>/dev/null || chmod +x /usr/bin/speedtest 2>/dev/null || true
      rm -f "$TMP_DIR/speedtest.tgz"
      ;;
  esac

  if command_exists speedtest; then
    log_ok "Speedtest CLI berhasil dipasang."
  else
    log_warn "Speedtest CLI mungkin tidak terpasang dengan benar, lanjut..."
  fi
}

# -----------------------------------------------------------------------------
# 2. Kredensial Cloudflare (hanya jika ApakahPakaiCloudflare=Ya)
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

  # Tulis kredensial secara atomik
  local cf_tmp
  cf_tmp="$(mktemp)"
  {
    if [ -n "${EmailCloudFlare:-}" ]; then
      # Mode: Global API Key (pakai email + api key)
      echo "dns_cloudflare_email = $EmailCloudFlare"
      echo "dns_cloudflare_api_key = $APICloudFlare"
    else
      # Mode: API Token (modern)
      echo "dns_cloudflare_api_token = $APICloudFlare"
    fi
  } > "$cf_tmp"

  mkdir -p "$(dirname "$cf_cred")"
  chmod 600 "$cf_tmp" 2>/dev/null || true
  mv -f "$cf_tmp" "$cf_cred"
  chmod 600 "$cf_cred" 2>/dev/null || true

  log_ok "Kredensial Cloudflare disimpan di $cf_cred"
  log_info "Token disamarkan: $(mask_secret "$APICloudFlare")"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
install_speedtest_cli
setup_cloudflare_credentials

log_ok "Bagian 1 selesai."
