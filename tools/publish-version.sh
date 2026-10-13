#!/usr/bin/env bash
###############################################################################
# tools/publish-version.sh — (MAINTAINER) Membuat snapshot rilis imutabel.
#
#   bash tools/publish-version.sh
#
# Snapshot disalin ke  versions/<VERSION>/  agar install.sh & self-update bisa
# memakai sumber yang TIDAK berubah-ubah (tidak terpengaruh commit berikutnya
# di branch main). Ini yang membuat update server bisa di-rollback: cukup ubah
# VERSION (turunkan) atau arahkan REPO_RAW_BASE ke versions/<versi-lama>.
#
# Jalankan SETELAH tools/regen-checksums.sh dan SETELAH VERSION dinaikkan.
###############################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$REPO_ROOT"

if [ ! -f VERSION ]; then
  echo "[ERROR] VERSION tidak ditemukan." >&2
  exit 1
fi
VER="$(head -1 VERSION | tr -d '[:space:]')"
if [ -z "$VER" ]; then
  echo "[ERROR] VERSION kosong." >&2
  exit 1
fi

if [ ! -f MANIFEST ]; then
  echo "[ERROR] MANIFEST belum ada — jalankan dulu: bash tools/regen-checksums.sh" >&2
  exit 1
fi

DEST="versions/$VER"
mkdir -p "$DEST"

count=0
while IFS= read -r f; do
  case "$f" in ''|\#*) continue ;; esac
  if [ ! -f "$f" ]; then
    echo "[WARN] Dilewati (tidak ada): $f"
    continue
  fi
  cp -f "$f" "$DEST/$f"
  count=$((count + 1))
done < MANIFEST

echo "[OK] Snapshot v$VER dibuat di $DEST ($count file)."
echo
echo "Langkah berikutnya:"
echo "  git add -A && git commit -m 'release v$VER' && git push"
echo
echo "Catatan: install.sh memakai  versions/<VERSION>/  secara otomatis bila"
echo "         VERSION di $REPO_ROOT bisa dibaca dan snapshot-nya tersedia."
