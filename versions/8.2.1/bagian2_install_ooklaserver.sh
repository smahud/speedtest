#!/usr/bin/env bash
###############################################################################
# bagian2_install_ooklaserver.sh
#   - Mengunduh & memasang OoklaServer ke $BASE_DIR (bukan /root).
#   - Menyiapkan OoklaServer.properties dasar (idempotent).
###############################################################################
set -euo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 2: Instalasi OoklaServer =="

# Pastikan ooklaserver.sh tersedia di BASE_DIR.
if [ ! -f "$OOKLA_SCRIPT" ]; then
    if [ -f "$SCRIPT_DIR/ooklaserver.sh" ]; then
        cp -f "$SCRIPT_DIR/ooklaserver.sh" "$OOKLA_SCRIPT"
    else
        log_info "Mengunduh ooklaserver.sh resmi..."
        wget -q -O "$OOKLA_SCRIPT" "https://install.speedtest.net/ooklaserver/ooklaserver.sh" \
            || die "Gagal mengunduh ooklaserver.sh"
    fi
fi
chmod a+x "$OOKLA_SCRIPT"

if [ -f "$OOKLA_BIN" ]; then
    log_ok "OoklaServer sudah terpasang di $OOKLA_BIN. Melewati instalasi biner."
else
    log_info "Memasang OoklaServer ke $BASE_DIR ..."
    # ooklaserver.sh memasang biner di CWD; jalankan dari BASE_DIR.
    # Note: we call it with 'install' command. The '-f' is now supported/ignored.
    ( cd "$BASE_DIR" && "$OOKLA_SCRIPT" -f install ) \
        || die "Instalasi OoklaServer gagal."
fi

# Hentikan daemon yang mungkin baru saja start oleh 'install -f' agar tidak
# berjalan dengan konfigurasi SSL yang belum lengkap (sertifikat menyusul).
log_info "Menghentikan daemon sementara (sertifikat dikonfigurasi di bagian berikutnya)..."
( cd "$BASE_DIR" && "$OOKLA_SCRIPT" stop ) >/dev/null 2>&1 || true

# --- Aktifkan opsi penting di OoklaServer.properties (idempotent) -------------
if [ -f "$OOKLA_PROPERTIES" ]; then
    log_info "Menyesuaikan OoklaServer.properties..."
    # Uncomment opsi default penting bila masih dikomentari.
    sed -i 's/^# *\(OoklaServer\.allowedDomains[[:space:]]*=.*\)/\1/' "$OOKLA_PROPERTIES" || true
    sed -i 's/^# *\(OoklaServer\.enableAutoUpdate.*\)/\1/' "$OOKLA_PROPERTIES" || true

    # PENTING: JANGAN aktifkan useLetsEncrypt di sini. Kita memakai path
    # sertifikat eksplisit (di-set bagian5). useLetsEncrypt=true tanpa cert
    # membuat daemon gagal start. Pastikan baris itu dikomentari/dihapus.
    sed -i 's/^\(OoklaServer\.ssl\.useLetsEncrypt[[:space:]]*=.*\)/# \1/' "$OOKLA_PROPERTIES" || true

    # Pastikan allowedDomains ada (untuk verifikasi & sertifikat).
    if ! grep -qE '^OoklaServer\.allowedDomains' "$OOKLA_PROPERTIES"; then
        echo "OoklaServer.allowedDomains = *.ookla.com, *.speedtest.net" >> "$OOKLA_PROPERTIES"
    fi
    log_ok "OoklaServer.properties disiapkan."
else
    log_warn "OoklaServer.properties tidak ditemukan setelah instalasi."
fi

log_ok "Bagian 2 selesai."
