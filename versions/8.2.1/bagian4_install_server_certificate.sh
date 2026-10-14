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

# Nilai dari data.ini (load_and_validate_config). Default aman bila kosong.
Domain="${Domain:-}"
ApakahPakaiCloudflare="${ApakahPakaiCloudflare:-Tidak}"
ApakahDomainWildcard="${ApakahDomainWildcard:-Tidak}"

log_info "== Bagian 4: Penerbitan Sertifikat =="

# certbot dipasang oleh bagian3. Bila gagal/tidak ada, hentikan dengan pesan
# yang jelas (OoklaServer butuh sertifikat untuk endpoint HTTPS).
if ! command_exists certbot; then
    die "certbot tidak tersedia. Jalankan ulang: bash $BASE_DIR/bagian3_install_certbot.sh lalu ulangi instalasi."
fi

CF_CRED="/etc/letsencrypt/dnscloudflare.ini"
# Email admin: pakai EmailCloudFlare bila ada, jika tidak pakai administrator@Domain.
ADMIN_EMAIL="${EmailCloudFlare:-}"
# Domain dibaca dari data.ini saat runtime (load_and_validate_config)
# shellcheck disable=SC2154
[ -n "$ADMIN_EMAIL" ] || ADMIN_EMAIL="administrator@${Domain}"
FULLCHAIN="${CERT_LIVE_DIR:-/etc/letsencrypt/live}/$Domain/fullchain.pem"
CRON_PATH_RESOLVED="${CRON_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

# catatan: cert_valid_for()/cert_days_left() ada di common_functions1.sh
# (dipakai bersama oleh bagian4, cert-check.sh, dan uji E2E).

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
    if ! cert_valid_for "$Domain"; then
        log_warn "Sertifikat ada tetapi belum lolos verifikasi masa berlaku — cek: certbot certificates"
    fi
else
    die "Sertifikat gagal dibuat / file $FULLCHAIN tidak ditemukan."
fi

# ── Pemeliharaan sertifikat otomatis ─────────────────────────────────────────
# Mode Cloudflare (plugin DNS-01) bisa di-renew tanpa interaksi → dijadwalkan.
# Mode manual DNS tidak bisa non-interaktif → dipasang pemantau masa berlaku
# yang menulis peringatan ke update.log sebelum sertifikat kedaluwarsa.
schedule_cert_maintenance() {
    if [ "${ApakahPakaiCloudflare:-Tidak}" = "Ya" ]; then
        cat > "$BASE_DIR/certbot-renew.sh" <<'RENEOF'
#!/usr/bin/env bash
# certbot-renew.sh — dibuat otomatis oleh bagian4_install_server_certificate.sh
# Renewal non-interaktif (Cloudflare DNS plugin). certbot hanya memperbarui bila
# sertifikat memang mendekati kedaluwarsa; OoklaServer di-restart lewat
# --deploy-hook HANYA bila sertifikat benar-benar diperbarui.
BASE_DIR="__BASE_DIR__"
LOG="$BASE_DIR/update.log"

# PATH eksplisit: cron hanya memberi /usr/bin:/bin (certbot bisa di
# /usr/bin, tetapi deploy-hook memanggil ooklaserver.sh di BASE_DIR).
PATH="__CRON_PATH__"
export PATH
CERTBOT_BIN="$(command -v certbot 2>/dev/null || true)"
[ -n "$CERTBOT_BIN" ] || CERTBOT_BIN="/usr/bin/certbot"

{
    printf '%s [INFO] certbot renew (otomatis) dimulai.\n' "$(date '+%F %T')"
    rc=0
    if command -v flock >/dev/null 2>&1; then
        flock -n /run/speedtest-certbot-renew.lock \
            "$CERTBOT_BIN" renew --non-interactive --quiet \
            --deploy-hook "cd $BASE_DIR && ./ooklaserver.sh restart" || rc=$?
    else
        "$CERTBOT_BIN" renew --non-interactive --quiet \
            --deploy-hook "cd $BASE_DIR && ./ooklaserver.sh restart" || rc=$?
    fi
    printf '%s [INFO] certbot renew selesai (rc=%s).\n' "$(date '+%F %T')" "$rc"
} >> "$LOG" 2>&1
exit 0
RENEOF
        sed -i "s|__BASE_DIR__|$(sed_escape_repl "${BASE_DIR}")|; s|__CRON_PATH__|$(sed_escape_repl "${CRON_PATH_RESOLVED}")|" "$BASE_DIR/certbot-renew.sh"
        chmod a+x "$BASE_DIR/certbot-renew.sh"
        if cron_apply "# speedtest-cert-renew (managed)" \
             "23 4 * * * bash $BASE_DIR/certbot-renew.sh >/dev/null 2>&1"; then
            log_ok "Renewal sertifikat otomatis dijadwalkan (harian 04:23, mode Cloudflare)."
        else
            log_warn "Gagal menjadwalkan renewal sertifikat (crontab?)."
        fi
    else
        cat > "$BASE_DIR/cert-check.sh" <<'CHKEOF'
#!/usr/bin/env bash
# cert-check.sh — dibuat otomatis oleh bagian4_install_server_certificate.sh
# Pemantau masa berlaku sertifikat untuk mode DNS manual (renewal butuh
# verifikasi DNS oleh manusia, jadi tidak bisa diotomatiskan sepenuhnya).
DOMAIN="__DOMAIN__"
FULLCHAIN="__FULLCHAIN__"
BASE_DIR="__BASE_DIR__"
LOG="$BASE_DIR/update.log"

# PATH eksplisit untuk konteks cron (openssl ada di /usr/bin, dokumentasi jelas).
PATH="__CRON_PATH__"
export PATH

[ -f "$FULLCHAIN" ] || exit 0

# Hitung sisa masa berlaku memakai pustaka bersama (SATU implementasi dengan
# bagian4 + uji E2E — dulu duplikat yang bisa menyimpang).
CERT_LIVE_DIR="__CERT_LIVE_DIR__"
export CERT_LIVE_DIR
if [ -f "$BASE_DIR/common_functions1.sh" ]; then
    # shellcheck source=common_functions1.sh
    . "$BASE_DIR/common_functions1.sh" >/dev/null 2>&1 || true
fi
days="$(cert_days_left "$DOMAIN" 2>/dev/null || true)"
if [ -z "$days" ]; then
    command -v openssl >/dev/null 2>&1 || exit 0
    end="$(openssl x509 -enddate -noout -in "$FULLCHAIN" 2>/dev/null | cut -d= -f2)"
    [ -n "$end" ] || exit 0
    end_epoch="$(date -d "$end" +%s 2>/dev/null || date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null)"
    [ -n "$end_epoch" ] || exit 0
    days=$(( (end_epoch - $(date +%s)) / 86400 ))
fi
if [ "$days" -lt 21 ]; then
    printf '%s [WARN] Sertifikat %s kedaluwarsa dalam %s hari — perbarui dengan menjalankan: bash %s/bagian4_install_server_certificate.sh (perlu verifikasi DNS manual).\n' \
        "$(date '+%F %T')" "$DOMAIN" "$days" "$BASE_DIR" >> "$LOG"
    logger -t speedtest-cert "Sertifikat $DOMAIN tersisa $days hari" 2>/dev/null || true
fi
exit 0
CHKEOF
        sed -i "s|__DOMAIN__|$(sed_escape_repl "${Domain}")|; s|__FULLCHAIN__|$(sed_escape_repl "${FULLCHAIN}")|; s|__BASE_DIR__|$(sed_escape_repl "${BASE_DIR}")|; s|__CRON_PATH__|$(sed_escape_repl "${CRON_PATH_RESOLVED}")|; s|__CERT_LIVE_DIR__|$(sed_escape_repl "${CERT_LIVE_DIR:-/etc/letsencrypt/live}")|" "$BASE_DIR/cert-check.sh"
        chmod a+x "$BASE_DIR/cert-check.sh"
        if cron_apply "# speedtest-cert-check (managed)" \
             "41 4 * * * bash $BASE_DIR/cert-check.sh >/dev/null 2>&1"; then
            log_ok "Pemantau masa berlaku sertifikat aktif (harian 04:41, mode DNS manual)."
        else
            log_warn "Gagal menjadwalkan pemantau sertifikat (crontab?)."
        fi
    fi
}
schedule_cert_maintenance

log_ok "Bagian 4 selesai."
