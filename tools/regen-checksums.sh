#!/usr/bin/env bash
###############################################################################
# tools/regen-checksums.sh — (MAINTAINER) Membangun ulang MANIFEST,
# checksums.sha256, dan pasangan <file>.sha256 untuk setiap file terkelola.
#
# WAJIB dijalankan setiap kali Anda mengubah file di repo, lalu commit hasilnya.
#
#   bash tools/regen-checksums.sh            # dari root repo
#
# File .sha256 inilah yang diverifikasi oleh self-update di sisi server
# (speedtest-selfupdate.sh / install.sh). Tanpa file ini, verifikasi dilewati
# dan update tetap berjalan dengan mode "uji sintaks saja".
###############################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$REPO_ROOT"

# Daftar file terkelola — HARUS SAMA dengan SUPPORT_FILES di install.sh dan
# au_support_files_default() di auto_update_lib.sh.
MANAGED_FILES="
VERSION
MANIFEST
checksums.sha256
speedtest-repo.conf
common_functions1.sh
auto_update_lib.sh
bagian0.sh
bagian1_install_dependency.sh
bagian2_install_ooklaserver.sh
bagian3_install_certbot.sh
bagian4_install_server_certificate.sh
bagian5_update_ooklaserver.sh
bagian6_automaintenance.sh
bagian7_network.sh
bagian8_cek_konfigurasi.sh
bagian9_ssh_access.sh
bagian10_hosts_ssh.sh
bagian11_self_update.sh
install.sh
ooklaserver.sh
uninstall.sh
speedtest-selfupdate.sh
"

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "[ERROR] sha256sum tidak tersedia." >&2
  exit 1
fi

missing=""
for f in $MANAGED_FILES; do
  case "$f" in checksums.sha256|MANIFEST) continue ;; esac
  [ -f "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  echo "[ERROR] File berikut belum ada:$missing" >&2
  echo "        Buat dulu, atau sesuaikan daftar MANAGED_FILES." >&2
  exit 1
fi

echo "[INFO] Membersihkan hash lama..."
rm -f ./*.sha256 2>/dev/null || true

echo "[INFO] Menulis MANIFEST..."
# shellcheck disable=SC2086  # daftar file memang dipisah spasi/baris
printf '%s\n' $MANAGED_FILES > MANIFEST

echo "[INFO] Menghitung SHA-256 per file..."
: > checksums.sha256
for f in $MANAGED_FILES; do
  case "$f" in checksums.sha256) continue ;; esac
  [ -f "$f" ] || continue
  h="$(sha256sum "$f" | awk '{print $1}')"
  printf '%s  %s\n' "$h" "$f" >> checksums.sha256
  printf '%s\n' "$h" > "$f.sha256"     # dipakai verifikasi per-file saat sync
done
# checksums.sha256 sendiri tidak di-hash (self-reference).
[ -f "checksums.sha256.sha256" ] && rm -f "checksums.sha256.sha256"

echo "[OK] Selesai. File yang dihasilkan:"
echo "     - MANIFEST"
echo "     - checksums.sha256"
echo "     - <file>.sha256 (satu per file terkelola)"
echo
echo "Langkah berikutnya:"
echo "  1. Naikkan VERSION (mis. 8.0.1)"
echo "  2. bash tools/regen-checksums.sh   # ulangi setelah VERSION diubah"
echo "  3. bash tools/publish-version.sh   # salin snapshot ke versions/<VERSION>/"
echo "  4. git add -A && git commit -m 'release v<X.Y.Z>' && git push"
