#!/usr/bin/env bash
###############################################################################
# bagian4_install_server_certificate.sh
#   - Menerbitkan sertifikat Let's Encrypt sesuai mode:
#       * Cloudflare + wildcard / non-wildcard  -> OTOMATIS (non-interaktif, DNS-01)
#       * non-Cloudflare + wildcard             -> MANUAL DNS-01 (INTERAKTIF)
#       * non-Cloudflare + non-wildcard         -> MANUAL DNS-01 (INTERAKTIF)
#   - Idempotent: lewati bila sertifikat masih berlaku.
#
# CATATAN: Untuk mode non-Cloudflare, certbot --manual akan BERHENTI menampilkan
#          record TXT yang harus Anda tambahkan ke DNS, lalu menunggu Anda
#          menekan Enter (verifikasi manual). Ini memang interaktif sesuai
#          kebutuhan Anda.
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 4: Penerbitan Sertifikat =="

CF_CRED="/etc/letsencrypt/dnscloudflare.ini"
# Email admin: pakai EmailCloudFlare bila ada, jika tidak pakai administrator@Domain.
ADMIN_EMAIL="${EmailCloudFlare:-}"
[ -n "$ADMIN_EMAIL" ] || ADMIN_EMAIL="administrator@${Domain}"
FULLCHAIN="/etc/letsencrypt/live/$Domain/fullchain.pem"

# Apakah sertifikat untuk pola domain tertentu masih berlaku?
cert_valid_for() {
    certbot certificates --domain "$1" 2>/dev/null | grep -iq "Expiry Date"
}

issue_cloudflare_wildcard() {
    log_info "Mode: Cloudflare + Wildcard (*.$Domain) — OTOMATIS."
    certbot certonly \
        -d "*.$Domain" -d "$Domain" \
        --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \
        --dns-cloudflare-propagation-seconds 30 \
        -n --agree-tos --email "$ADMIN_EMAIL" \
        --keep-until-expiring
}

issue_cloudflare_single() {
    log_info "Mode: Cloudflare + non-Wildcard ($Domain) — OTOMATIS."
    certbot certonly \
        -d "$Domain" \
        --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \
        --dns-cloudflare-propagation-seconds 30 \
        -n --agree-tos --email "$ADMIN_EMAIL" \
        --keep-until-expiring
}

# --- Mode MANUAL (non-Cloudflare) : INTERAKTIF ---
# Menampilkan instruksi jelas lalu menjalankan certbot --manual (berhenti
# menunggu Anda update DNS TXT, lalu tekan Enter untuk verifikasi).
print_manual_banner() {
    local target="$1"
    print_hash 60
    log_warn "VERIFIKASI MANUAL DIPERLUKAN (non-Cloudflare)."
    log_warn "Certbot akan MENAMPILKAN satu/lebih record TXT untuk: $target"
    log_warn "LANGKAH ANDA:"
    log_warn "  1) Tambahkan record TXT _acme-challenge sesuai yang ditampilkan."
    log_warn "  2) Tunggu DNS ter-propagasi (cek: dig TXT _acme-challenge.$Domain)."
    log_warn "  3) Setelah propagasi, kembali ke sini dan tekan ENTER."
    print_hash 60
}

ensure_interactive() {
    # certbot --manual butuh TTY. Bila stdin bukan terminal, coba ambil /dev/tty.
    if [ ! -t 0 ] && [ -c /dev/tty ]; then
        # Verifikasi /dev/tty benar-benar bisa dibuka sebelum exec (hindari
        # error mentah bila tidak ada controlling terminal).
        if ( : < /dev/tty ) 2>/dev/null; then
            exec < /dev/tty
        fi
    fi
    if [ ! -t 0 ]; then
        die "Mode non-Cloudflare butuh interaksi terminal untuk update DNS, tetapi tidak ada TTY terdeteksi.
       Jalankan installer LANGSUNG di terminal SSH/console (bukan via pipe atau cron),
       atau gunakan mode Cloudflare (ApakahPakaiCloudflare=\"Ya\") untuk verifikasi otomatis."
    fi
}

issue_manual_wildcard() {
    print_manual_banner "*.$Domain dan $Domain"
    ensure_interactive
    certbot certonly --manual --preferred-challenges=dns \
        -d "*.$Domain" -d "$Domain" \
        --agree-tos --email "$ADMIN_EMAIL" \
        --keep-until-expiring
}

issue_manual_single() {
    print_manual_banner "$Domain"
    ensure_interactive
    certbot certonly --manual --preferred-challenges=dns \
        -d "$Domain" \
        --agree-tos --email "$ADMIN_EMAIL" \
        --keep-until-expiring
}

if [ "${ApakahPakaiCloudflare}" = "Ya" ]; then
    if [ "${ApakahDomainWildcard}" = "Ya" ]; then
        if cert_valid_for "*.$Domain"; then
            log_ok "Sertifikat wildcard masih berlaku, dilewati."
        else
            issue_cloudflare_wildcard
        fi
    else
        if cert_valid_for "$Domain"; then
            log_ok "Sertifikat masih berlaku, dilewati."
        else
            issue_cloudflare_single
        fi
    fi
else
    # NON-CLOUDFLARE: SELALU manual DNS (interaktif), baik wildcard maupun bukan.
    if [ "${ApakahDomainWildcard}" = "Ya" ]; then
        if cert_valid_for "*.$Domain"; then
            log_ok "Sertifikat wildcard masih berlaku, dilewati."
        else
            issue_manual_wildcard
        fi
    else
        if cert_valid_for "$Domain"; then
            log_ok "Sertifikat masih berlaku, dilewati."
        else
            issue_manual_single
        fi
    fi
fi

if [ -f "$FULLCHAIN" ]; then
    log_ok "Sertifikat tersedia: $FULLCHAIN"
else
    die "Sertifikat gagal dibuat / file $FULLCHAIN tidak ditemukan."
fi

log_ok "Bagian 4 selesai."
