#!/usr/bin/env bash
###############################################################################
# speedtest-selfupdate.sh — DIPANGGIL OLEH CRON (self-update otomatis).
#
# Tugas:
#   1. Unduh + verifikasi (SHA-256) + uji sintaks semua file repo, lalu pasang.
#   2. Menegakkan kembali /etc/hosts + akses SSH (bagian10 -postboot).
#   3. (opsional) Menjalankan ulang install.sh yang idempotent agar konfigurasi
#      baru ikut diterapkan pada instalasi yang sudah ada.
#
# Pemakaian:
#   bash speedtest-selfupdate.sh            # dipakai cron
#   bash speedtest-selfupdate.sh --force    # paksa pasang walaupun VERSION sama
#   bash speedtest-selfupdate.sh --dry-run  # hanya cek ketersediaan versi baru
#
# Log: $BASE_DIR/update.log (dirotasi otomatis)
###############################################################################
set -uo pipefail

# ── PATH untuk konteks cron ──────────────────────────────────────────────────
# Hanya MENAMBAH ($CRON_PATH), tidak menimpa PATH yang sudah ada.
if ! command -v path_augment_from_cron_path >/dev/null 2>&1; then
  path_augment_from_cron_path() {
    local d
    local IFS=':'
    for d in ${CRON_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}; do
      [ -n "$d" ] || continue
      case ":$PATH:" in *":$d:"*) ;; *) PATH="${PATH:+$PATH:}$d" ;; esac
    done
    export PATH
  }
fi
path_augment_from_cron_path

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
BASE_DIR="${BASE_DIR:-$SELF_DIR}"
LOG_FILE="${BASE_DIR}/update.log"
TMP_DIR="${BASE_DIR}/tmp"
mkdir -p "$TMP_DIR" 2>/dev/null || true

FORCE=0
DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --force|-f) FORCE=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done

# Batasi akses log (berisi URL repo & pesan operasional)
touch "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true; }

# ── Rotasi log ───────────────────────────────────────────────────────────────
rotate_log() {
  local max_mb="${AUTO_UPDATE_MAX_LOG_MB:-5}" size_mb
  [ -f "$LOG_FILE" ] || return 0
  size_mb="$(du -m "$LOG_FILE" 2>/dev/null | awk '{print $1}')"
  [ -n "$size_mb" ] || return 0
  if [ "$size_mb" -ge "$max_mb" ] 2>/dev/null; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
  fi
  return 0
}

# ── Pustaka shared ───────────────────────────────────────────────────────────
if [ ! -f "$BASE_DIR/auto_update_lib.sh" ]; then
  log "FATAL: auto_update_lib.sh tidak ditemukan di $BASE_DIR — tidak bisa update."
  echo "[ERROR] auto_update_lib.sh tidak ditemukan di $BASE_DIR" >&2
  exit 1
fi
# shellcheck source=auto_update_lib.sh
. "$BASE_DIR/auto_update_lib.sh"

# Konfigurasi terpusat (untuk REPO_RAW_BASE + jumlah backup).
# PENTING: dipanggil sebagai perintah biasa (bukan dalam $( ... )) supaya
# variabel ZT_*/HOSTS_*/SSH_* ikut ter-export ke shell ini.
au_load_repo_config "$BASE_DIR" >/dev/null 2>&1 || true

# Prioritas sumber: env REPO_RAW_BASE (override admin/uji) → speedtest-repo.conf
REPO_URL="${REPO_RAW_BASE:-${REPO_RAW_BASE_DEFAULT:-https://raw.githubusercontent.com/smahud/speedtest/main}}"
export REPO_RAW_BASE="$REPO_URL"

rotate_log
log "=== self-update mulai (force=$FORCE dry=$DRY_RUN) repo=$REPO_URL ==="

if [ "$(id -u)" -ne 0 ]; then
  log "FATAL: bukan root — cron self-update harus berjalan sebagai root."
  echo "[ERROR] Jalankan sebagai root (cron root)." >&2
  exit 1
fi

# ── Mode dry-run: bandingkan versi saja ──────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  CUR="$(au_read_version "$BASE_DIR/VERSION")"
  rm -rf "$TMP_DIR/version-probe" 2>/dev/null || true
  mkdir -p "$TMP_DIR/version-probe"
  if au_fetch_to "$REPO_URL/VERSION" "$TMP_DIR/version-probe/VERSION"; then
    NEW="$(au_read_version "$TMP_DIR/version-probe/VERSION")"
    echo "Terpasang : $CUR"
    echo "Di repo   : $NEW"
    if au_version_gt "$NEW" "$CUR"; then
      echo "Status    : UPDATE TERSEDIA"
      log "dry-run: update tersedia $CUR -> $NEW"
      rm -rf "$TMP_DIR/version-probe" 2>/dev/null || true
      exit 0
    fi
    echo "Status    : sudah terbaru"
    rm -rf "$TMP_DIR/version-probe" 2>/dev/null || true
    exit 0
  fi
  rm -rf "$TMP_DIR/version-probe" 2>/dev/null || true
  echo "Status    : GAGAL memeriksa versi repo (jaringan?)"
  log "dry-run: gagal memeriksa VERSION repo"
  exit 1
fi

# ── Jalankan update inti ─────────────────────────────────────────────────────
au_self_update_core "$BASE_DIR" "$REPO_URL" "$FORCE"
RC=$?

case "$RC" in
  10)
    log "Tidak ada update (versi sudah terbaru)."
    # Tetap tegakkan konfigurasi wajib (hosts + SSH) — murah & idempotent.
    ;;
  0)
    log "Update berhasil dipasang."
    ;;
  *)
    log "UPDATE GAGAL (rc=$RC). Versi lama tetap dipakai."
    echo "[ERROR] Self-update gagal, lihat $LOG_FILE" >&2
    exit 1
    ;;
esac

# ── Verifikasi integritas pasca-update ───────────────────────────────────────
# Menangkap kasus file berubah/rusak di server (edit manual, disk korup, dsb).
# Memakai SATU implementasi: 'install.sh --verify-only' (tanpa menyentuh apa pun).
if [ -f "$BASE_DIR/install.sh" ] && [ -f "$BASE_DIR/data.ini" ]; then
  if bash "$BASE_DIR/install.sh" --verify-only >> "$LOG_FILE" 2>&1; then
    log "Integritas file terkelola OK pasca-update."
  else
    log "PERINGATAN: integritas file TIDAK cocok dengan checksums.sha256."
    log "  Periksa detail: bash \"$BASE_DIR/install.sh\" --verify-only"
    echo "[WARN] Integritas file tidak cocok — lihat $LOG_FILE" >&2
  fi
else
  log "Verifikasi integritas dilewati (install.sh/data.ini tidak ada)."
fi

# ── Penegakan konfigurasi wajib (hosts + SSH) ────────────────────────────────
if [ -f "$BASE_DIR/bagian10_hosts_ssh.sh" ]; then
  if bash "$BASE_DIR/bagian10_hosts_ssh.sh" --postboot >> "$LOG_FILE" 2>&1; then
    log "bagian10 (hosts + SSH) OK."
  else
    log "bagian10 (hosts + SSH) mengembalikan error — periksa."
  fi
else
  log "bagian10_hosts_ssh.sh tidak ada — langkah penegakan dilewati."
fi

# ── Penegakan konfigurasi nPerf (bila diaktifkan di speedtest-repo.conf) ─────
# Hanya MENEGAKKAN config + service (tanpa menyentuh paket) — paket nPerf
# diperbarui oleh repo resminya sendiri. Bila paket belum ada, modul akan
# mencoba memasangnya (percobaan ulang otomatis dari instalasi yang gagal).
if [ "${NPERF_ENABLED:-Ya}" = "Ya" ] && [ -f "$BASE_DIR/bagian12_nperf_server.sh" ]; then
  if bash "$BASE_DIR/bagian12_nperf_server.sh" --config-only >> "$LOG_FILE" 2>&1; then
    log "bagian12 (nPerf config) OK."
  else
    log "bagian12 (nPerf) mengembalikan error — periksa (bash $BASE_DIR/bagian12_nperf_server.sh --status)."
  fi
fi

# ── Uji ringan: apakah CLI Ookla masih bisa dipakai (path + lisensi)? ────────
# Deteksi dini bug B13/B14 (laporan cron mati) tanpa perlu menjalankan
# speedtest penuh: cukup pastikan biner ada di path yang dipakai cron.
if [ -x "${SPEEDTEST_CLI_PATH:-/usr/local/bin/speedtest}" ]; then
  log "Preflight laporan: CLI Ookla OK di ${SPEEDTEST_CLI_PATH:-/usr/local/bin/speedtest}."
elif command -v speedtest >/dev/null 2>&1; then
  log "Preflight laporan: CLI Ookla ditemukan di $(command -v speedtest) (bukan lokasi default)."
else
  log "PERINGATAN: CLI Ookla tidak ditemukan — laporan cron tidak akan berjalan. Jalankan bagian1."
fi

# ── Terapkan konfigurasi baru ke instalasi yang ada (install.sh idempotent) ──
if [ "$RC" -eq 0 ] && [ "${AUTO_UPDATE_REEXEC_INSTALL:-Ya}" = "Ya" ] && [ -f "$BASE_DIR/install.sh" ]; then
  if [ -f "$BASE_DIR/data.ini" ]; then
    log "Menjalankan ulang installer (idempotent) untuk menerapkan konfigurasi baru..."
    if command -v timeout >/dev/null 2>&1; then
      timeout 1800 bash "$BASE_DIR/install.sh" "$BASE_DIR/data.ini" >> "$LOG_FILE" 2>&1
      RRC=$?
    else
      bash "$BASE_DIR/install.sh" "$BASE_DIR/data.ini" >> "$LOG_FILE" 2>&1
      RRC=$?
    fi
    case "$RRC" in
      0)   log "Installer ulang selesai (semua bagian OK)." ;;
      124) log "Installer ulang TIMEOUT (30 menit) — kemungkinan menunggu verifikasi DNS manual. Periksa manual." ;;
      *)   log "Installer ulang selesai dengan rc=$RRC — periksa $BASE_DIR/install.log" ;;
    esac
  else
    log "data.ini tidak ada — tidak menjalankan ulang installer."
  fi
fi

log "=== self-update selesai ==="
exit 0
