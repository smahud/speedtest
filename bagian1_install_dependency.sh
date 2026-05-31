#!/usr/bin/env bash
###############################################################################
# bagian1_install_dependency.sh
#   - Memasang Speedtest CLI (Ookla) untuk keperluan reporting.
#   - Menulis kredensial Cloudflare untuk certbot (bila dipakai).
#
# Semua temp file mengikuti $TMP_DIR ($BASE_DIR/tmp). Token TIDAK dicetak.
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

# Inisialisasi mandiri bila dijalankan langsung.
if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 1: Dependency & Speedtest CLI =="

# --- Pasang Speedtest CLI (idempotent) ----------------------------------------
SPEEDTEST_CLI_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
SPEEDTEST_TGZ="$TMP_DIR/speedtest.tgz"

if command_exists speedtest && speedtest --version >/dev/null 2>&1; then
    log_ok "Speedtest CLI sudah terpasang, dilewati."
else
    # Sesuaikan arsitektur (x86_64 / aarch64).
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) SPEEDTEST_CLI_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz" ;;
        aarch64|arm64) SPEEDTEST_CLI_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" ;;
        armv7l|armhf)  SPEEDTEST_CLI_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-armhf.tgz" ;;
        i386|i686)     SPEEDTEST_CLI_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-i386.tgz" ;;
        *) log_warn "Arsitektur '$arch' tidak dikenali, mencoba paket x86_64." ;;
    esac

    log_info "Mengunduh Speedtest CLI ($arch)..."
    mkdir -p /usr/local/bin
    if wget -q -O "$SPEEDTEST_TGZ" "$SPEEDTEST_CLI_URL"; then
        # Ekstrak hanya biner 'speedtest'. Beberapa arsip menaruh path berbeda,
        # jadi pakai --strip-components bila perlu (best effort).
        if tar -xzf "$SPEEDTEST_TGZ" -C /usr/local/bin speedtest 2>/dev/null; then
            :
        else
            # fallback: ekstrak semua ke tmp lalu pindahkan binernya
            tar -xzf "$SPEEDTEST_TGZ" -C "$TMP_DIR" 2>/dev/null || true
            if [ -f "$TMP_DIR/speedtest" ]; then
                mv -f "$TMP_DIR/speedtest" /usr/local/bin/speedtest
            fi
        fi
        if [ -f /usr/local/bin/speedtest ]; then
            chmod a+x /usr/local/bin/speedtest
            rm -f "$SPEEDTEST_TGZ"
            log_ok "Speedtest CLI terpasang di /usr/local/bin/speedtest."
        else
            log_warn "Biner speedtest tidak ditemukan setelah ekstraksi."
        fi
    else
        log_warn "Gagal mengunduh Speedtest CLI. Reporting CLI mungkin tidak tersedia."
    fi
fi

# --- Tulis kredensial Cloudflare untuk certbot --------------------------------
if [ "${ApakahPakaiCloudflare:-Tidak}" = "Ya" ]; then
    log_info "Menyiapkan kredensial Cloudflare untuk certbot..."
    mkdir -p /etc/letsencrypt
    CF_CRED="/etc/letsencrypt/dnscloudflare.ini"

    # Tulis dengan umask ketat agar token tidak bocor lewat permission.
    ( umask 077
      {
        if [ -n "${EmailCloudFlare:-}" ]; then
            printf 'dns_cloudflare_email = %s\n' "$EmailCloudFlare"
        fi
        printf 'dns_cloudflare_api_token = %s\n' "$APICloudFlare"
      } > "$CF_CRED"
    )
    chmod 600 "$CF_CRED"
    chown root:root "$CF_CRED" 2>/dev/null || true
    log_ok "Kredensial Cloudflare ditulis ke $CF_CRED (token: $(mask_secret "$APICloudFlare"))."
else
    log_info "Mode non-Cloudflare: melewati penulisan kredensial Cloudflare."
fi

log_ok "Bagian 1 selesai."
