#!/usr/bin/env bash
###############################################################################
# bagian3_install_certbot.sh
#   - Memasang certbot + plugin DNS Cloudflare (bila perlu) secara non-interaktif.
#   - Idempotent: jika certbot sudah ada, dilewati.
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 3: Instalasi Certbot =="

NEED_CF_PLUGIN="no"
[ "${ApakahPakaiCloudflare:-Tidak}" = "Ya" ] && NEED_CF_PLUGIN="yes"

cf_plugin_ok() {
    # Plugin dianggap ada bila certbot mengenali --dns-cloudflare.
    certbot plugins 2>/dev/null | grep -qi 'dns-cloudflare'
}

if command_exists certbot; then
    if [ "$NEED_CF_PLUGIN" = "no" ] || cf_plugin_ok; then
        log_ok "Certbot (dan plugin yang diperlukan) sudah terpasang. Dilewati."
        exit 0
    fi
    log_info "Certbot ada, tetapi plugin Cloudflare belum. Memasang plugin..."
fi

install_certbot_debian() {
    pkg_update
    # Paket native (cukup untuk DNS Cloudflare di Debian/Ubuntu modern).
    if [ "$NEED_CF_PLUGIN" = "yes" ]; then
        pkg_install certbot python3-certbot-dns-cloudflare || true
    else
        pkg_install certbot || true
    fi
    # Fallback ke snap bila native gagal menyediakan plugin.
    if ! command_exists certbot || { [ "$NEED_CF_PLUGIN" = "yes" ] && ! cf_plugin_ok; }; then
        log_warn "Paket native tidak lengkap, mencoba snap..."
        pkg_install snapd || true
        command_exists snap && {
            snap install core >/dev/null 2>&1 || true
            snap refresh core >/dev/null 2>&1 || true
            snap install --classic certbot >/dev/null 2>&1 || true
            ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
            [ "$NEED_CF_PLUGIN" = "yes" ] && {
                snap set certbot trust-plugin-with-root=ok >/dev/null 2>&1 || true
                snap install certbot-dns-cloudflare >/dev/null 2>&1 || true
            }
        }
    fi
}

install_certbot_rhel() {
    pkg_install epel-release >/dev/null 2>&1 || true
    pkg_update
    if [ "$NEED_CF_PLUGIN" = "yes" ]; then
        pkg_install certbot python3-certbot-dns-cloudflare || true
    else
        pkg_install certbot || true
    fi
    if ! command_exists certbot || { [ "$NEED_CF_PLUGIN" = "yes" ] && ! cf_plugin_ok; }; then
        log_warn "Paket native tidak lengkap, mencoba snap..."
        pkg_install snapd || true
        if command_exists systemctl; then
            systemctl enable --now snapd.socket >/dev/null 2>&1 || true
        fi
        ln -s /var/lib/snapd/snap /snap >/dev/null 2>&1 || true
        sleep 2
        command_exists snap && {
            snap install core >/dev/null 2>&1 || true
            snap refresh core >/dev/null 2>&1 || true
            snap install --classic certbot >/dev/null 2>&1 || true
            ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
            [ "$NEED_CF_PLUGIN" = "yes" ] && {
                snap set certbot trust-plugin-with-root=ok >/dev/null 2>&1 || true
                snap install certbot-dns-cloudflare >/dev/null 2>&1 || true
            }
        }
    fi
}

install_certbot_alpine() {
    # certbot-dns-cloudflare berada di repo 'community'. Pastikan aktif.
    if [ "$NEED_CF_PLUGIN" = "yes" ] && [ -f /etc/apk/repositories ]; then
        if ! grep -q '/community' /etc/apk/repositories 2>/dev/null; then
            log_info "Mengaktifkan repo Alpine 'community' untuk plugin Cloudflare..."
            echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories
        fi
    fi
    pkg_update
    if [ "$NEED_CF_PLUGIN" = "yes" ]; then
        # Coba paket plugin; nama bisa berbeda antar versi Alpine.
        pkg_install certbot py3-certbot-dns-cloudflare 2>/dev/null \
            || pkg_install certbot certbot-dns-cloudflare 2>/dev/null \
            || pkg_install certbot 2>/dev/null || true
    else
        pkg_install certbot || true
    fi
}

install_certbot_suse() {
    pkg_update
    if [ "$NEED_CF_PLUGIN" = "yes" ]; then
        pkg_install certbot python3-certbot-dns-cloudflare || true
    else
        pkg_install certbot || true
    fi
}

case "$OS_FAMILY" in
    debian) install_certbot_debian ;;
    rhel)   install_certbot_rhel ;;
    alpine) install_certbot_alpine ;;
    suse)   install_certbot_suse ;;
    *)      die "OS family '$OS_FAMILY' tidak didukung untuk instalasi certbot." ;;
esac

command_exists certbot || die "Certbot gagal dipasang."
if [ "$NEED_CF_PLUGIN" = "yes" ] && ! cf_plugin_ok; then
    die "Plugin certbot DNS Cloudflare gagal dipasang. Tidak bisa lanjut untuk mode Cloudflare wildcard."
fi

log_ok "Bagian 3 selesai (certbot siap)."
