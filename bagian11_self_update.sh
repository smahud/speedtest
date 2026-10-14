#!/usr/bin/env bash
###############################################################################
# bagian11_self_update.sh
#   - Memasang/memperbarui cron SELF-UPDATE otomatis (idempotent).
#   - Memasang cron boot-sync (bagian10 -postboot) agar /etc/hosts & akses SSH
#     selalu ditegakkan setelah reboot.
#   - Menyiapkan rotasi log update.
#
# Cron yang Dipasang:
#   <M> <H> * * *  bash $BASE_DIR/speedtest-selfupdate.sh      → cek & update repo
#   @reboot        bash $BASE_DIR/bagian10_hosts_ssh.sh -postboot  → tegakkan config
###############################################################################
set -uo pipefail
SPEEDTEST_SCRIPT_DIR="${SPEEDTEST_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)}"
export SPEEDTEST_SCRIPT_DIR
# shellcheck source=common_functions1.sh
. "$SPEEDTEST_SCRIPT_DIR/common_functions1.sh"

if [ -z "${BASE_DIR:-}" ]; then
  resolve_config_path "${1:-}"; init_paths; detect_os; load_and_validate_config
fi

log_info "== Bagian 11: Self-update otomatis (cron) =="

SELFUPDATE_SCRIPT="$BASE_DIR/speedtest-selfupdate.sh"
POSTBOOT_SCRIPT="$BASE_DIR/bagian10_hosts_ssh.sh"
NETWORK_SCRIPT="$BASE_DIR/bagian7_network.sh"

AUTO_UPDATE_ENABLED="${AUTO_UPDATE_ENABLED:-Ya}"
AUTO_UPDATE_SCHEDULE_MIN="${AUTO_UPDATE_SCHEDULE_MIN:-17}"
AUTO_UPDATE_SCHEDULE_HOUR="${AUTO_UPDATE_SCHEDULE_HOUR:-3}"
CRON_TAG="# speedtest-autoupdate (managed)"
BOOT_TAG="# speedtest-boot-sync (managed)"
NAT_TAG="# speedtest-zt-nat-restore (managed)"

if ! command_exists crontab; then
  log_warn "crontab tidak tersedia — self-update otomatis dilewati."
  log_warn "Anda tetap bisa update manual: bash $SELFUPDATE_SCRIPT"
  exit 0
fi

# ── Penulisan cron memakai helper generik (common_functions1.sh) ─────────────
# cron_apply()/cron_clear() membuang baris tag + baris perintah kita (termasuk
# format lama seperti 'speedtest-zt-nat-restore') dalam satu pass awk, selalu
# status 0 (aman untuk 'set -e'), dan tidak mungkin mengosongkan crontab karena
# redirect salah tempat.
if [ "$AUTO_UPDATE_ENABLED" = "Ya" ]; then
  [ -f "$SELFUPDATE_SCRIPT" ] || log_warn "$SELFUPDATE_SCRIPT tidak ditemukan (akan ada setelah self-update pertama)."
  [ -f "$POSTBOOT_SCRIPT" ] || log_warn "$POSTBOOT_SCRIPT tidak ditemukan (boot-sync tidak akan berjalan)."
  chmod a+x "$SELFUPDATE_SCRIPT" "$POSTBOOT_SCRIPT" "$NETWORK_SCRIPT" 2>/dev/null || true

  if cron_apply "$CRON_TAG" \
       "$AUTO_UPDATE_SCHEDULE_MIN $AUTO_UPDATE_SCHEDULE_HOUR * * * bash $SELFUPDATE_SCRIPT >/dev/null 2>&1" \
     && cron_apply "$BOOT_TAG" \
       --purge "$NAT_TAG" --purge "$NETWORK_SCRIPT -postboot" --purge "$NETWORK_SCRIPT --postboot" \
       --purge "$POSTBOOT_SCRIPT -postboot" \
       "@reboot bash $POSTBOOT_SCRIPT --postboot >/dev/null 2>&1"; then
    log_ok "Self-update otomatis aktif: setiap hari pukul ${AUTO_UPDATE_SCHEDULE_HOUR}:$(printf '%02d' "$AUTO_UPDATE_SCHEDULE_MIN")"
    log_ok "Boot-sync aktif: @reboot → $POSTBOOT_SCRIPT --postboot (hosts + SSH + NAT ZeroTier)"
  else
    log_warn "Gagal memasang cron self-update."
  fi
else
  if cron_clear "$CRON_TAG" "$SELFUPDATE_SCRIPT" \
     && cron_clear "$BOOT_TAG" "$POSTBOOT_SCRIPT -postboot" "$POSTBOOT_SCRIPT --postboot"; then
    log_info "AUTO_UPDATE_ENABLED=Tidak → cron self-update & boot-sync lama dihapus."
  fi
fi

# ── Info rotasi log (dilakukan di dalam speedtest-selfupdate.sh) ──────────────
log_info "Rotasi update.log: otomatis saat file > ${AUTO_UPDATE_MAX_LOG_MB:-5} MB."

log_ok "Bagian 11 selesai."
