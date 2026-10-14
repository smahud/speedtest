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

# Nilai dari data.ini (load_and_validate_config).
Domain="${Domain:-}"

log_info "== Bagian 5: Update OoklaServer & Sertifikat =="

[ -f "$OOKLA_PROPERTIES" ] || die "OoklaServer.properties tidak ditemukan di $OOKLA_PROPERTIES"

CERT_FULLCHAIN="${CERT_LIVE_DIR:-/etc/letsencrypt/live}/$Domain/fullchain.pem"
CERT_PRIVKEY="${CERT_LIVE_DIR:-/etc/letsencrypt/live}/$Domain/privkey.pem"

# Hentikan server bila sedang berjalan (memakai script instalasi yang benar).
log_info "Menghentikan OoklaServer (jika berjalan)..."
( cd "$BASE_DIR" && "$OOKLA_SCRIPT" stop ) >/dev/null 2>&1 || true
# Pengaman tambahan bila masih ada proses tertinggal. Urutan upaya dari yang
# paling tepat sasaran ke paling kasar — pola '-f OoklaServer' yang generik bisa
# menumbuk proses lain milik operator, jadi dipakai paling akhir (dan hanya
# lewat path absolut biner kita).
if pgrep -x "OoklaServer" >/dev/null 2>&1; then
    OOKLA_STOP_PID=""
    if [ -f "${OOKLA_PIDFILE:-}" ]; then
        OOKLA_STOP_PID="$(head -n 1 "$OOKLA_PIDFILE" 2>/dev/null | tr -d '[:space:]')"
        case "$OOKLA_STOP_PID" in ''|*[!0-9]*) OOKLA_STOP_PID="" ;; esac
    fi
    if [ -n "$OOKLA_STOP_PID" ] && kill -0 "$OOKLA_STOP_PID" 2>/dev/null; then
        kill "$OOKLA_STOP_PID" 2>/dev/null || true
    elif command_exists pkill; then
        pkill -x "OoklaServer" 2>/dev/null || true
    fi
    sleep 2
    if pgrep -x "OoklaServer" >/dev/null 2>&1; then
        pkill -f "$OOKLA_BIN" 2>/dev/null || true
        sleep 1
    fi
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

# --- Aktifkan Logging ke File (Optimalisasi) ---
if ! grep -q "logging.channels.c1.class = FileChannel" "$OOKLA_PROPERTIES" 2>/dev/null; then
    cat >> "$OOKLA_PROPERTIES" <<EOF

# Logging Configuration
logging.channels.c1.class = FileChannel
logging.channels.c1.path = $BASE_DIR/OoklaServer.log
logging.channels.c1.formatter.class = PatternFormatter
logging.channels.c1.formatter.pattern = %Y-%m-%d %H:%M:%S [%P - %I] [%p] %t
logging.loggers.root.channel = c1
logging.loggers.root.level = information
EOF
fi

# --- Start/restart memakai script lokal (TANPA re-download biner) -------------
# Biner sudah dipasang di bagian2; cukup restart agar konfigurasi cert dibaca.
log_info "Menjalankan OoklaServer dengan konfigurasi sertifikat baru..."
( cd "$BASE_DIR" && "$OOKLA_SCRIPT" restart ) || die "Gagal me-restart OoklaServer."

# Bersihkan file sisa di BASE_DIR (bukan CWD).
rm -f "$BASE_DIR/OoklaServer.properties.default" 2>/dev/null || true

# ── Verifikasi END-TO-END: HTTP + TLS ke server lokal ───────────────────────
# Menjawab bug B18: sebelumnya installer menyatakan sukses tanpa pernah
# memastikan endpoint benar-benar melayani HTTPS dengan sertifikat yang cocok.
# Pemeriksaan ini bersifat WARN (non-fatal) kecuali TLS_VERIFY_STRICT="Ya".
verify_endpoint() {
  [ "${TLS_VERIFY_ENABLED:-Ya}" = "Ya" ] || { log_info "TLS_VERIFY_ENABLED=Tidak → verifikasi endpoint dilewati."; return 0; }

  local ports port http_code="" http_port="" tls_port="" seen=""
  ports="$(ookla_props_ports "$OOKLA_PROPERTIES")"
  if [ -z "$ports" ]; then ports="8080 5060"; fi

  # 1) Server benar-benar menjawab HTTP?
  for port in $ports; do
    http_code="$(endpoint_http_probe "$port" 2>/dev/null || true)"
    if [ -n "$http_code" ]; then http_port="$port"; break; fi
  done
  if [ -n "$http_port" ]; then
    log_ok "Endpoint HTTP lokal menjawab (127.0.0.1:$http_port → HTTP $http_code)."
  else
    log_warn "Tidak ada port OoklaServer ($ports) yang menjawab HTTP — cek proses/log OoklaServer."
  fi

  # 2) HTTPS benar-benar melayani sertifikat domain ini? (uji beberapa kandidat
  #    port: 443, 8443, 5061, 5060 + port yang dikonfigurasi)
  for port in 443 8443 5061 5060 $ports; do
    case " $seen " in *" $port "*) continue ;; esac
    seen="$seen $port"
    if endpoint_tls_probe "$Domain" "$port" 2>/dev/null; then tls_port="$port"; break; fi
  done
  if [ -n "$tls_port" ]; then
    log_ok "TLS terverifikasi: 127.0.0.1:$tls_port melayani sertifikat valid untuk '$Domain'."
    return 0
  fi

  log_warn "TLS ke 127.0.0.1 belum terverifikasi untuk '$Domain' (port kandidat: 443/8443/5061/5060/$ports)."
  log_warn "  Uji manual: openssl s_client -connect 127.0.0.1:443 -servername $Domain </dev/null | grep 'Verify return'"
  if [ "${TLS_VERIFY_STRICT:-Tidak}" = "Ya" ]; then
    log_error "TLS_VERIFY_STRICT=Ya → instalasi dihentikan karena TLS tidak terverifikasi."
    return 1
  fi
  return 0
}
verify_endpoint || die "Verifikasi endpoint TLS gagal (TLS_VERIFY_STRICT=Ya)."

log_ok "Bagian 5 selesai (OoklaServer berjalan kembali)."
