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

rm -rf "$WORK"
mkdir -p "$WORK"/{base,repo,shims,rootfs,localbin,etc_hosts_dir,usr_sbin_fake}

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
         update-rc.d sysctl ufw firewall-cmd restorecon git sed_guard; do
  mk "$t" 'exit 0'
done

cat > "$WORK/shims/iptables" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "-C" ] && exit 1; done
exit 0
EOF
chmod +x "$WORK/shims/iptables"

cat > "$WORK/shims/ip" <<'EOF'
#!/bin/sh
case "$*" in
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
if [ "${1:-}" = "--version" ]; then echo "Speedtest by Ookla 1.2.0.84"; exit 0; fi
echo "mock speedtest run"; exit 0
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

ns_run() {
  # $1 = perintah bash yang dijalankan di dalam namespace
  # $2 = env tambahan (opsional)
  ensure_mock_zt
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
check "NAT ZT dipulihkan via bagian10 -postboot"       'grep -q "bagian7_network.sh\" -postboot" "'"$WORK"'/base/bagian10_hosts_ssh.sh"'
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
check "helper user_home dipakai (tanpa getent)"       'grep -q "user_home" "'"$WORK"'/base/bagian10_hosts_ssh.sh" && ! grep -q "getent passwd" "'"$WORK"'/base/bagian10_hosts_ssh.sh"'
check "moon updater menanam MOON_ID dari repo (fix heredoc)" 'grep -q "\"72ff30f973\"" "'"$WORK"'/localbin/zt-moon-updater.sh" 2>/dev/null'
check "moon updater memakai path absolut zerotier-cli" 'grep -q "ZT_CLI=\"/usr/sbin/zerotier-cli\"" "'"$WORK"'/localbin/zt-moon-updater.sh" 2>/dev/null'
check "properties memuat path sertifikat"             'grep -q "openSSL.server.certificateFile" "'"$WORK"'/base/OoklaServer.properties"'
check "state file menyimpan VERSION & REPO"           'grep -q "^VERSION=" "'"$WORK"'/base/.speedtest-install.state"'
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
echo "=== 3) Self-update otomatis (repo naik ke 8.1.1) ==="
echo "8.1.1" > "$WORK/repo/VERSION"
sed -i 's/Menjalankan Auto Install Speedtest OoklaServer/Menjalankan Auto Install Speedtest OoklaServer [UPDATED-8.1.1]/' "$WORK/repo/bagian0.sh"
rehash_mock_repo
ns_run 'bash ./speedtest-selfupdate.sh --force > "$WORK/selfupdate.out" 2>&1; echo "EXIT=$?" > "$WORK/selfupdate.exit"; exit 0'
tail -8 "$WORK/selfupdate.out" | sed 's/^/   /'

check "self-update berhasil (rc=0)"           'grep -q "EXIT=0" "'"$WORK"'/selfupdate.exit"'
check "VERSION terpasang naik ke 8.1.1"       '[ "$(head -1 "'"$WORK"'/base/VERSION")" = "8.1.1" ]'
check "file bagian0 ikut ter-update"          'grep -q "UPDATED-8.1.1" "'"$WORK"'/base/bagian0.sh"'
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
ns_run 'E2E_ZT_STATE=ok bash ./bagian7_network.sh ./zt_test.ini > "$WORK/ztok.out" 2>&1; echo "EXIT=$?" > "$WORK/ztok.exit"; exit 0'
grep -iE "orbit|authorize|terhubung|Network ID" "$WORK/ztok.out" | head -5 | sed 's/^/   /'
check "bagian7 SUKSES saat node ter-authorize"  'grep -q "EXIT=0" "'"$WORK"'/ztok.exit"'
check "orbit moon dijalankan"                   'grep -qiE "orbit|moon" "'"$WORK"'/ztok.out"'
check "orbit moon tercatat di output"           'grep -qi "orbit" "'"$WORK"'/ztok.out"'

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
echo "============================================================"
echo "  HASIL:  $PASS PASS / $FAIL FAIL"
echo "  Output lengkap: $WORK/install.out , $WORK/install2.out"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
