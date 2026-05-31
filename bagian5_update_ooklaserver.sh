#!/usr/bin/env bash
###############################################################################
# bagian5_update_ooklaserver.sh
#   - Menyetel path sertifikat di OoklaServer.properties ($BASE_DIR).
#   - Restart OoklaServer memakai $OOKLA_SCRIPT (bukan /root/ooklaserver.sh).
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 5: Update OoklaServer & Sertifikat =="

[ -f "$OOKLA_PROPERTIES" ] || die "OoklaServer.properties tidak ditemukan di $OOKLA_PROPERTIES"

CERT_FULLCHAIN="/etc/letsencrypt/live/$Domain/fullchain.pem"
CERT_PRIVKEY="/etc/letsencrypt/live/$Domain/privkey.pem"

# Hentikan server bila sedang berjalan (memakai script instalasi yang benar).
log_info "Menghentikan OoklaServer (jika berjalan)..."
( cd "$BASE_DIR" && "$OOKLA_SCRIPT" stop ) >/dev/null 2>&1 || true
# Pengaman tambahan.
if pgrep -x "OoklaServer" >/dev/null 2>&1; then
    pkill -f "$OOKLA_BIN" 2>/dev/null || pkill -f "OoklaServer" 2>/dev/null || true
    sleep 2
fi

# --- Verifikasi file sertifikat benar-benar ada sebelum dipakai ---------------
if [ ! -f "$CERT_FULLCHAIN" ] || [ ! -f "$CERT_PRIVKEY" ]; then
    die "File sertifikat tidak ditemukan ($CERT_FULLCHAIN / $CERT_PRIVKEY). Jalankan bagian4 dulu."
fi

# --- Bersihkan baris cert/SSL lama lalu tulis ulang (idempotent) --------------
# Pakai 'grep || true' agar pipeline tidak gagal di bawah 'set -e' bila tidak
# ada match (mis. file properties masih minimal).
tmp_prop="$TMP_DIR/OoklaServer.properties.new"
{
    grep -vE '^[[:space:]]*openSSL\.server\.certificateFile[[:space:]]*=' "$OOKLA_PROPERTIES" \
      | grep -vE '^[[:space:]]*openSSL\.server\.privateKeyFile[[:space:]]*=' \
      | grep -vE '^[[:space:]]*OoklaServer\.ssl\.useLetsEncrypt[[:space:]]*=[[:space:]]*true'
} > "$tmp_prop" || true

{
    echo "openSSL.server.certificateFile = $CERT_FULLCHAIN"
    echo "openSSL.server.privateKeyFile = $CERT_PRIVKEY"
} >> "$tmp_prop"

mv -f "$tmp_prop" "$OOKLA_PROPERTIES"
log_ok "OoklaServer.properties diperbarui dengan path sertifikat domain '$Domain'."

# --- Start/restart memakai script lokal (TANPA re-download biner) -------------
# Biner sudah dipasang di bagian2; cukup restart agar konfigurasi cert dibaca.
log_info "Menjalankan OoklaServer dengan konfigurasi sertifikat baru..."
( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || die "Gagal me-restart OoklaServer."

# Bersihkan file sisa di BASE_DIR (bukan CWD).
rm -f "$BASE_DIR/OoklaServer.properties.default" 2>/dev/null || true

log_ok "Bagian 5 selesai (OoklaServer berjalan kembali)."
