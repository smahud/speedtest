#!/usr/bin/env bash
###############################################################################
# bagian9_ssh_access.sh
#   - Memasang public key dari GitHub (SSH_KEYS_URL, default
#     https://github.com/smahud.keys) ke authorized_keys user target
#     (SSH_TARGET_USERS, default: root).
#   - STANDARDISASI konfigurasi sshd (drop-in /etc/ssh/sshd_config.d/ bila
#     didukung, fallback ke sshd_config utama) dengan:
#       * backup sebelum mengubah
#       * validasi `sshd -t` SEBELUM reload + rollback otomatis bila gagal
#       * TIDAK mematikan PasswordAuthentication kecuali diminta eksplisit
#         (SSH_DISABLE_PASSWORD_AUTH="Ya") → mencegah server terkunci
#       * kunci lama yang dikelola (blok penanda) dibuang agar tidak menumpuk
#
# Seluruh logika kunci/sshd ada di common_functions1.sh (ssh_sync_all) supaya
# bagian9 dan bagian10 (boot-sync) memakai implementasi yang SAMA — dulu
# keduanya punya salinan sendiri yang bisa berbeda perilaku.
#
# Aman dijalankan ulang (idempotent). Nilai diambil dari speedtest-repo.conf.
###############################################################################
set -uo pipefail

SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
    resolve_config_path "${1:-}"; init_paths; detect_os; detect_init; load_and_validate_config
fi

log_info "== Bagian 9: Akses SSH (public key GitHub + standardisasi sshd) =="

SSH_KEYS_URL="${SSH_KEYS_URL:-https://github.com/smahud.keys}"
SSH_TARGET_USERS="${SSH_TARGET_USERS:-root}"
SSH_INSTALL_SERVER="${SSH_INSTALL_SERVER:-Ya}"

# ── 1. Pastikan openssh-server terpasang (best-effort, tidak fatal) ──────────
ensure_sshd() {
    if [ "$SSH_INSTALL_SERVER" != "Ya" ]; then
        log_info "SSH_INSTALL_SERVER=Tidak → pemasangan openssh-server dilewati."
        return 0
    fi
    if [ -n "$(sshd_bin_path)" ]; then
        log_ok "SSH server sudah tersedia."
        return 0
    fi
    log_info "Memasang openssh-server..."
    case "${OS_FAMILY:-unknown}" in
        alpine) pkg_install openssh >/dev/null 2>&1 || true ;;
        debian|rhel|suse) pkg_install openssh-server >/dev/null 2>&1 || true ;;
        *) pkg_install openssh-server >/dev/null 2>&1 || pkg_install openssh >/dev/null 2>&1 || true ;;
    esac
    if [ -n "$(sshd_bin_path)" ]; then
        log_ok "openssh-server terpasang."
    else
        log_warn "openssh-server tidak terpasang. Konfigurasi sshd dilewati (kunci tetap dipasang)."
    fi
    return 0
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
ensure_sshd

log_info "Menyinkronkan akses SSH (kunci dari $SSH_KEYS_URL, user: $SSH_TARGET_USERS)..."
if ssh_sync_all; then
    log_ok "Bagian 9 selesai (akses SSH via public key siap)."
else
    # Tidak fatal di level instalasi: bagian10 (boot-sync) akan mengulanginya,
    # tetapi operator harus tahu bahwa konfigurasi SSH belum sepenuhnya siap.
    log_warn "Bagian 9 belum sepenuhnya berhasil — akan diulang otomatis oleh boot-sync (@reboot) dan self-update."
fi
exit 0
