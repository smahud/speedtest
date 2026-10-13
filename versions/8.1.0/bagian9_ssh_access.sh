#!/usr/bin/env bash
###############################################################################
# bagian9_ssh_access.sh
#   - Memasang public key dari GitHub (SSH_KEYS_URL, default
#     https://github.com/smahud.keys) ke authorized_keys user target
#     (SSH_TARGET_USERS, default: root).
#   - STANDARDISASI konfigurasi sshd (file drop-in di /etc/ssh/sshd_config.d/
#     bila didukung, fallback ke sshd_config utama) — dengan:
#       * backup sebelum ubah
#       * validasi `sshd -t` SEBELUM reload, rollback otomatis bila gagal
#       * TIDAK mengubah PasswordAuthentication kecuali diminta eksplisit
#         (mencegah server terkunci)
#       * hapus kunci yang dikelola sebelumnya (ditandai) agar tidak menumpuk
#
# Aman dijalankan ulang (idempotent). Semua nilai diambil dari
# speedtest-repo.conf di BASE_DIR.
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
SSH_MANAGE_SSHD="${SSH_MANAGE_SSHD:-Ya}"
SSH_INSTALL_SERVER="${SSH_INSTALL_SERVER:-Ya}"
SSH_ROOT_LOGIN="${SSH_ROOT_LOGIN:-prohibit-password}"
SSH_DISABLE_PASSWORD_AUTH="${SSH_DISABLE_PASSWORD_AUTH:-Tidak}"
SSH_MARKER="${SSH_MARKER:-speedtest-managed-keys}"

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="$SSHD_DROPIN_DIR/99-speedtest-managed.conf"

# ── Helper: apakah user ada? ─────────────────────────────────────────────────
user_exists() {
    id "$1" >/dev/null 2>&1
}

home_of() {
    local h=""
    h="$(user_home "$1")"
    [ -n "$h" ] || h="/root"
    printf '%s' "$h"
}

# ── 1. Pastikan openssh-server terpasang ─────────────────────────────────────
ensure_sshd() {
    [ "$SSH_INSTALL_SERVER" = "Ya" ] || return 0
    if command_exists sshd || [ -x /usr/sbin/sshd ]; then
        log_ok "SSH server sudah tersedia."
        return 0
    fi
    log_info "Memasang openssh-server..."
    case "$OS_FAMILY" in
        debian) pkg_install openssh-server >/dev/null 2>&1 || true ;;
        rhel)   pkg_install openssh-server >/dev/null 2>&1 || true ;;
        alpine) pkg_install openssh >/dev/null 2>&1 || true ;;
        suse)   pkg_install openssh-server >/dev/null 2>&1 || pkg_install openssh >/dev/null 2>&1 || true ;;
        *)      pkg_install openssh-server >/dev/null 2>&1 || pkg_install openssh >/dev/null 2>&1 || true ;;
    esac
    if command_exists sshd || [ -x /usr/sbin/sshd ]; then
        log_ok "openssh-server terpasang."
    else
        log_warn "openssh-server tidak terpasang. Langkah sshd akan dilewati (kunci tetap dipasang)."
    fi
}

sshd_bin() {
    if command_exists sshd; then command -v sshd
    elif [ -x /usr/sbin/sshd ]; then printf '%s' /usr/sbin/sshd
    else printf ''
    fi
}

# ── 2. Unduh & validasi public key ───────────────────────────────────────────
fetch_keys() {
    local dest="$1"
    log_info "Mengunduh public key: $SSH_KEYS_URL"
    if ! _download_to "$SSH_KEYS_URL" "$dest"; then
        log_error "Gagal mengunduh public key dari $SSH_KEYS_URL"
        return 1
    fi
    # Validasi: minimal satu baris, format key yang dikenal.
    # CATATAN: 'grep -c' mencetak 0 DAN keluar dengan status 1 → jangan pakai
    # '|| echo 0' (bisa menghasilkan dua baris → error aritmetika).
    local ok=""
    ok="$(grep -cE '^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+' "$dest" 2>/dev/null)"
    case "$ok" in ''|*[!0-9]*) ok=0 ;; esac
    if [ "$ok" -lt 1 ]; then
        log_error "File kunci tidak memuat public key OpenSSH yang valid (atau akun GitHub tanpa kunci publik)."
        return 1
    fi
    chmod 600 "$dest" 2>/dev/null || true
    log_ok "$ok public key valid ditemukan."
    return 0
}

# Unduh ke file (tanpa merusak file lama bila gagal).
_download_to() {
    local url="$1" dest="$2" rc=0 apk_url
    apk_url="${url%.keys}.apk"
    if command_exists curl; then
        curl -fsSL --max-time 60 -H 'Accept: application/vnd.github.raw' -o "${dest}.tmp" "$url" || rc=$?
    elif command_exists wget; then
        wget -q -T 60 --header='Accept: application/vnd.github.raw' -O "${dest}.tmp" "$url" || rc=$?
    elif command_exists busybox; then
        busybox wget -q -O "${dest}.tmp" "$url" || rc=$?
    else
        return 127
    fi
    if [ "$rc" -eq 0 ] && [ -s "${dest}.tmp" ]; then
        mv -f "${dest}.tmp" "$dest"
        return 0
    fi
    # Fallback: endpoint .apk GitHub
    rc=0
    rm -f "${dest}.tmp"
    if command_exists curl; then
        curl -fsSL --max-time 60 -o "${dest}.tmp" "$apk_url" || rc=$?
    elif command_exists wget; then
        wget -q -T 60 -O "${dest}.tmp" "$apk_url" || rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ -s "${dest}.tmp" ]; then
        mv -f "${dest}.tmp" "$dest"
        return 0
    fi
    rm -f "${dest}.tmp" 2>/dev/null
    return 1
}

# ── 3. Pasang kunci ke user target ───────────────────────────────────────────
install_keys_for_user() {
    local u="$1" keyfile="$2"
    local home; home="$(home_of "$u")"
    [ -n "$home" ] || { log_warn "Home user '$u' tidak diketahui, dilewati."; return 1; }

    local sshdir="$home/.ssh" ak="$home/.ssh/authorized_keys"
    mkdir -p "$sshdir" 2>/dev/null || { log_warn "Tidak bisa membuat $sshdir"; return 1; }
    touch "$ak" 2>/dev/null || { log_warn "Tidak bisa menulis $ak"; return 1; }

    # Buang kunci yang pernah dikelola (blok penanda) agar tidak menumpuk.
    local tmp="$ak.speedtesttmp.$$"
    if ! awk -v begin="# BEGIN $SSH_MARKER" -v end="# END $SSH_MARKER" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        !skip { print }
    ' "$ak" > "$tmp" 2>/dev/null; then
        cp -f "$ak" "$tmp" 2>/dev/null || : > "$tmp"
    fi
    mv -f "$tmp" "$ak" 2>/dev/null || rm -f "$tmp"

    {
        printf '# BEGIN %s\n' "$SSH_MARKER"
        printf '# Dikelola otomatis oleh speedtest installer — jangan diedit manual.\n'
        printf '# Sumber: %s (diperbarui %s)\n' "$SSH_KEYS_URL" "$(date -Iseconds 2>/dev/null || date)"
        grep -vE '^[[:space:]]*(#|$)' "$keyfile"
        printf '# END %s\n' "$SSH_MARKER"
    } >> "$ak" || { log_warn "Gagal menulis $ak"; return 1; }

    # Permission standar OpenSSH (harus ketat, kalau tidak sshd menolak kunci)
    chmod 700 "$sshdir" 2>/dev/null || true
    chmod 600 "$ak" 2>/dev/null || true
    chown -R "$u":"$u" "$sshdir" 2>/dev/null || chown -R "$(id -u "$u")":"$(id -g "$u")" "$sshdir" 2>/dev/null || true

    # SELinux context (RHEL/CentOS/Alma/Rocky)
    if command_exists restorecon; then
        restorecon -RF "$sshdir" >/dev/null 2>&1 || true
    fi
    log_ok "Public key dipasang untuk user '$u' → $ak"
    return 0
}

# ── 4. Standardisasi sshd ────────────────────────────────────────────────────
backup_sshd_files() {
    local ts bdir
    ts="$(date +%Y%m%d-%H%M%S)"
    bdir="$BASE_DIR/.ssh-backups/$ts"
    mkdir -p "$bdir" 2>/dev/null || return 0
    [ -f "$SSHD_MAIN" ] && cp -p "$SSHD_MAIN" "$bdir/sshd_config" 2>/dev/null || true
    if [ -d "$SSHD_DROPIN_DIR" ]; then
        cp -p "$SSHD_DROPIN_DIR"/*.conf "$bdir/" 2>/dev/null || true
    fi
    printf '%s' "$bdir"
}

restart_sshd() {
    if command_exists systemctl && [ -d /run/systemd/system ]; then
        systemctl reload sshd >/dev/null 2>&1 || systemctl reload ssh >/dev/null 2>&1 \
        || systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
    elif command_exists rc-service; then
        rc-service sshd reload >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || true
    elif command_exists service; then
        service sshd reload >/dev/null 2>&1 || service ssh reload >/dev/null 2>&1 || true
    fi
    # Verifikasi masih listening
    sleep 1
    if command_exists ss; then
        ss -tln 2>/dev/null | grep -qE ':22[[:space:]]' && { log_ok "sshd aktif di port 22."; return 0; }
    elif command_exists netstat; then
        netstat -tln 2>/dev/null | grep -qE ':22[[:space:]]' && { log_ok "sshd aktif di port 22."; return 0; }
    elif command_exists pgrep; then
        pgrep -x sshd >/dev/null 2>&1 && { log_ok "sshd berjalan."; return 0; }
    fi
    log_warn "Tidak bisa memverifikasi status sshd (mungkin berjalan dengan port khusus)."
    return 0
}

sshd_include_supported() {
    [ -f "$SSHD_MAIN" ] || return 1
    grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN"
}

write_sshd_dropin() {
    local bin; bin="$(sshd_bin)"
    [ -n "$bin" ] || { log_warn "sshd tidak terpasang — standardisasi sshd dilewati."; return 1; }

    # Backup
    local bdir; bdir="$(backup_sshd_files)"
    [ -n "$bdir" ] && log_info "Backup konfigurasi SSH: $bdir"

    # Nilai PasswordAuthentication: jangan pernah mengubah ke "no" tanpa izin.
    local passwd_line=""
    if [ "$SSH_DISABLE_PASSWORD_AUTH" = "Ya" ]; then
        passwd_line="PasswordAuthentication no"
        log_warn "SSH_DISABLE_PASSWORD_AUTH=Ya → login password akan dimatikan (pastikan kunci sudah benar-benar bisa dipakai!)."
    fi

    local content
    content="$(cat <<EOF
# Dikelola otomatis oleh speedtest installer (bagian9).
# Jangan diedit manual — perubahan akan ditimpa pada instalasi/update berikutnya.
PermitRootLogin $SSH_ROOT_LOGIN
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
${passwd_line}
EOF
)"

    if sshd_include_supported; then
        mkdir -p "$SSHD_DROPIN_DIR" 2>/dev/null || true
        printf '%s\n' "$content" > "$SSHD_DROPIN" || { log_warn "Gagal menulis $SSHD_DROPIN"; return 1; }
        chmod 600 "$SSHD_DROPIN" 2>/dev/null || true
        if "$bin" -t >/dev/null 2>&1; then
            log_ok "Konfigurasi sshd (drop-in) valid: $SSHD_DROPIN"
            restart_sshd
            return 0
        fi
        log_error "Validasi sshd -t GAGAL dengan drop-in. Rollback..."
        rm -f "$SSHD_DROPIN" 2>/dev/null || true
        "$bin" -t >/dev/null 2>&1 && log_ok "Konfigurasi lama tetap utuh (rollback berhasil)."
        return 1
    fi

    # Fallback: sunting sshd_config utama secara idempotent
    local tmp="$SSHD_MAIN.speedtesttmp.$$"
    cp -p "$SSHD_MAIN" "$tmp" 2>/dev/null || { log_warn "Tidak bisa menyalin $SSHD_MAIN"; return 1; }
    apply_kv() {
        local key="$1" val="$2" f="$3"
        if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$f" 2>/dev/null; then
            sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$f"
        else
            printf '%s %s\n' "$key" "$val" >> "$f"
        fi
    }
    apply_kv "PermitRootLogin" "$SSH_ROOT_LOGIN" "$tmp"
    apply_kv "PubkeyAuthentication" "yes" "$tmp"
    apply_kv "AuthorizedKeysFile" ".ssh/authorized_keys" "$tmp"
    [ -n "$passwd_line" ] && apply_kv "PasswordAuthentication" "no" "$tmp"

    mv -f "$tmp" "$SSHD_MAIN" 2>/dev/null || { log_warn "Gagal menerapkan perubahan sshd_config"; return 1; }
    if "$bin" -t >/dev/null 2>&1; then
        log_ok "Konfigurasi sshd valid (file utama)."
        restart_sshd
        return 0
    fi
    log_error "Validasi sshd -t GAGAL. Restore backup terbaru..."
    local latest
    latest="$(ls -1dt "$BASE_DIR"/.ssh-backups/*/ 2>/dev/null | head -1)"
    if [ -n "$latest" ] && [ -f "$latest/sshd_config" ]; then
        cp -f "$latest/sshd_config" "$SSHD_MAIN" 2>/dev/null || true
        log_ok "sshd_config dipulihkan dari $latest"
    else
        log_error "Tidak ada backup untuk dipulihkan — periksa manual segera! Backup: $SSHD_MAIN.speedtesttmp.* dihapus."
    fi
    return 1
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
ensure_sshd

KEY_TMP="$TMP_DIR/smahud.keys"
if fetch_keys "$KEY_TMP"; then
    :
else
    die "Tidak bisa melanjutkan bagian9: public key gagal diunduh/diverifikasi."
fi

INSTALLED_ANY=0
for u in $SSH_TARGET_USERS; do
    if user_exists "$u"; then
        install_keys_for_user "$u" "$KEY_TMP" && INSTALLED_ANY=1
    else
        log_warn "User '$u' tidak ada di sistem, dilewati."
    fi
done

[ "$INSTALLED_ANY" -eq 1 ] || log_warn "Tidak ada user target yang berhasil dipasangi kunci."

if [ "$SSH_MANAGE_SSHD" = "Ya" ]; then
    write_sshd_dropin || log_warn "Standardisasi sshd tidak sepenuhnya berhasil, lanjut..."
else
    log_info "SSH_MANAGE_SSHD=Tidak → konfigurasi sshd tidak diubah."
fi

rm -f "$KEY_TMP" 2>/dev/null || true
log_ok "Bagian 9 selesai (akses SSH via public key siap)."
