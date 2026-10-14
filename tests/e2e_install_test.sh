#!/usr/bin/env bash
###############################################################################
# tests/e2e_install_test.sh — Uji END-TO-END installer di lingkungan MOCK.
#
# TIDAK menyentuh sistem Anda:
#   - seluruh uji berjalan di dalam user+mount namespace
#     (unshare -rm --map-root-user), tanpa akses root nyata
#   - /etc/hosts, /etc/ssh, /root, /usr/local/bin, /usr/sbin, /etc/letsencrypt,
#     /etc/sysctl.d di-BIND MOUNT ke direktori sementara
#   - semua tool sistem (apt-get, systemctl, iptables, certbot, crontab,
#     zerotier-cli, sshd, speedtest, ...) diganti SHIM terkendali
#   - "repo" disajikan via file:// dari salinan lokal (tanpa menyentuh GitHub)
#
# Cakupan: instalasi penuh, entri /etc/hosts, kunci SSH + sshd, cron
#          (self-update/boot-sync/NAT/report/restart), self-update otomatis
#          (VERSION naik + backup + checksum), idempotensi, dan sifat WAJIB
#          ZeroTier (gagal bila belum di-authorize).
#
# Pemakaian:  bash tests/e2e_install_test.sh
#
# CATATAN SHELLCHECK: harness ini sengaja banyak memakai blok berkutip tunggal
# (SC2016) karena isi blok tersebut dievaluasi BELAKANGAN oleh fungsi check()
# dengan $WORK / $REPO_ROOT pada posisi tertentu — bukan sekarang. Pola 'ls'
# (SC2012) dan pemisahan kata daftar file (SC2086) juga disengaja.
# Skrip PRODUKSI (install.sh, bagian*.sh, uninstall.sh, common_functions1.sh,
# auto_update_lib.sh, speedtest-selfupdate.sh) harus tetap bersih tanpa
# pengecualian ini.
# shellcheck disable=SC2016,SC2012,SC2086,SC1012,SC1078,SC1079
###############################################################################
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
WORK="${WORK:-/tmp/st-e2e}"
MANAGED_LIST="VERSION MANIFEST checksums.sha256 speedtest-repo.conf common_functions1.sh
auto_update_lib.sh bagian0.sh bagian1_install_dependency.sh bagian2_install_ooklaserver.sh
bagian3_install_certbot.sh bagian4_install_server_certificate.sh bagian5_update_ooklaserver.sh
bagian6_automaintenance.sh bagian7_network.sh bagian8_cek_konfigurasi.sh
bagian9_ssh_access.sh bagian10_hosts_ssh.sh bagian11_self_update.sh
install.sh ooklaserver.sh uninstall.sh speedtest-selfupdate.sh"

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

if ! unshare -rm --map-root-user true 2>/dev/null; then
  echo "[SKIP] unshare --map-root-user tidak tersedia di lingkungan ini."
  exit 0
fi

echo "=== Uji E2E installer (mock environment) ==="
echo "repo : $REPO_ROOT"
echo "work : $WORK"

# ── Kunci anti-tumpang-tindih ────────────────────────────────────────────────
# Dua uji E2E yang berjalan bersamaan akan saling menghapus isi $WORK (mock
# /usr/sbin, dsb) dan menghasilkan kegagalan yang menyesatkan.
LOCK_FILE="${WORK}.lock"
if [ -f "$LOCK_FILE" ]; then
  OTHER_PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [ -n "$OTHER_PID" ] && kill -0 "$OTHER_PID" 2>/dev/null; then
    echo "[SKIP] Uji E2E lain masih berjalan (PID $OTHER_PID)."
    echo "       Hentikan dulu (kill $OTHER_PID) atau pakai WORK lain, mis:"
    echo "       WORK=/tmp/st-e2e-2 bash tests/e2e_install_test.sh"
    exit 3
  fi
fi
printf '%s\n' "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

rm -rf "$WORK"
mkdir -p "$WORK"/{base,repo,shims,rootfs,localbin,etc_hosts_dir,usr_sbin_fake}

# CRON_PATH untuk uji: shims diletakkan paling depan (di server nyata isinya
# /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin — lihat
# speedtest-repo.conf). Wrapper cron memakai PATH="$CRON_PATH".
export CRON_PATH="$WORK/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Salinan /etc → di-bind mount ke /etc di dalam namespace sehingga semua file
# sistem (/etc/hosts, /etc/ssh, /etc/letsencrypt, /etc/sysctl.d) bisa ditulis
# tanpa menyentuh sistem nyata.
cp -R /etc "$WORK/etc" 2>/dev/null || true
mkdir -p "$WORK/etc/letsencrypt" "$WORK/etc/ssh/sshd_config.d" "$WORK/etc/sysctl.d" 2>/dev/null || true
cat > "$WORK/etc/ssh/sshd_config" <<'EOF'
# mock sshd_config
Include /etc/ssh/sshd_config.d/*.conf
PermitRootLogin yes
EOF

cat > "$WORK/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 mockhost
# entri pengguna lain yang WAJIB tetap ada
192.168.1.50 fileserver.local
EOF

# ── Banu: hitung ulang hash repo mock ────────────────────────────────────────
rehash_mock_repo() {
  ( cd "$WORK/repo" || exit 1
    rm -f ./*.sha256 2>/dev/null
    : > checksums.sha256
    while IFS= read -r f; do
      case "$f" in ''|\#*) continue ;; esac
      [ -f "$f" ] || continue
      if [ "$f" = "checksums.sha256" ]; then continue; fi
      h="$(sha256sum "$f" | awk '{print $1}')"
      printf '%s  %s\n' "$h" "$f" >> checksums.sha256
      printf '%s\n' "$h" > "$f.sha256"
    done < MANIFEST )
}

# ── 0. "Repo" mock ───────────────────────────────────────────────────────────
for f in $MANAGED_LIST; do
  [ -f "$REPO_ROOT/$f" ] && cp -f "$REPO_ROOT/$f" "$WORK/repo/$f"
done
mkdir -p "$WORK/repo/zerotier" "$WORK/repo/tools"
printf '%s\n' $MANAGED_LIST > "$WORK/repo/MANIFEST"
rehash_mock_repo

# Direktori pengguna: data.ini + install.sh (seperti hasil wget/ekstrak tarball)
for f in $MANAGED_LIST; do
  [ -f "$WORK/repo/$f" ] && cp -f "$WORK/repo/$f" "$WORK/base/$f"
done

# ── 1. data.ini ──────────────────────────────────────────────────────────────
cat > "$WORK/base/data.ini" <<'EOF'
ApakahDomainWildcard="Tidak"
ApakahPakaiCloudflare="Ya"
Domain="speedtest.example.com"
APICloudFlare="dummytoken0123456789abcdef"
RegisteredSpeedtestURL="speedtest.example.com"
EmailCloudFlare=""
EOF

# ── 2. SHIM semua tool sistem ────────────────────────────────────────────────
mk() { printf '#!/bin/sh\n%s\n' "$2" > "$WORK/shims/$1"; chmod +x "$WORK/shims/$1"; }
for t in apt-get apt dpkg dnf yum apk zypper systemctl rc-service rc-update service \
         update-rc.d ufw firewall-cmd restorecon git sed_guard; do
  mk "$t" 'exit 0'
done

cat > "$WORK/shims/sysctl" <<'EOF'
#!/bin/sh
# Shim sysctl BERSTATUS (meniru kernel): installer menulis nilai lalu membacanya
# kembali untuk verifikasi IP forwarding. Tanpa state, verifikasi ini akan
# selalu "gagal" di sandbox (padahal di server nyata nilainya benar-benar 1).
STORE="${E2E_SYSCTL_STORE:-/tmp/st-e2e/sysctl.store}"
case "$1" in
  -w) printf '%s\n' "${2#*=}" > "$STORE" 2>/dev/null; exit 0 ;;
  -n) [ -r "$STORE" ] && cat "$STORE"; exit 0 ;;
  -p) f="$2"; v="1"
      [ -n "$f" ] && [ -r "$f" ] && v="$(sed -n 's/^[^=]*=//p' "$f" | head -n 1)"
      printf '%s\n' "$v" > "$STORE" 2>/dev/null; exit 0 ;;
esac
[ -r "$STORE" ] && cat "$STORE" || echo 0
EOF
chmod +x "$WORK/shims/sysctl"

cat > "$WORK/shims/iptables" <<'EOF'
#!/bin/sh
# Shim iptables — meniru perilaku NYATA:
#   * '-C' berhasil setelah '-A' (rule disimpan di file)
#   * '-D' menghapus SATU rule pertama yang cocok (seperti iptables asli)
#   * opsi '-t <tabel>' boleh berada di mana pun dalam argumen
# Mode uji:
#   E2E_IPTABLES_FAIL=1 → SEMUA operasi gagal (uji jalur error NAT)
#   E2E_IPTABLES_LIE=1  → '-C' selalu mengaku "ada" tetapi '-D' tidak menghapus
#                         (memicu loop tak terbatas pada kode lama → uji anti-hang)
STORE="${E2E_IPTABLES_STORE:-/tmp/st-e2e/iptables.store}"
[ -n "${E2E_IPTABLES_FAIL:-}" ] && { echo "iptables: gagal (simulasi)" >&2; exit 1; }

op=""
for a in "$@"; do
  case "$a" in -C|-A|-D|-F) op="$a"; break ;; esac
done

key=""
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -t|-N) skip=1; continue ;;
    -v|-n|-w|--wait) continue ;;
    -C|-A|-D|-F) continue ;;
  esac
  key="$key $a"
done
key="${key# }"

if [ "${E2E_IPTABLES_LIE:-}" = "1" ] && [ "$op" = "-C" ]; then
  exit 0
fi

case "$op" in
  -C) grep -qxF "$key" "$STORE" 2>/dev/null; exit $? ;;
  -A) printf '%s\n' "$key" >> "$STORE"; exit 0 ;;
  -D) awk -v k="$key" 'BEGIN{done=0} { if (!done && $0==k) { done=1; next } print }' \
        "$STORE" > "$STORE.tmp" 2>/dev/null && mv -f "$STORE.tmp" "$STORE" 2>/dev/null
      exit 0 ;;
  -F) : > "$STORE" 2>/dev/null; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/shims/iptables"

cat > "$WORK/shims/ip" <<'EOF'
#!/bin/sh
# Shim ip: meniru keluaran yang dipakai installer/bagian7/uninstall.
case "$*" in
  *"addr show"*) echo "5: zt5f0a1b2c9    inet 10.147.17.8/24 scope global zt5f0a1b2c9"; echo "3: eth0    inet 10.0.0.2/24 scope global eth0"; exit 0 ;;
  *"-o link show"*) echo "2: zt5f0a1b2c9: <BROADCAST,MULTICAST,UP,LOWER_UP>"; echo "3: eth0: <UP>"; exit 0 ;;
  *route*) echo "default via 10.0.0.1 dev eth0 proto dhcp"; exit 0 ;;
esac
echo "1: lo: <LOOPBACK,UP>"
EOF
chmod +x "$WORK/shims/ip"

mk pgrep 'exit 0'
mk ss 'echo "LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*"'
mk netstat 'echo "tcp 0 0 0.0.0.0:8080 0.0.0.0:* LISTEN"'

cat > "$WORK/shims/speedtest" <<'EOF'
#!/bin/sh
# Shim CLI Ookla — meniru perilaku NYATA soal lisensi (bug v8.1.0/B13):
#   * '-o <host>' TANPA --accept-license dan tanpa TTY → gagal (exit 1)
#   * '--version' → mencetak "Speedtest by Ookla ..." (deteksi oleh bagian1)
# Setiap pemanggilan dicatat untuk audit (E2E_SPEEDTEST_LOG).
LOG="${E2E_SPEEDTEST_LOG:-/tmp/st-e2e/speedtest.calls}"
printf '%s\n' "$*" >> "$LOG" 2>/dev/null
accepted=0
for a in "$@"; do
  case "$a" in
    --version) echo "Speedtest by Ookla 1.2.0.84"; exit 0 ;;
    --accept-license) accepted=1 ;;
  esac
done
if [ "$accepted" -ne 1 ]; then
  echo "Your use of this software is subject to the End User License Agreement ..."
  echo "To accept the message please run speedtest interactively or use the following:"
  echo "    speedtest --accept-license"
  exit 1
fi
echo "mock speedtest run OK"
exit 0
EOF
chmod +x "$WORK/shims/speedtest"

cat > "$WORK/shims/certbot" <<'EOF'
#!/bin/sh
DOM="speedtest.example.com"
case "$1" in
  plugins) echo "  dns-cloudflare"; exit 0 ;;
  certificates) echo "  Certificate Name: $DOM"; exit 0 ;;
  certonly)
    mkdir -p "/etc/letsencrypt/live/$DOM" 2>/dev/null
    : > "/etc/letsencrypt/live/$DOM/fullchain.pem" 2>/dev/null
    : > "/etc/letsencrypt/live/$DOM/privkey.pem" 2>/dev/null
    echo "mock: certificate issued for $DOM"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/shims/certbot"

cat > "$WORK/shims/crontab" <<'EOF'
#!/bin/sh
STORE="${E2E_CRONTAB:-/tmp/st-e2e/crontab.store}"
# Simulasi crontab yang SELALU gagal (uji ketahanan installer).
if [ -n "${E2E_CRONTAB_FAIL:-}" ]; then
  echo "crontab: gagal (simulasi)" >&2
  exit 1
fi
touch "$STORE" 2>/dev/null
if [ "${1:-}" = "-l" ]; then cat "$STORE" 2>/dev/null; exit 0; fi
if [ "${1:-}" = "-r" ]; then : > "$STORE"; exit 0; fi
# 'crontab -' → baca stdin (perilaku crontab sebenarnya)
if [ "${1:-}" = "-" ]; then cat > "$STORE"; exit 0; fi
if [ -n "${1:-}" ] && [ -f "$1" ]; then cp -f "$1" "$STORE"; exit 0; fi
exit 0
EOF
chmod +x "$WORK/shims/crontab"

cat > "$WORK/shims/zerotier-cli" <<'EOF'
#!/bin/sh
# Catat setiap pemanggilan (uji kebijakan interface ZeroTier / exit node).
[ -n "${E2E_ZT_LOG:-}" ] && printf '%s\n' "$*" >> "$E2E_ZT_LOG"
STATE="${E2E_ZT_STATE:-ok}"
NET="${ZT_NETWORK_ID:-72ff30f9733a82d9}"
case "$1" in
  info)
    [ "$STATE" = "offline" ] && { echo "200 info deadbeef00 1.14.0 OFFLINE"; exit 0; }
    echo "200 info deadbeef00 1.14.0 ONLINE"; exit 0 ;;
  listnetworks)
    case "$STATE" in
      ok) echo "200 listnetworks $NET mynet aa:bb:cc:dd:ee:ff 10.147.17.8/24 OK PRIVATE" ;;
      unauthorized) echo "200 listnetworks $NET mynet aa:bb:cc:dd:ee:ff 10.147.17.8/24 ACCESS_DENIED PRIVATE" ;;
      *) : ;;
    esac
    exit 0 ;;
  join|orbit) echo "200 ok"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/shims/zerotier-cli"

mk sshd 'exit 0'

# ── 3. Mock binary & file sistem ─────────────────────────────────────────────
cat > "$WORK/base/OoklaServer" <<'EOF'
#!/bin/sh
# Mock daemon: fork ke background lalu keluar (perilaku --daemon OoklaServer)
PIDF=""
for a in "$@"; do case "$a" in --pidfile=*) PIDF="${a#--pidfile=}" ;; esac; done
nohup sleep 300 >/dev/null 2>&1 &
[ -n "$PIDF" ] && echo $! > "$PIDF"
exit 0
EOF
chmod +x "$WORK/base/OoklaServer"

cat > "$WORK/base/OoklaServer.properties" <<'EOF'
OoklaServer.tcpPorts = 5060,8080
OoklaServer.udpPorts = 5060,8080
OoklaServer.allowedDomains = *.ookla.com, *.speedtest.net
#OoklaServer.ssl.useLetsEncrypt = true
EOF

printf '#!/bin/sh\nexit 0\n' > "$WORK/usr_sbin_fake/zerotier-one"
chmod +x "$WORK/usr_sbin_fake/zerotier-one"



# ── 4. Helper: jalankan perintah di dalam namespace mock-root ────────────────
ensure_mock_zt() {
  # Mock binary ZeroTier. Ditulis di sisi host ke direktori yang di-bind ke /usr/sbin,
  # karena uji uninstall menghapus binary itu (deleted di dalam bind-mount).
  printf '#!/bin/sh\nexit 0\n' > "$WORK/usr_sbin_fake/zerotier-one" 2>/dev/null || true
  chmod +x "$WORK/usr_sbin_fake/zerotier-one" 2>/dev/null || true
}

ensure_sbin_tools() {
  # iptables/sysctl/ip ada di /usr/sbin pada server nyata → sediakan di direktori
  # yang di-bind ke /usr/sbin agar uji merepresentasikan PATH asli (PATH cron
  # minimal hanya berisi /usr/bin:/bin, sehingga /usr/sbin harus benar-benar ada).
  for t in iptables ip sysctl zerotier-cli; do
    [ -f "$WORK/shims/$t" ] || continue
    cp -f "$WORK/shims/$t" "$WORK/usr_sbin_fake/$t" 2>/dev/null || true
    chmod 755 "$WORK/usr_sbin_fake/$t" 2>/dev/null || true
  done
}

ensure_local_speedtest() {
  # Server nyata: CLI Ookla ada di /usr/local/bin (TIDAK ada di PATH cron).
  [ -d "$WORK/localbin" ] || mkdir -p "$WORK/localbin"
  cp -f "$WORK/shims/speedtest" "$WORK/localbin/speedtest" 2>/dev/null || true
  chmod 755 "$WORK/localbin/speedtest" 2>/dev/null || true
}

ensure_local_cli() {
  # Salin shim CLI ke direktori yang di-bind ke /usr/local/bin supaya kondisi
  # sama dengan server nyata (CLI Ookla di /usr/local/bin, TIDAK di PATH cron).
  [ -d "$WORK/localbin" ] || mkdir -p "$WORK/localbin"
  cp -f "$WORK/shims/speedtest" "$WORK/localbin/speedtest" 2>/dev/null || true
  chmod 755 "$WORK/localbin/speedtest" 2>/dev/null || true
}

ns_run() {
  # $1 = perintah bash yang dijalankan di dalam namespace
  # $2 = env tambahan (opsional)
  ensure_mock_zt
  ensure_local_cli
  ensure_local_speedtest
  unshare -rm --map-root-user bash -c '
    WORK="'"$WORK"'"
    mount --bind "$WORK/etc" /etc 2>/dev/null
    mount --bind "$WORK/rootfs" /root 2>/dev/null
    mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
    mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null

    export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
    export E2E_CRONTAB="$WORK/crontab.store"
    export HOME=/root
    export REPO_RAW_BASE="file://$WORK/repo"
    export BASE_REPO="file://$WORK/repo"
    '"${2:-}"'
    cd "$WORK/base" || exit 1
    '"$1"'
  '
}

echo
echo "=== 1) Instalasi penuh (lingkungan bersih) ==="
ns_run 'bash ./install.sh > "$WORK/install.out" 2>&1; echo "EXIT=$?" > "$WORK/install.exit"; exit 0'
RC1="$(cat "$WORK/install.exit" 2>/dev/null)"
echo "   exit: $RC1"
if [ "$RC1" != "EXIT=0" ]; then
  echo "   --- 30 baris terakhir output installer ---"
  tail -30 "$WORK/install.out" | sed 's/^/   /'
fi

check "installer selesai tanpa error (rc=0)"          '[ "$RC1" = "EXIT=0" ]'
check "VERSION terpasang"                             '[ -f "'"$WORK"'/base/VERSION" ]'
check "checksums.sha256 tersalin"                     '[ -f "'"$WORK"'/base/checksums.sha256" ]'
check "speedtest-repo.conf tersalin (config terpusat)" '[ -f "'"$WORK"'/base/speedtest-repo.conf" ]'
check "speedtest-selfupdate.sh tersedia"              '[ -x "'"$WORK"'/base/speedtest-selfupdate.sh" ]'
check "entri /etc/hosts managed ada (mv & fallback mount)" 'grep -q "speedtest.example.com # speedtest-managed" "'"$WORK"'/etc/hosts"'
check "entri hosts lama milik pengguna tetap utuh"    'grep -q "fileserver.local" "'"$WORK"'/etc/hosts"'
check "public key dipasang ke /root/.ssh/authorized_keys" '[ -s "'"$WORK"'/rootfs/.ssh/authorized_keys" ]'
check "authorized_keys memuat blok penanda"           'grep -q "# BEGIN speedtest-managed-keys" "'"$WORK"'/rootfs/.ssh/authorized_keys"'
check "permission authorized_keys = 600"              '[ "$(stat -c %a "'"$WORK"'/rootfs/.ssh/authorized_keys" 2>/dev/null)" = "600" ]'
check "drop-in sshd ditulis"                          '[ -f "'"$WORK"'/etc/ssh/sshd_config.d/99-speedtest-managed.conf" ]'
check "drop-in sshd memuat PermitRootLogin"           'grep -q "PermitRootLogin prohibit-password" "'"$WORK"'/etc/ssh/sshd_config.d/99-speedtest-managed.conf" 2>/dev/null'
check "drop-in sshd memuat PubkeyAuthentication yes"  'grep -q "PubkeyAuthentication yes" "'"$WORK"'/etc/ssh/sshd_config.d/99-speedtest-managed.conf" 2>/dev/null'
check "password auth TIDAK dimatikan secara default"  '! grep -q "PasswordAuthentication no" "'"$WORK"'/etc/ssh/sshd_config.d/99-speedtest-managed.conf" 2>/dev/null'
check "cron self-update terpasang"                    'grep -q "speedtest-autoupdate (managed)" "'"$WORK"'/crontab.store"'
check "cron boot-sync terpasang"                      'grep -q "speedtest-boot-sync (managed)" "'"$WORK"'/crontab.store"'
check "NAT ZT dipulihkan via bagian10 --postboot"      'grep -q "bagian7_network.sh\" --postboot" "'"$WORK"'/base/bagian10_hosts_ssh.sh"'
check "cron usang zt-nat-restore tidak ada"             '! grep -q "zt-nat-restore" "'"$WORK"'/crontab.store"' 
check "cron report speedtest terpasang"               'grep -qF "cron-speedtest5.sh" "'"$WORK"'/crontab.store"'
check "cron daily restart terpasang"                  'grep -qF "# ookla-daily-restart" "'"$WORK"'/crontab.store"'
check "cron moon updater terpasang"                   'grep -qF "zt-moon-updater (managed)" "'"$WORK"'/crontab.store"'
check "cron renewal sertifikat terpasang (Cloudflare)" 'grep -qF "certbot-renew.sh" "'"$WORK"'/crontab.store"'
check "wrapper renewal sertifikat dibuat"             '[ -x "'"$WORK"'/base/certbot-renew.sh" ]'
check "verifikasi akhir dijalankan"                   'grep -q "VERIFIKASI AKHIR" "'"$WORK"'/install.out"'
check "verifikasi: OoklaServer OK"                    'grep -q "\[OK\]   OoklaServer berjalan" "'"$WORK"'/install.out"'
check "verifikasi: mapping hosts OK"                  'grep -q "\[OK\]   Mapping" "'"$WORK"'/install.out"'
check "verifikasi: kunci SSH OK"                      'grep -q "\[OK\]   Kunci SSH" "'"$WORK"'/install.out"'
check "verifikasi: ZeroTier OK"                       'grep -q "\[OK\]   ZeroTier terhubung" "'"$WORK"'/install.out"'
check "installer mengaktifkan layanan cron"           'grep -q "Layanan cron aktif" "'"$WORK"'/install.out"'
check "SSH memakai pustaka bersama (ssh_sync_all)"   'grep -q "ssh_sync_all" "'"$WORK"'/base/bagian10_hosts_ssh.sh" && grep -q "ssh_sync_all()" "'"$WORK"'/base/common_functions1.sh"'
check "helper user_home dipakai (tanpa getent langsung)" 'grep -q "user_home" "'"$WORK"'/base/common_functions1.sh" && ! grep -q "getent passwd" "'"$WORK"'/base/bagian10_hosts_ssh.sh"'
check "tidak ada hack fallback .apk untuk kunci SSH"  '! grep -q "apk_url" "'"$WORK"'/base/common_functions1.sh"'
check "moon updater menanam MOON_ID dari repo (fix heredoc)" 'grep -q "\"72ff30f973\"" "'"$WORK"'/localbin/zt-moon-updater.sh" 2>/dev/null'
check "moon updater memakai path absolut zerotier-cli" 'grep -q "ZT_CLI=\"/usr/sbin/zerotier-cli\"" "'"$WORK"'/localbin/zt-moon-updater.sh" 2>/dev/null'
check "properties memuat path sertifikat"             'grep -q "openSSL.server.certificateFile" "'"$WORK"'/base/OoklaServer.properties"'
check "state file menyimpan VERSION & REPO"           'grep -q "^VERSION=" "'"$WORK"'/base/.speedtest-install.state"'
check "smoke test laporan dijalankan saat instalasi"  'grep -q "Uji laporan end-to-end" "'"$WORK"'/install.out"'
check "CLI dipanggil dengan flag lisensi (non-interaktif)" 'grep -q -- "--accept-license" "'"$WORK"'/speedtest.calls"'
check "log instalasi dibuat"                          '[ -f "'"$WORK"'/base/install.log" ]'

echo
echo "--- Cron terpasang (mock crontab) ---"
sed 's/^/   /' "$WORK/crontab.store"
cp -f "$WORK/crontab.store" "$WORK/crontab.run1.store" 2>/dev/null || :
CRON_BEFORE="$(awk 'NF{n++} END{print n+0}' "$WORK/crontab.store" 2>/dev/null)"

echo
echo "=== 2) Idempotensi: jalankan installer lagi ==="
ns_run 'bash ./install.sh > "$WORK/install2.out" 2>&1; echo "EXIT=$?" > "$WORK/install2.exit"; exit 0'
RC2="$(cat "$WORK/install2.exit" 2>/dev/null)"
echo "   exit: $RC2"
cp -f "$WORK/crontab.store" "$WORK/crontab.run2.store" 2>/dev/null || :
CRON_AFTER="$(awk 'NF{n++} END{print n+0}' "$WORK/crontab.store" 2>/dev/null)"
if [ "$CRON_BEFORE" != "$CRON_AFTER" ]; then
  echo "   --- selisih crontab run1 vs run2 ---"
  diff "$WORK/crontab.run1.store" "$WORK/crontab.run2.store" | sed 's/^/   /'
fi
# shellcheck disable=SC2034  # dipakai di dalam string check "..."
HOSTS_MANAGED="$(grep -c "speedtest-managed" "$WORK/etc/hosts" 2>/dev/null || echo 0)"
# shellcheck disable=SC2034  # dipakai di dalam string check "..."
KEYS_BEGIN="$(grep -c "# BEGIN speedtest-managed-keys" "$WORK/rootfs/.ssh/authorized_keys" 2>/dev/null || echo 0)"

check "run kedua sukses (rc=0)"                '[ "$RC2" = "EXIT=0" ]'
check "jumlah baris cron tidak bertambah"      '[ "$CRON_BEFORE" = "$CRON_AFTER" ]'
check "entri hosts tidak terduplikasi"         '[ "$HOSTS_MANAGED" = "1" ]'
check "blok kunci SSH tidak terduplikasi"      '[ "$KEYS_BEGIN" = "1" ]'

echo
echo "=== 3) Self-update otomatis (repo mock naik ke 99.0.0) ==="
echo "99.0.0" > "$WORK/repo/VERSION"
sed -i 's/Menjalankan Auto Install Speedtest OoklaServer/Menjalankan Auto Install Speedtest OoklaServer [UPDATED-99.0.0]/' "$WORK/repo/bagian0.sh"
rehash_mock_repo
ns_run 'bash ./speedtest-selfupdate.sh --force > "$WORK/selfupdate.out" 2>&1; echo "EXIT=$?" > "$WORK/selfupdate.exit"; exit 0'
tail -8 "$WORK/selfupdate.out" | sed 's/^/   /'

check "self-update berhasil (rc=0)"           'grep -q "EXIT=0" "'"$WORK"'/selfupdate.exit"'
check "VERSION terpasang naik ke 99.0.0"      '[ "$(head -1 "'"$WORK"'/base/VERSION")" = "99.0.0" ]'
check "file bagian0 ikut ter-update"          'grep -q "UPDATED-99.0.0" "'"$WORK"'/base/bagian0.sh"'
# shellcheck disable=SC2034  # dipakai di dalam string check "..."
BACKUP_COUNT="$(ls -1 "$WORK/base/.backups" 2>/dev/null | wc -l)"
check "backup versi lama dibuat"              '[ "${BACKUP_COUNT:-0}" -ge 1 ]'
check "update.log dibuat"                     '[ -f "'"$WORK"'/base/update.log" ]'
# shellcheck disable=SC2034  # dipakai di dalam string check "..."
HOSTS_AFTER_UPDATE="$(grep -c "speedtest-managed" "$WORK/etc/hosts" 2>/dev/null || echo 0)"
check "hosts tetap konsisten setelah update"  '[ "$HOSTS_AFTER_UPDATE" -ge 1 ]'

echo
echo "=== 4) ZeroTier WAJIB: node belum di-authorize harus GAGAL ==="
cat > "$WORK/base/zt_test.ini" <<'EOF'
ApakahDomainWildcard="Tidak"
ApakahPakaiCloudflare="Ya"
Domain="speedtest.example.com"
APICloudFlare="dummytoken0123456789abcdef"
RegisteredSpeedtestURL="speedtest.example.com"
EOF
sed -i 's/^ZT_AUTH_TIMEOUT=.*/ZT_AUTH_TIMEOUT="3"/' "$WORK/base/speedtest-repo.conf"
ns_run 'E2E_ZT_STATE=unauthorized bash ./bagian7_network.sh ./zt_test.ini > "$WORK/ztfail.out" 2>&1; echo "EXIT=$?" > "$WORK/ztfail.exit"; exit 0'
grep -iE "authorize|BELUM|ERROR" "$WORK/ztfail.out" | head -4 | sed 's/^/   /'
check "bagian7 GAGAL saat node belum di-authorize" '! grep -q "EXIT=0" "'"$WORK"'/ztfail.exit"'

echo
echo "=== 5) ZeroTier: node ter-authorize harus SUKSES ==="
rm -f "$WORK/zt.calls"
ns_run 'E2E_ZT_STATE=ok E2E_ZT_LOG="$WORK/zt.calls" bash ./bagian7_network.sh ./zt_test.ini > "$WORK/ztok.out" 2>&1; echo "EXIT=$?" > "$WORK/ztok.exit"; exit 0'
grep -iE "orbit|authorize|terhubung|Network ID" "$WORK/ztok.out" | head -5 | sed 's/^/   /'
check "bagian7 SUKSES saat node ter-authorize"  'grep -q "EXIT=0" "'"$WORK"'/ztok.exit"'
check "orbit moon dijalankan"                   'grep -qiE "orbit|moon" "'"$WORK"'/ztok.out"'
check "orbit moon tercatat di output"           'grep -qi "orbit" "'"$WORK"'/ztok.out"'
check "kebijakan interface: allowManaged=1 (C6)"       'grep -q "^set 72ff30f9733a82d9 allowManaged=1" "'"$WORK"'/zt.calls"'
check "kebijakan interface: allowDefault=0 (C6 anti-loop)" 'grep -q "^set 72ff30f9733a82d9 allowDefault=0" "'"$WORK"'/zt.calls"'
check "kebijakan interface: allowGlobal=0 (C6)"        'grep -q "^set 72ff30f9733a82d9 allowGlobal=0" "'"$WORK"'/zt.calls"'

echo
echo "=== 6) Uninstall (tidak destruktif) ==="
ns_run 'bash ./uninstall.sh --force ./data.ini > "$WORK/uninstall.out" 2>&1; echo "EXIT=$?" > "$WORK/uninstall.exit"; exit 0'
tail -6 "$WORK/uninstall.out" | sed 's/^/   /'
check "uninstall selesai (rc=0)"                      'grep -q "EXIT=0" "'"$WORK"'/uninstall.exit"'
check "entri hosts managed dihapus"                   '! grep -q "speedtest-managed" "'"$WORK"'/etc/hosts"'
check "entri hosts pengguna tetap ada"                'grep -q "fileserver.local" "'"$WORK"'/etc/hosts"'
check "data.ini disimpan"                             '[ -f "'"$WORK"'/base/data.ini" ]'
check "file installer dibersihkan (install.sh hilang)" '[ ! -f "'"$WORK"'/base/install.sh" ]'
check "cron milik installer dibersihkan"              '! grep -q "speedtest-autoupdate" "'"$WORK"'/crontab.store"'
check "kunci SSH managed dihapus dari authorized_keys" '! grep -q "# BEGIN speedtest-managed-keys" "'"$WORK"'/rootfs/.ssh/authorized_keys" 2>/dev/null'


echo
echo "=== 7) Uji mode ONE-LINER (pipe): curl ... | bash ==="
# Direktori kerja baru HANYA berisi data.ini (mensimulasikan server baru)
rm -rf "$WORK/base2"; mkdir -p "$WORK/base2"
cp -f "$WORK/base/data.ini" "$WORK/base2/data.ini"
rm -rf "$WORK/rootfs2"; mkdir -p "$WORK/rootfs2"

ensure_mock_zt
ensure_local_cli
ensure_sbin_tools
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs2" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_CRONTAB="$WORK/crontab2.store"
  export HOME=/root
  export REPO_RAW_BASE="file://$WORK/repo"
  export BASE_REPO="file://$WORK/repo"
  cd "$WORK/base2" || exit 1
  # Simulasi:  cat install.sh | bash   (tanpa file script di direktori kerja)
  cat "$WORK/repo/install.sh" | bash > "$WORK/pipe.out" 2>&1
  echo "EXIT=$?" > "$WORK/pipe.exit"
  exit 0
'
tail -12 "$WORK/pipe.out" | sed 's/^/   /'
check "mode pipe (curl | bash) sukses"            'grep -q "EXIT=0" "'"$WORK"'/pipe.exit"'
check "mode pipe memasang install.sh ke BASE_DIR" '[ -f "'"$WORK"'/base2/install.sh" ]'
check "mode pipe memasang seluruh bagian"         '[ -f "'"$WORK"'/base2/bagian7_network.sh" ] && [ -f "'"$WORK"'/base2/bagian10_hosts_ssh.sh" ]'
check "mode pipe menulis /etc/hosts"              'grep -q "speedtest-managed" "'"$WORK"'/etc/hosts"'
check "mode pipe memasang cron self-update"       'grep -q "speedtest-autoupdate" "'"$WORK"'/crontab2.store"'
check "mode pipe memasang kunci SSH"              '[ -s "'"$WORK"'/rootfs2/.ssh/authorized_keys" ]'

echo
echo "=== 8) Re-exec anti version-skew ==="
check "installer mendukung re-exec (guard SPEEDTEST_REEXEC)" 'grep -q "SPEEDTEST_REEXEC" "'"$REPO_ROOT"'/install.sh"'
check "self-update memakai cmp (tidak menulis file identik)" 'grep -q "cmp -s" "'"$REPO_ROOT"'/auto_update_lib.sh"'
check "parser config menangani komentar inline"              'grep -q "au_parse_value" "'"$REPO_ROOT"'/auto_update_lib.sh"'

echo
echo "=== 9) Kasus container: /etc/hosts adalah mount point ==="
# Simulasi Docker: file /etc/hosts di-bind dari luar sehingga 'mv' gagal.
rm -rf "$WORK/base3" "$WORK/rootfs3"; mkdir -p "$WORK/base3" "$WORK/rootfs3"
cp -f "$WORK/repo/bagian10_hosts_ssh.sh" "$WORK/repo/common_functions1.sh" \
      "$WORK/repo/auto_update_lib.sh" "$WORK/repo/speedtest-repo.conf" "$WORK/base3/" 2>/dev/null
cp -f "$WORK/base/data.ini" "$WORK/base3/data.ini" 2>/dev/null || true
printf '127.0.0.1 localhost\n10.0.0.9 speedtest.example.com # sudah ada milik user\n' > "$WORK/etc_hosts_dir/mount_hosts"

ensure_mock_zt
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/etc_hosts_dir/mount_hosts" /etc/hosts 2>/dev/null
  mount --bind "$WORK/rootfs3" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export HOME=/root
  export HOSTS_FILE=/etc/hosts
  cd "$WORK/base3" || exit 1
  bash ./bagian10_hosts_ssh.sh -postboot > "$WORK/mount_hosts.out" 2>&1
  echo "EXIT=$?" > "$WORK/mount_hosts.exit"
  exit 0
'
check "penulisan hosts berhasil walau /etc/hosts mount point" 'grep -q "speedtest-managed" "'"$WORK"'/etc_hosts_dir/mount_hosts"'
check "entri hosts milik user tetap ada"                      'grep -q "10.0.0.9 speedtest.example.com" "'"$WORK"'/etc_hosts_dir/mount_hosts"'

echo
echo "=== 10) Ketahanan: crontab gagal (cron API error) ==="
rm -rf "$WORK/base4"; mkdir -p "$WORK/base4"
cp -f "$WORK/repo/bagian6_automaintenance.sh" "$WORK/repo/common_functions1.sh" \
      "$WORK/repo/auto_update_lib.sh" "$WORK/repo/speedtest-repo.conf" "$WORK/base4/" 2>/dev/null
cp -f "$WORK/base/data.ini" "$WORK/base4/data.ini" 2>/dev/null || true
: > "$WORK/crontab.fail.store"
ensure_mock_zt
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_CRONTAB="$WORK/crontab.fail.store"
  export E2E_CRONTAB_FAIL=1
  export HOME=/root
  cd "$WORK/base4" || exit 1
  bash ./bagian6_automaintenance.sh ./data.ini > "$WORK/cronfail.out" 2>&1
  echo "EXIT=$?" > "$WORK/cronfail.exit"
  exit 0
'
check "bagian6 tetap sukses walau crontab error"      'grep -q "EXIT=0" "'"$WORK"'/cronfail.exit"'
check "bagian6 memberi peringatan yang jelas"          'grep -q "Gagal memasang cron" "'"$WORK"'/cronfail.out"'
check "crontab tidak rusak/di-truncate saat error"     '[ ! -s "'"$WORK"'/crontab.fail.store" ]'

echo
echo "=== 11) Unit test: pola entri cron (regresi @reboot) ==="
# Regresi v8.1.0: sed dengan alternansi '(\@reboot|5 field)' salah-strip entri
# @reboot menjadi '2>&1' → pola terlalu pendek → cron bagian lain ikut terhapus.
ensure_mock_zt
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export HOME=/root
  . "$WORK/repo/common_functions1.sh" >/dev/null 2>&1
  TMP_DIR="$WORK/tmp"; mkdir -p "$TMP_DIR"; export TMP_DIR
  {
    cron_entry_pattern "@reboot bash /opt/x/y.sh -postboot >/dev/null 2>&1"
    cron_entry_pattern "0 0 * * * cd /opt/x && /opt/x/ooklaserver.sh restart"
    cron_entry_pattern "*/5 * * * * /opt/x/cron-speedtest5.sh"
  } > "$WORK/pat.out"
  exit 0
'
check "pola entri @reboot benar (bukan 2>&1)"         'grep -qxF "bash /opt/x/y.sh -postboot >/dev/null 2>&1" "'"$WORK"'/pat.out"'
check "pola entri 5-field benar"                      'grep -qxF "cd /opt/x && /opt/x/ooklaserver.sh restart" "'"$WORK"'/pat.out"'
check "pola entri wrapper benar"                      'grep -qxF "/opt/x/cron-speedtest5.sh" "'"$WORK"'/pat.out"'

echo
echo "=== 12) Saklar reporting (REPORT_FAST_ENABLED=Tidak) ==="
rm -rf "$WORK/base5"; mkdir -p "$WORK/base5"
cp -f "$WORK/repo/bagian6_automaintenance.sh" "$WORK/repo/common_functions1.sh" \
      "$WORK/repo/auto_update_lib.sh" "$WORK/repo/speedtest-repo.conf" "$WORK/base5/" 2>/dev/null
cp -f "$WORK/base/data.ini" "$WORK/base5/data.ini" 2>/dev/null || true
if [ -f "$WORK/base5/data.ini" ]; then
  sed -i 's/^REPORT_FAST_ENABLED=.*/REPORT_FAST_ENABLED="Tidak"/' "$WORK/base5/speedtest-repo.conf"
else
  echo "   (data.ini tidak tersedia — pakai base2)"
  cp -f "$WORK/base2/data.ini" "$WORK/base5/data.ini" 2>/dev/null || true
  sed -i 's/^REPORT_FAST_ENABLED=.*/REPORT_FAST_ENABLED="Tidak"/' "$WORK/base5/speedtest-repo.conf"
fi
printf '# speedtest-report (managed)\n0 * * * * %s/base5/cron-speedtest.sh\n*/5 * * * * %s/base5/cron-speedtest5.sh\n' "$WORK" "$WORK" > "$WORK/crontab.fast.store"
ensure_mock_zt
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_CRONTAB="$WORK/crontab.fast.store"
  export HOME=/root
  cd "$WORK/base5" || exit 1
  bash ./bagian6_automaintenance.sh ./data.ini > "$WORK/reportfast.out" 2>&1
  echo "EXIT=$?" > "$WORK/reportfast.exit"
  exit 0
'
check "bagian6 sukses dengan laporan cepat dimatikan" 'grep -q "EXIT=0" "'"$WORK"'/reportfast.exit"'
check "jadwal cepat (5 menit) benar-benar dihapus"     '! grep -q "cron-speedtest5.sh" "'"$WORK"'/crontab.fast.store"'
check "jadwal per jam tetap ada"                       'grep -q "cron-speedtest.sh" "'"$WORK"'/crontab.fast.store"'
check "entri milik bagian lain tidak tersentuh"        'grep -q "speedtest-report (managed)" "'"$WORK"'/crontab.fast.store"'


echo
echo "=== 13) Regresi B13/B14: laporan cron HARUS jalan dengan PATH cron minimal ==="
# $WORK/base sudah di-uninstall pada bagian 6 → siapkan instalasi baru (base4)
# khusus untuk uji wrapper cron & NAT di bawah ini.
rm -rf "$WORK/base4"; mkdir -p "$WORK/base4"
cp -f "$WORK/repo/install.sh" "$WORK/base4/install.sh" 2>/dev/null || true
cp -f "$WORK/unit/data2.ini" "$WORK/base4/data.ini" 2>/dev/null || cp -f "$WORK/base/data.ini" "$WORK/base4/data.ini"
ensure_mock_zt
ensure_local_cli
ensure_sbin_tools
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_CRONTAB="$WORK/crontab4.store"
  export HOME=/root
  export REPO_RAW_BASE="file://$WORK/repo"
  export BASE_REPO="file://$WORK/repo"
  cd "$WORK/base4" || exit 1
  timeout 300 bash ./install.sh > "$WORK/install4.out" 2>&1
  echo "EXIT=$?" > "$WORK/install4.exit"
  exit 0
'
check "instalasi ulang (base4) sukses untuk uji lanjutan" 'grep -q "EXIT=0" "'"$WORK"'/install4.exit"'
LIVE="$WORK/base4"
# Kondisi asli server: cron hanya punya PATH=/usr/bin:/bin, CLI Ookla ada di
# /usr/local/bin, dan CLI menolak jalan tanpa flag lisensi (shim meniru ini).
check "wrapper memuat PATH eksplisit (CRON_PATH)"      'grep -q "^PATH=" "'"$WORK"'/base4/cron-speedtest.sh"'
check "wrapper memakai path absolut CLI Ookla"         'grep -q "^SPEEDTEST_BIN=\"/usr/local/bin/speedtest\"" "'"$WORK"'/base4/cron-speedtest.sh"'
check "wrapper membawa flag lisensi"                   'grep -q "^SPEEDTEST_FLAGS=\"--accept-license --accept-gdpr\"" "'"$WORK"'/base4/cron-speedtest.sh"'
check "wrapper menulis log laporan"                    'grep -q "^LOG=\"" "'"$WORK"'/base4/cron-speedtest5.sh"'

# Kontrol: TANPA flag lisensi, CLI (shim yang meniru perilaku asli) harus GAGAL.
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export HOME=/root
  env -i PATH=/usr/bin:/bin HOME=/root /usr/local/bin/speedtest -o speedtest.example.com >/dev/null 2>&1
  echo "EXIT=$?" > "$WORK/license_control.exit"
  exit 0
'
check "kontrol: tanpa --accept-license CLI gagal (perilaku asli)" 'grep -q "EXIT=1" "'"$WORK"'/license_control.exit"'

# Jalankan bagian6 ulang dengan jitter 0 lalu eksekusi wrapper pada PATH cron minimal.
ensure_mock_zt
ensure_local_cli
ensure_sbin_tools
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_CRONTAB="$WORK/crontab4.store"
  export E2E_SPEEDTEST_LOG="$WORK/speedtest.calls"
  export HOME=/root
  cd "$WORK/base4" || exit 1
  : > "$WORK/speedtest.calls"
  # Jitter 0 menit supaya uji tidak menunggu (config ini juga dipakai di produksi
  # bila operator ingin laporan langsung tanpa jeda acak).
  sed -i "s/^REPORT_JITTER_MIN_MAX=.*/REPORT_JITTER_MIN_MAX=\"0\"/" speedtest-repo.conf
  printf 'REPORT_FAST_ENABLED="Ya"\n' >> speedtest-repo.conf
  bash ./bagian6_automaintenance.sh ./data.ini > "$WORK/report_regen.out" 2>&1
  rm -f "$WORK/base4/report.log"
  # INTI UJI (B13/B14): jalankan wrapper seperti cron — PATH hanya /usr/bin:/bin
  # (tanpa /usr/local/bin!), tanpa TTY, dan tanpa variabel lingkungan lain.
  env -i PATH=/usr/bin:/bin HOME=/root E2E_SPEEDTEST_LOG="$WORK/speedtest.calls" sh "$WORK/base4/cron-speedtest.sh" > "$WORK/wrapper_hourly.out" 2>&1
  echo "rc_hourly=$?" >> "$WORK/wrapper_hourly.out"
  env -i PATH=/usr/bin:/bin HOME=/root E2E_SPEEDTEST_LOG="$WORK/speedtest.calls" sh "$WORK/base4/cron-speedtest5.sh" > "$WORK/wrapper_fast.out" 2>&1
  echo "rc_fast=$?" >> "$WORK/wrapper_fast.out"

  # KONTROL: perilaku lama (tanpa flag lisensi) HARUS gagal → membuktikan uji ini
  # benar-benar sensitif terhadap bug B13.
  env -i PATH=/usr/bin:/bin HOME=/root /usr/local/bin/speedtest -o speedtest.example.com > "$WORK/nolicense.out" 2>&1
  echo "rc_nolicense=$?" >> "$WORK/nolicense.out"
  env -i PATH=/usr/bin:/bin HOME=/root /usr/local/bin/speedtest --accept-license --accept-gdpr -o speedtest.example.com > "$WORK/withlicense.out" 2>&1
  echo "rc_withlicense=$?" >> "$WORK/withlicense.out"
  # Validasi sintaks POSIX (/bin/sh): wrapper WAJIB jalan tanpa bashisme.
  if env -i PATH=/usr/bin:/bin sh -n "$WORK/base4/cron-speedtest.sh" 2>/dev/null; then
    echo "SHN=0" > "$WORK/wrapper_shn"
  else
    echo "SHN=1" > "$WORK/wrapper_shn"
  fi
  exit 0
'
sed -n '1,4p' "$WORK/base4/report.log" 2>/dev/null | sed 's/^/   /' || true
echo "   kontrol tanpa lisensi: $(cat "$WORK/nolicense.out" 2>/dev/null | tail -1)"
check "laporan per jam sukses pada PATH cron minimal"  'grep -q "rc_hourly=0" "'"$WORK"'/wrapper_hourly.out"'
check "laporan cepat sukses pada PATH cron minimal"    'grep -q "rc_fast=0" "'"$WORK"'/wrapper_fast.out"'
check "report.log mencatat rc=0 (tidak senyap lagi)"   'grep -q "rc=0 (hourly)" "'"$WORK"'/base4/report.log"'
check "report.log mencatat rc=0 untuk laporan cepat"   'grep -q "rc=0 (fast)" "'"$WORK"'/base4/report.log"'
check "wrapper handal: CLI dipanggil dengan flag lisensi" 'grep -q -- "--accept-license" "'"$WORK"'/speedtest.calls"'
check "KONTROL: tanpa flag lisensi CLI gagal (rc=1)"   'grep -q "rc_nolicense=1" "'"$WORK"'/nolicense.out"'
check "dengan flag lisensi CLI sukses (rc=0)"          'grep -q "rc_withlicense=0" "'"$WORK"'/withlicense.out"'
check "wrapper lolos sintaks POSIX (/bin/sh -n)"       'grep -qx "SHN=0" "'"$WORK"'/wrapper_shn"'
check "smoke test install memakai flag lisensi"        'grep -q -- "--accept-license" "'"$WORK"'/speedtest.calls" || grep -q "Laporan speedtest BERHASIL" "'"$WORK"'/install4.out"'

echo
echo "=== 14) Regresi B15/B16: NAT postboot --postboot tidak senyap + idempotent ==="
: > "$WORK/iptables.store"
rm -f "$WORK/sysctl.store"   # mulai dari "IP forwarding belum aktif"
ensure_mock_zt
ensure_local_cli
ensure_sbin_tools
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_IPTABLES_STORE="$WORK/iptables.store"
  export HOME=/root
  cd "$WORK/base4" || exit 1
  env -i PATH=/usr/bin:/bin HOME=/root CRON_PATH="$CRON_PATH" E2E_IPTABLES_STORE="$WORK/iptables.store" E2E_SYSCTL_STORE="$WORK/sysctl.store" E2E_ZT_LOG="$WORK/zt.postboot.calls" bash "$WORK/base4/bagian7_network.sh" --postboot > "$WORK/nat1.out" 2>&1
  echo "EXIT=$?" > "$WORK/nat1.exit"
  env -i PATH=/usr/bin:/bin HOME=/root CRON_PATH="$CRON_PATH" E2E_IPTABLES_STORE="$WORK/iptables.store" E2E_SYSCTL_STORE="$WORK/sysctl.store" E2E_ZT_LOG="$WORK/zt.postboot.calls" bash "$WORK/base4/bagian7_network.sh" --postboot > "$WORK/nat2.out" 2>&1
  echo "EXIT=$?" > "$WORK/nat2.exit"
  exit 0
'
NAT_RULES="$(awk 'NF{n++} END{print n+0}' "$WORK/iptables.store" 2>/dev/null)"
echo "   rule iptables tercatat: $NAT_RULES"
grep -E "NAT|masquerade" "$WORK/nat1.out" | sed 's/^/   /'
check "postboot berhasil dengan PATH minimal (iptables ditemukan)" 'grep -q "EXIT=0" "'"$WORK"'/nat1.exit"'
check "rule NAT benar-benar terpasang (3 rule)"        '[ "${NAT_RULES:-0}" -eq 3 ]'
check "log sukses hanya setelah rule terverifikasi"    'grep -q "verifikasi" "'"$WORK"'/nat1.out"'
check "masquerade dibatasi subnet ZeroTier (bukan generik)" 'grep -q -- "-s 10.147.17.8/24 -o eth0 -j MASQUERADE" "'"$WORK"'/iptables.store"'
check "tidak ada masquerade generik di POSTROUTING"    '! grep -qE "(^| )POSTROUTING -o eth0 -j MASQUERADE" "'"$WORK"'/iptables.store"'
check "postboot kedua idempotent (tidak menumpuk rule)" '[ "$(awk "NF{n++} END{print n+0}" "'"$WORK"'/iptables.store")" -eq 3 ] && grep -q "EXIT=0" "'"$WORK"'/nat2.exit"'
check "postboot mengaktifkan IP forwarding (status sysctl)" 'grep -qx "1" "'"$WORK"'/sysctl.store"'
check "postboot menegakkan kebijakan interface ZT"      'grep -q "^set 72ff30f9733a82d9 allowDefault=0" "'"$WORK"'/zt.postboot.calls"'

unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_IPTABLES_STORE="$WORK/iptables.store"
  export E2E_IPTABLES_FAIL=1
  export HOME=/root
  cd "$WORK/base4" || exit 1
  env -i PATH=/usr/bin:/bin HOME=/root CRON_PATH="$CRON_PATH" E2E_IPTABLES_STORE="$WORK/iptables.store" E2E_IPTABLES_FAIL=1 bash "$WORK/base4/bagian7_network.sh" --postboot > "$WORK/natfail.out" 2>&1
  echo "EXIT=$?" > "$WORK/natfail.exit"
  exit 0
'
grep -E "ERROR|GAGAL|TIDAK" "$WORK/natfail.out" | head -3 | sed 's/^/   /'
check "postboot GAGAL bila iptables tidak bekerja"     '! grep -q "EXIT=0" "'"$WORK"'/natfail.exit"'
check "TIDAK ada log sukses palsu saat NAT gagal"      '! grep -q "masquerade, terverifikasi" "'"$WORK"'/natfail.out"'

# Jalur NYATA @reboot: bagian10 --postboot (yang dipasang di crontab) harus
# sukses dan menegakkan NAT + hosts + SSH tanpa data.ini di cwd.
: > "$WORK/iptables.store"
ensure_mock_zt
ensure_local_cli
ensure_local_speedtest
ensure_sbin_tools
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export E2E_CRONTAB="$WORK/crontab4.store"
  export E2E_IPTABLES_STORE="$WORK/iptables.store"
  cd / || exit 1
  env -i PATH=/usr/bin:/bin HOME=/root CRON_PATH="$CRON_PATH" E2E_IPTABLES_STORE="$WORK/iptables.store" E2E_SYSCTL_STORE="$WORK/sysctl.store" \
      bash "$WORK/base4/bagian10_hosts_ssh.sh" --postboot > "$WORK/bootsync.out" 2>&1
  echo "EXIT=$?" > "$WORK/bootsync.exit"
  exit 0
'
grep -E "hosts|kunci|NAT|ZeroTier" "$WORK/bootsync.out" | head -5 | sed 's/^/   /'
check "bagian10 --postboot (jalur @reboot) sukses"     'grep -q "EXIT=0" "'"$WORK"'/bootsync.exit"'
check "@reboot menegakkan NAT (rule scoped terpasang)" 'grep -q -- "-s 10.147.17.8/24 -o eth0 -j MASQUERADE" "'"$WORK"'/iptables.store"'
check "bagian7 menerima --postboot tanpa data.ini"     '! grep -q "data.ini tidak ditemukan" "'"$WORK"'/bootsync.out"'

echo
echo "=== 15) Regresi B17: cert_valid_for memeriksa masa berlaku (bukan keberadaan) ==="
if command -v openssl >/dev/null 2>&1; then
  rm -rf "$WORK/certlive"; mkdir -p "$WORK/certlive"/{valid.example.com,expiring.example.com,expired.example.com}
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=valid.example.com" \
      -keyout /dev/null -out "$WORK/certlive/valid.example.com/fullchain.pem" >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=expiring.example.com" \
      -keyout /dev/null -out "$WORK/certlive/expiring.example.com/fullchain.pem" >/dev/null 2>&1
  # Sertifikat KEDALUWARSA: dibuat dengan 'openssl ca' + -startdate/-enddate
  ( cd "$WORK/certlive" || exit 1
    mkdir -p demoCA/newcerts; : > demoCA/index.txt; echo 1000 > demoCA/serial
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Fake CA" \
        -keyout ca.key -out ca.pem >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
        -subj "/CN=expired.example.com" >/dev/null 2>&1
    cat > ca.cnf <<'CAEOF'
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = DEMODIR
certificate = CAPEM
private_key = CAKEY
database = $dir/index.txt
new_certs_dir = $dir/newcerts
serial = $dir/serial
default_md = sha256
policy = policy_any
email_in_dn = no
rand_serial = no
[ policy_any ]
commonName = supplied
CAEOF
    sed -i "s|DEMODIR|$WORK/certlive/demoCA|; s|CAPEM|$WORK/certlive/ca.pem|; s|CAKEY|$WORK/certlive/ca.key|" ca.cnf
    openssl ca -batch -config ca.cnf -in leaf.csr -out expired.example.com/fullchain.pem \
        -startdate 20200101000000Z -enddate 20200102000000Z -notext >/dev/null 2>&1
  )
  unshare -rm --map-root-user bash -c '
    WORK="'"$WORK"'"
    export PATH="$WORK/shims:/usr/bin:/bin"
    export HOME=/root
    export BASE_DIR="$WORK/base"
    export TMP_DIR="$WORK/base/tmp"; mkdir -p "$TMP_DIR"
    export CERT_LIVE_DIR="$WORK/certlive"
    export CERT_MIN_VALID_DAYS=10
    . "$WORK/repo/common_functions1.sh" >/dev/null 2>&1
    {
      cert_valid_for valid.example.com    && echo "valid=0"    || echo "valid=1"
      cert_valid_for expiring.example.com && echo "expiring=0" || echo "expiring=1"
      cert_valid_for expired.example.com  && echo "expired=0"  || echo "expired=1"
      cert_valid_for missing.example.com  && echo "missing=0"  || echo "missing=1"
      echo "days_active=$(cert_days_left valid.example.com)"
    } > "$WORK/certval.out" 2>/dev/null
    exit 0
  '
  cat "$WORK/certval.out" | sed 's/^/   /'
  check "sertifikat valid (365 hari) → dianggap berlaku"  'grep -qx "valid=0" "'"$WORK"'/certval.out"'
  check "sertifikat sisa 3 hari → diterbitkan ulang"      'grep -qx "expiring=1" "'"$WORK"'/certval.out"'
  check "sertifikat KEDALUWARSA → diterbitkan ulang"      'grep -qx "expired=1" "'"$WORK"'/certval.out"'
  check "sertifikat tidak ada → diterbitkan ulang"        'grep -qx "missing=1" "'"$WORK"'/certval.out"'
else
  echo "   (openssl tidak tersedia — uji sertifikat dilewati)"
fi

echo
echo "=== 16) Audit: PATH cron, dependensi perintah, dan sisa pemanggilan rentan ==="
check "audit dependensi perintah lulus"                'python3 "'"$REPO_ROOT"'/tools/audit_cmd_deps.py" >/dev/null 2>&1'
check "bagian6 menanam PATH ke wrapper cron"          'grep -q "export PATH" "'"$REPO_ROOT"'/bagian6_automaintenance.sh" && grep -q "CRON_PATH" "'"$REPO_ROOT"'/bagian6_automaintenance.sh"'
check "bagian7 mengekspor PATH (sbin terlihat cron)"   'grep -q "^export PATH" "'"$REPO_ROOT"'/bagian7_network.sh"'
check "bagian10 memperluas PATH (sbin terlihat cron)"  'grep -q "path_augment_from_cron_path" "'"$REPO_ROOT"'/bagian10_hosts_ssh.sh"'
check "self-update memperluas PATH"                    'grep -q "path_augment_from_cron_path" "'"$REPO_ROOT"'/speedtest-selfupdate.sh"'
check "pustaka PATH bersama ada di common"             'grep -q "^path_augment_from_cron_path()" "'"$REPO_ROOT"'/common_functions1.sh"'
check "artefak cron bagian4 (renewal) punya PATH"      'grep -q '\''PATH="__CRON_PATH__"'\'' "'"$REPO_ROOT"'/bagian4_install_server_certificate.sh"'
check "bagian7 membatasi masquerade ke subnet ZT"      'grep -qF -- '\''ipt_ensure POSTROUTING -t nat -s "$ZT_SUBNET"'\'' "'"$REPO_ROOT"'/bagian7_network.sh"'
check "bagian7 menerima --postboot tanpa data.ini"    'grep -q -- "--postboot)" "'"$REPO_ROOT"'/bagian7_network.sh"'
check "bagian7 menegakkan kebijakan interface ZT (C6)"  'grep -q "allowManaged=1 allowDefault=0 allowGlobal=0" "'"$REPO_ROOT"'/bagian7_network.sh"'
check "kebijakan ZT non-fatal (tidak mematikan install)" 'grep -q "kebijakan interface ZeroTier dilewati" "'"$REPO_ROOT"'/bagian7_network.sh"'
check "uninstall memakai penghapusan rule TERBATAS"    'grep -q "ipt_del_max" "'"$REPO_ROOT"'/uninstall.sh" && ! grep -qE "^[[:space:]]*while[[:space:]].*iptables" "'"$REPO_ROOT"'/uninstall.sh"' 
check "uninstall memakai path absolut iptables/ip"     'grep -q "IPT_BIN=" "'"$REPO_ROOT"'/uninstall.sh"'
check "refresh sertifikat memakai pustaka bersama"     'grep -q "cert_days_left" "'"$REPO_ROOT"'/bagian4_install_server_certificate.sh"'
check "tidak ada lagi 'speedtest -o' telanjang"        '! grep -qE "(^|[;&|])[[:space:]]*speedtest[[:space:]]" "'"$REPO_ROOT"'/bagian6_automaintenance.sh"'
check "tidak ada pemanggilan iptables telanjang"       '! grep -qE "(^|[;&|])[[:space:]]*iptables[[:space:]]" "'"$REPO_ROOT"'/bagian7_network.sh"'
check "tidak ada pemanggilan sysctl telanjang"         '! grep -qE "(^|[;&|])[[:space:]]*sysctl[[:space:]]" "'"$REPO_ROOT"'/bagian7_network.sh"'
check "speedtestctl punya aksi report + report-log"    'grep -q "report-log)" "'"$REPO_ROOT"'/bagian8_cek_konfigurasi.sh" && grep -q "  report)" "'"$REPO_ROOT"'/bagian8_cek_konfigurasi.sh"'
check "uninstall hanya menghapus CLI Ookla"            'grep -q "is_ookla_cli" "'"$REPO_ROOT"'/uninstall.sh"'
check "uninstall tidak menyentuh speedtest-cli Python" '! grep -qE "^[[:space:]]*(apk del speedtest-cli|apt-get remove -y speedtest-cli)" "'"$REPO_ROOT"'/uninstall.sh"'
check "konfigurasi baru terdokumentasi di speedtest-repo.conf" 'grep -q "SPEEDTEST_CLI_LICENSE_FLAGS" "'"$REPO_ROOT"'/speedtest-repo.conf" && grep -q "CRON_PATH" "'"$REPO_ROOT"'/speedtest-repo.conf"'

echo
echo "=== 17) Uninstall ulang: CLI non-Ookla milik operator TIDAK dihapus ==="
printf '#!/bin/sh\necho "speedtest-cli 2.1.3 (python, sivel/speedtest-cli)"\nexit 0\n' > "$WORK/localbin/speedtest"
chmod 755 "$WORK/localbin/speedtest"
cp -f "$WORK/repo/uninstall.sh" "$WORK/base/uninstall.sh" 2>/dev/null || true
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export HOME=/root
  cd "$WORK/base" || exit 1
  bash ./uninstall.sh --force ./data.ini > "$WORK/uninstall2.out" 2>&1
  echo "EXIT=$?" > "$WORK/uninstall2.exit"
  exit 0
'
grep -iE "bukan CLI Ookla|Dilewati|speedtest" "$WORK/uninstall2.out" | head -4 | sed 's/^/   /'
check "uninstall sukses dijalankan ulang (idempotent)"  'grep -q "EXIT=0" "'"$WORK"'/uninstall2.exit"'
check "CLI non-Ookla milik operator tetap ada"          '[ -f "'"$WORK"'/localbin/speedtest" ]'
check "alasan dilewati dicatat jelas"                   'grep -q "bukan CLI Ookla" "'"$WORK"'/uninstall2.out"'

echo
echo "=== 18) Unit: normalisasi RegisteredSpeedtestURL (C5) & masa berlaku sertifikat (B17) ==="
mkdir -p "$WORK/unit/tmp"
cat > "$WORK/unit/data-url.ini" <<'EOF'
ApakahDomainWildcard="Tidak"
ApakahPakaiCloudflare="Tidak"
Domain="speedtest.example.com"
APICloudFlare=""
EmailCloudFlare=""
RegisteredSpeedtestURL="https://speedtest.example.com/hasil?id=1"
EOF
env BASE_DIR="$WORK/unit" TMP_DIR="$WORK/unit/tmp" \
  bash -c '
    set -uo pipefail
    . "$1" >/dev/null 2>&1
    resolve_config_path "$2" >/dev/null 2>&1
    load_and_validate_config >/dev/null 2>&1
    printf "REG=%s\n" "${RegisteredSpeedtestURL:-KOSONG}"
    printf "HOST=%s\n" "$(hostname_of "https://speedtest.example.com:8443/hasil?id=1")"
  ' _ "$WORK/repo/common_functions1.sh" "$WORK/unit/data-url.ini" > "$WORK/unit/url.result" 2>/dev/null
sed 's/^/   /' "$WORK/unit/url.result" 2>/dev/null
check "URL penuh dinormalisasi jadi hostname (C5)"      'grep -qx "REG=speedtest.example.com" "'"$WORK"'/unit/url.result"'
check "hostname_of lepas skema+port+path"              'grep -qx "HOST=speedtest.example.com" "'"$WORK"'/unit/url.result"'

# Fixture sertifikat: valid (90 hari), hampir kedaluwarsa (5 hari), kedaluwarsa (CA),
# dan satu domain tanpa sertifikat.
if command -v openssl >/dev/null 2>&1; then
  rm -rf "$WORK/certfix"; mkdir -p "$WORK/certfix"/{valid.example.com,expiring.example.com,expired.example.com}
  openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=valid.example.com" \
      -keyout /dev/null -out "$WORK/certfix/valid.example.com/fullchain.pem" >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -days 5 -subj "/CN=expiring.example.com" \
      -keyout /dev/null -out "$WORK/certfix/expiring.example.com/fullchain.pem" >/dev/null 2>&1
  (
    cd "$WORK/certfix" || exit 1
    mkdir -p ca/newcerts; : > ca/index.txt; echo 1000 > ca/serial
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Test CA" \
        -keyout ca.key -out ca.pem >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr \
        -subj "/CN=expired.example.com" >/dev/null 2>&1
    cat > ca.cnf <<CAEOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = DEMOCA
certificate = CAPEM
private_key = CAKEY
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
serial = \$dir/serial
default_md = sha256
policy = policy_any
email_in_dn = no
rand_serial = no
[ policy_any ]
commonName = supplied
CAEOF
    sed -i "s|DEMOCA|$WORK/certfix/ca|; s|CAPEM|$WORK/certfix/ca.pem|; s|CAKEY|$WORK/certfix/ca.key|" ca.cnf
    # Buat sertifikat yang SUDAH kedaluwarsa (tanggal eksplisit).
    openssl ca -batch -config ca.cnf -in leaf.csr -out expired.example.com/fullchain.pem \
        -startdate 20200101000000Z -enddate 20200102000000Z -notext >/dev/null 2>&1
  )
  env BASE_DIR="$WORK/unit" TMP_DIR="$WORK/unit/tmp" CERT_LIVE_DIR="$WORK/certfix" CERT_MIN_VALID_DAYS=10 \
    bash -c '
      . "$1" >/dev/null 2>&1
      for d in valid.example.com expiring.example.com expired.example.com missing.example.com; do
        if cert_valid_for "$d"; then echo "$d=LULUS"; else echo "$d=DIPERBARUI"; fi
      done
      echo "valid.days=$(cert_days_left valid.example.com)"
    ' _ "$WORK/repo/common_functions1.sh" > "$WORK/unit/cert.result" 2>/dev/null
  sed 's/^/   /' "$WORK/unit/cert.result" 2>/dev/null
  check "cert 90 hari dianggap masih berlaku"          'grep -qx "valid.example.com=LULUS" "'"$WORK"'/unit/cert.result"'
  check "cert sisa 5 hari (min 10) dipicu perbarui"    'grep -qx "expiring.example.com=DIPERBARUI" "'"$WORK"'/unit/cert.result"'
  check "cert KEDALUWARSA tidak lolos (regresi B17)"   'grep -qx "expired.example.com=DIPERBARUI" "'"$WORK"'/unit/cert.result"'
  check "domain tanpa sertifikat tidak lolos"          'grep -qx "missing.example.com=DIPERBARUI" "'"$WORK"'/unit/cert.result"'
else
  echo "   (openssl tidak tersedia — uji sertifikat dilewati)"
fi

echo
echo "=== 19) Uninstall: anti-menggantung + pembersihan tag cron lama (C7) ==="
# Crontab berisi tag LAMA (versi terdahulu) + cron milik operator.
cat > "$WORK/crontab.uninst" <<'EOF'
# speedtest-boot-fallback (managed)
@reboot bash /root/bagian7_network.sh -postboot >/dev/null 2>&1
*/10 * * * * /usr/bin/uptime >/dev/null 2>&1
EOF
cat > "$WORK/unit/data2.ini" <<'EOF'
ApakahDomainWildcard="Tidak"
ApakahPakaiCloudflare="Tidak"
Domain="speedtest.example.com"
APICloudFlare=""
EmailCloudFlare=""
RegisteredSpeedtestURL="speedtest.example.com"
EOF
mkdir -p "$WORK/base3"; cp -f "$WORK/repo/uninstall.sh" "$WORK/base3/uninstall.sh"
cp -f "$WORK/unit/data2.ini" "$WORK/base3/data.ini"
# Shim iptables 'berbohong': -C selalu "ada", -D tidak menghapus apa pun.
ensure_mock_zt
ensure_local_cli
ensure_sbin_tools
unshare -rm --map-root-user bash -c '
  WORK="'"$WORK"'"
  mount --bind "$WORK/etc" /etc 2>/dev/null
  mount --bind "$WORK/rootfs2" /root 2>/dev/null
  mount --bind "$WORK/localbin" /usr/local/bin 2>/dev/null
  mount --bind "$WORK/usr_sbin_fake" /usr/sbin 2>/dev/null
  export PATH="$WORK/shims:/usr/bin:/bin:/usr/local/bin"
  export HOME=/root
  export E2E_CRONTAB="$WORK/crontab.uninst"
  export E2E_IPTABLES_FAIL=""
  export E2E_IPTABLES_LIE="1"
  cd "$WORK/base3" || exit 1
  timeout 90 bash ./uninstall.sh --force ./data.ini > "$WORK/uninst3.out" 2>&1
  echo "EXIT=$?" > "$WORK/uninst3.exit"
  exit 0
'
grep -E "NAT|masquerade" "$WORK/uninst3.out" | head -5 | sed 's/^/   /'
check "uninstall TIDAK menggantung walau iptables aneh"  '! grep -q "EXIT=124" "'"$WORK"'/uninst3.exit"'
check "uninstall selesai normal (rc=0)"                  'grep -q "EXIT=0" "'"$WORK"'/uninst3.exit"'
check "tag cron lama (boot-fallback) ikut dibersihkan"   '! grep -q "speedtest-boot-fallback" "'"$WORK"'/crontab.uninst"'
check "cron milik operator TIDAK terhapus"               'grep -q "uptime" "'"$WORK"'/crontab.uninst"'
echo
echo "============================================================"
echo "  HASIL:  $PASS PASS / $FAIL FAIL"
echo "  Output lengkap: $WORK/install.out , $WORK/install2.out"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
