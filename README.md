# Speedtest OoklaServer Installer (Path-Aware Edition) — v8.1.1

Installer otomatis & **non-interaktif** untuk Ookla Speedtest Server, lengkap
dengan sertifikat Let's Encrypt (Cloudflare / non-Cloudflare, wildcard /
non-wildcard), auto-start service (systemd / OpenRC / fallback), cron
maintenance (termasuk **laporan speedtest yang benar-benar terbukti jalan**),
ZeroTier **wajib** (jaringan kontrol operator), dan self-update otomatis.

> **Versi ini telah dirombak total** agar tidak lagi bergantung pada `/root/`.
> Installer bisa dijalankan dari **direktori mana pun**, dan **semua file
> relatif mengikuti lokasi `data.ini`** (BASE_DIR).

---

## 0. Cara Cepat (SATU perintah)

Cukup siapkan **satu file**: `data.ini` di direktori kerja (mis. `/root`),
lalu jalankan satu perintah. Semua dependensi, modul, cron, hosts, dan akses
SSH dipasang otomatis — tidak ada langkah manual lain:

```bash
# 1) isi data.ini (domain + kredensial sertifikat saja)
nano data.ini

# 2) satu perintah install (semua otomatis)
curl -fsSL https://raw.githubusercontent.com/smahud/speedtest/main/install.sh | bash
```

Yang otomatis dikerjakan perintah di atas:

| Aspek | Otomatis | Keterangan |
|---|---|---|
| Dependency dasar | ✅ | bash, curl, wget, tar, jq, ca-certificates, cron, iptables, procps, openssl |
| Layanan cron | ✅ | `enable --now` daemon cron (cron/crond/cronie) supaya jadwal benar-benar jalan |
| ZeroTier | ✅ **WAJIB** | Network ID/Moon ada di `speedtest-repo.conf`; gagal bila node belum di-authorize |
| `/etc/hosts` | ✅ | `RegisteredSpeedtestURL` → localhost (blok `# speedtest-managed`) |
| Akses SSH | ✅ | Kunci dari `github.com/smahud.keys` + drop-in sshd (diuji `sshd -t`, rollback bila gagal) |
| Reporting speedtest | ✅ | CLI Ookla diverifikasi + **uji laporan end-to-end** saat instalasi, lalu cron per jam & per 5 menit |
| Self-update | ✅ | Cron harian menarik repo, verifikasi SHA-256, backup, dan re-exec installer bila perlu |
| Sertifikat | ✅ / manual | Cloudflare = otomatis + renewal terjadwal; DNS manual = interaktif sekali + pemantau masa berlaku |
| Verifikasi akhir | ✅ | Laporan `[OK]`/`[WARN]` untuk OoklaServer, hosts, kunci SSH, cron, daemon cron, ZeroTier, **CLI+laporan**, dan **TLS endpoint** |

Catatan:
- `data.ini` **tidak lagi** memuat pengaturan ZeroTier (dihapus sejak v8);
  semua nilai operasional ada di `speedtest-repo.conf`.
- Ingin repo/URL lain? Set `REPO_RAW_BASE` sebelum menjalankan installer.
- Dokumentasi perubahan + hasil uji: `CHANGELOG.md`, `OPTIMIZATION_NOTES.md`,
  `LAPORAN_ANALISA_RONDE2.md` (analisa bug + perbaikan v8.1.1).

---

## 1. Cara Kerja Path (PENTING)

- **`CONFIG_PATH`** ditentukan dengan prioritas:
  1. argumen pertama (`./install.sh /path/ke/data.ini`),
  2. current working directory,
  3. direktori tempat `install.sh` berada,
  4. jika tidak ditemukan → error yang jelas.
- **`BASE_DIR = $(cd "$(dirname "$CONFIG_PATH")" && pwd)`**.
- **Semua** file output, temporary, script generated, config, log, dan service
  script mengikuti `$BASE_DIR`. Tidak ada `/root/` yang di-hardcode.

Contoh:

| Lokasi `data.ini`                  | BASE_DIR                  |
|------------------------------------|---------------------------|
| `/opt/speedtest/data.ini`          | `/opt/speedtest/`         |
| `/home/user/speedtest/data.ini`    | `/home/user/speedtest/`   |

---

## 2. Menyiapkan `data.ini`

Salin contoh lalu sesuaikan:

```bash
cp data.ini.example data.ini
nano data.ini
```

Field:

| Field                    | Wajib | Keterangan |
|--------------------------|-------|------------|
| `ApakahDomainWildcard`   | ✓     | `Ya` / `Tidak` |
| `ApakahPakaiCloudflare`  | ✓     | `Ya` / `Tidak` |
| `Domain`                 | ✓     | wildcard → domain utama (`example.com`); non-wildcard → FQDN (`speedtest.example.com`) |
| `APICloudFlare`          | ✓ (jika CF=Ya) | Token Cloudflare (DNS edit) |
| `RegisteredSpeedtestURL` | ✓     | Hostname server speedtest terdaftar (boleh URL lengkap — otomatis dinormalisasi ke hostname) |
| `EmailCloudFlare`        | opsional | Email akun CF (untuk Global API Key) |

Installer **memvalidasi** semua field sebelum lanjut; token Cloudflare
**tidak pernah** dicetak penuh (selalu disamarkan, mis. `v1.0********mnop`).

### Mode Sertifikat

| Mode | Perilaku |
|------|----------|
| Cloudflare + wildcard | **Otomatis** (DNS-01 via API, non-interaktif) |
| Cloudflare + non-wildcard | **Otomatis** (DNS-01 via API, non-interaktif) |
| **non-Cloudflare + wildcard** | **INTERAKTIF**: certbot menampilkan record TXT, Anda update DNS lalu tekan Enter |
| **non-Cloudflare + non-wildcard** | **INTERAKTIF**: certbot menampilkan record TXT, Anda update DNS lalu tekan Enter |

> Untuk mode non-Cloudflare, **jalankan installer langsung di terminal SSH/console**
> (bukan via pipe/cron) karena membutuhkan input Enter setelah update DNS.
> Jika tidak ada terminal, installer berhenti dengan pesan error yang jelas.

---

## 3. Kebijakan Operasional Terpusat — `speedtest-repo.conf`

Semua kebijakan yang **sama untuk semua server** ada di satu file ini (bukan di
`data.ini`), sehingga bisa diubah sekali lalu tersebar otomatis lewat
self-update:

| Kunci | Default | Fungsi |
|---|---|---|
| `ZT_NETWORK_ID` / `ZT_MOON_ID` / `ZT_MOON_CONFIG_URL` | nilai operator | ZeroTier **wajib** (network kontrol + moon) |
| `ZT_INSTALL_IF_MISSING`, `ZT_REQUIRE_AUTHORIZATION`, `ZT_ENABLE_EXIT_NODE` | `Ya` | paksa install ZT, wajib authorize, dan aktifkan exit node (NAT) |
| `HOSTS_FILE`, `HOSTS_MANAGED`, `HOSTS_MARKER` | `/etc/hosts`, `Ya`, `speedtest-managed` | mapping `RegisteredSpeedtestURL` → 127.0.0.1 |
| `SSH_KEYS_URL`, `SSH_TARGET_USERS`, `SSH_ROOT_LOGIN`, `SSH_DISABLE_PASSWORD_AUTH` | `github.com/smahud.keys`, `root`, `prohibit-password`, `Tidak` | akses SSH otomatis |
| `AUTO_UPDATE_ENABLED`, `AUTO_UPDATE_*` | harian 03:17 | self-update (verifikasi SHA-256 + backup + re-exec) |
| `REPORT_HOURLY_ENABLED`, `REPORT_FAST_ENABLED`, `REPORT_FAST_SCHEDULE`, `REPORT_JITTER_MIN_MAX`, `REPORT_LOG_MAX_KB` | `Ya`, `Ya`, `*/5 * * * *`, `50`, `512` | jadwal laporan speedtest, jeda acak (menit), rotasi log (KB) |
| `SPEEDTEST_CLI_PATH`, `SPEEDTEST_CLI_LICENSE_FLAGS`, `SPEEDTEST_SMOKE_TEST`, `SPEEDTEST_SMOKE_TIMEOUT` | `/usr/local/bin/speedtest`, `--accept-license --accept-gdpr`, `Ya`, `150` | CLI Ookla + penerimaan lisensi non-interaktif + uji laporan |
| `CRON_PATH` | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` | PATH untuk **semua** artefak cron (penyebab bug lama: laporan & NAT mati senyap) |
| `TLS_VERIFY_ENABLED`, `TLS_VERIFY_STRICT`, `CERT_MIN_VALID_DAYS` | `Ya`, `Tidak`, `10` | verifikasi endpoint TLS + ambang masa berlaku sertifikat |

> `CERT_MIN_VALID_DAYS=10` berarti sertifikat dengan sisa masa berlaku < 10
> hari dianggap **tidak layak** dan akan diterbitkan ulang (versi lama hanya
> memeriksa keberadaan file/sertifikat, sehingga sertifikat kedaluwarsa
> dianggap "masih berlaku").

---

## 4. Reporting Speedtest (cron & manual)

Yang berjalan otomatis setelah instalasi:

| Jadwal | Perintah | Fungsi |
|---|---|---|
| `0 * * * *` | `$BASE_DIR/cron-speedtest.sh` | laporan penuh tiap jam (jeda acak 0–50 menit) |
| `*/5 * * * *` | `$BASE_DIR/cron-speedtest5.sh` | laporan cepat tiap 5 menit (dibatasi CPU bila systemd aktif) |
| `@reboot` | `$BASE_DIR/bagian10_hosts_ssh.sh --postboot` | hosts + kunci SSH + NAT ZeroTier ditegakkan ulang |
| `17 3 * * *` | `$BASE_DIR/speedtest-selfupdate.sh` | self-update + penegakan konfigurasi |
| `41 4 * * *` / `23 4 * * *` | `cert-check.sh` / `certbot-renew.sh` | pemantau masa berlaku / renewal otomatis (mode Cloudflare) |

Detail penting:

- Wrapper cron memuat **PATH eksplisit** (`$CRON_PATH`), **path absolut** CLI
  Ookla, dan **flag lisensi** — cron tidak punya TTY, dan CLI Ookla menolak
  berjalan tanpa `--accept-license` (ini penyebab laporan "diam-diam gagal"
  pada versi sebelumnya).
- Setiap eksekusi menulis satu baris status ke `$BASE_DIR/report.log`
  (`rc=0`/`rc≠0`); log dirotasi otomatis bila melebihi `REPORT_LOG_MAX_KB`.
- Saat instalasi, installer menjalankan **satu uji laporan end-to-end** ke
  `RegisteredSpeedtestURL` (lewat `/etc/hosts` = 127.0.0.1, jadi **tidak**
  memakai kuota internet) dan melaporkan hasilnya di verifikasi akhir.
- Manual: `$BASE_DIR/speedtestctl.sh report` (jalankan sekarang) dan
  `$BASE_DIR/speedtestctl.sh report-log` (lihat log).

---

## 5. Cara Pakai per OS

> **PENTING:** Jalankan command **di direktori tempat `data.ini` berada**.
> `install.sh` bersifat **self-bootstrap**: cukup unduh SATU file `install.sh`,
> ia akan otomatis mengunduh file pendukung (common + bagian0..11 +
> ooklaserver.sh) ke `BASE_DIR` (folder `data.ini`), lalu menjalankan semuanya
> dan **restart otomatis** di akhir.

### Debian / Ubuntu (apt)
```bash
cd /folder/berisi/data.ini
apt update && apt install -y bash wget ca-certificates
wget -O install.sh https://URL-FINAL/install.sh
chmod a+x install.sh
./install.sh
```

### RedHat / CentOS / AlmaLinux / Rocky / Fedora (yum/dnf)
```bash
cd /folder/berisi/data.ini
yum install -y bash wget ca-certificates || dnf install -y bash wget ca-certificates
wget -O install.sh https://URL-FINAL/install.sh
chmod a+x install.sh
./install.sh
```

### Alpine (apk)
```bash
cd /folder/berisi/data.ini
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories
apk update && apk upgrade
apk add bash wget ca-certificates
wget -O install.sh https://URL-FINAL/install.sh
chmod a+x install.sh
bash ./install.sh        # gunakan 'bash' di Alpine (shell default = busybox ash)
```

### Menentukan data.ini di lokasi lain (opsional argumen)
```bash
./install.sh /opt/speedtest/data.ini
```

### Catatan sumber unduhan
`install.sh` mengunduh file pendukung dari
`https://raw.githubusercontent.com/smahud/speedtest/main`, dan otomatis memakai
snapshot imutabel `versions/<VERSION>/` bila tersedia. Sumber dapat diganti:
```bash
REPO_RAW_BASE="https://raw.githubusercontent.com/USER/REPO/BRANCH" ./install.sh
```

---

## 6. Management

Tool `speedtestctl.sh` dibuat di `$BASE_DIR` dan bisa dijalankan dari mana saja:

```bash
$BASE_DIR/speedtestctl.sh status       # status proses + port yang dipakai
$BASE_DIR/speedtestctl.sh start|stop|restart
$BASE_DIR/speedtestctl.sh report       # jalankan 1x laporan speedtest sekarang
$BASE_DIR/speedtestctl.sh report-log   # 50 baris terakhir log laporan
$BASE_DIR/speedtestctl.sh logs         # 50 baris terakhir install.log
$BASE_DIR/speedtestctl.sh uninstall
```

Self-update manual (opsional, sebenarnya sudah otomatis harian):

```bash
bash $BASE_DIR/speedtest-selfupdate.sh --dry-run    # cek saja
bash $BASE_DIR/speedtest-selfupdate.sh              # terapkan
```

Service auto-start dibuat sesuai init system:
- **systemd** → `ooklaserver.service`
- **OpenRC** (Alpine) → `/etc/init.d/ooklaserver`
- **fallback** → cron `@reboot`

---

## 7. Idempotency

Installer aman dijalankan ulang:
- Speedtest CLI & certbot dilewati bila sudah ada.
- Sertifikat dilewati bila **masih layak** (`openssl x509 -checkend`,
  ambang `CERT_MIN_VALID_DAYS`).
- OoklaServer.properties di-rewrite secara bersih (tanpa duplikasi baris).
- Cron job di-deduplikasi (tag `(managed)` + pencocokan baris penuh).
- `data.ini` **tidak pernah** ditimpa.

---

## 8. Uninstall

```bash
bash $BASE_DIR/uninstall.sh --force     # atau tanpa --force untuk konfirmasi
```

Yang dihapus: OoklaServer (binary/service/cron/properties), sertifikat domain
Anda, kredensial Cloudflare, **hanya CLI Ookla** (CLI `speedtest-cli` Python
milik operator **tidak** disentuh), ZeroTier (binary + script + moon updater),
cron milik installer ini saja, entri `/etc/hosts` terkelola, blok kunci SSH
terkelola, drop-in sshd terkelola, dan **rule NAT ter-scope ZeroTier**.

Yang **disisakan**: `data.ini`, `/var/lib/zerotier-one` (agar Node ID tetap
sama saat instal ulang), `IP forwarding` host, dan seluruh rule NAT milik
layanan lain (Docker/libvirt/K8s).

> Penghapusan rule iptables dibatasi jumlahnya (bukan loop tak terbatas) dan
> memakai path absolut — versi lama bisa menggantung tanpa batas bila backend
> iptables menjawab "ada" tetapi tidak menghapus rule.

---

## 9. Log & Diagnosa

| File | Isi |
|---|---|
| `$BASE_DIR/install.log` | log lengkap instalasi |
| `$BASE_DIR/update.log` | log self-update & boot-sync |
| `$BASE_DIR/report.log` (+`.1`) | status setiap laporan speedtest (rc, URL) |
| `/var/log/zt-moon-updater.log` (+`.1`) | updater moon ZeroTier |

Cek cepat:

```bash
tail -20 $BASE_DIR/report.log                       # laporan jalan?
bash $BASE_DIR/speedtestctl.sh status               # server hidup?
zerotier-cli listnetworks                           # node ter-authorize?
openssl s_client -connect 127.0.0.1:443 -servername <Domain> </dev/null | grep Verify
```

Masalah umum:

| Gejala | Penyebab & solusi |
|---|---|
| `report.log` berisi `rc=127` | CLI Ookla tidak ada di `SPEEDTEST_CLI_PATH` → jalankan `bash $BASE_DIR/bagian1_install_dependency.sh` |
| `report.log` berisi `rc=1` + pesan lisensi | jalankan sekali: `/usr/local/bin/speedtest --accept-license --accept-gdpr -L` (wrapper cron sudah membawa flag ini otomatis) |
| NAT ZeroTier hilang setelah reboot | `bash $BASE_DIR/bagian7_network.sh --postboot` (sudah dipasang sebagai cron `@reboot`) |
| Instalasi berhenti di bagian7 | node belum di-authorize di controller: authorize Node ID yang ditampilkan |
| TLS `[WARN]` di verifikasi akhir | endpoint HTTPS belum melayani domain tsb; uji manual dengan perintah `openssl s_client` di atas |

---

## 10. Pengujian & Audit

```bash
bash tests/e2e_install_test.sh          # uji E2E lengkap di namespace mock (tidak menyentuh sistem)
python3 tools/audit_cmd_deps.py         # audit dependensi perintah + PATH konteks cron
shellcheck -s bash -e SC1091,SC1090,SC2154,SC2034 *.sh tools/*.sh tests/*.sh
bash -n *.sh                            # validasi sintaks seluruh skrip
```

Hasil pengujian rilis **v8.1.1**: `150 PASS / 0 FAIL` (log tersimpan di
`e2e-logs/run11.log`), audit dependensi `[OK]` tanpa temuan, dan ShellCheck
**0 temuan** pada seluruh skrip produksi (harness memakai pengecualian
`SC2016/SC2012/SC2086` yang didokumentasikan di kepalanya).

- `tests/e2e_install_test.sh` menjalankan instalasi nyata di dalam
  `unshare -rm --map-root-user` dengan `/etc`, `/root`, `/usr/local/bin`,
  `/usr/sbin`, dan semua tool sistem **di-mock**: menguji instalasi, idempotensi,
  self-update, gerbang ZeroTier, uninstall, mode pipe (`curl | bash`), kasus
  container, laporan cron pada `PATH` minimal, NAT `--postboot`, masa berlaku
  sertifikat, dan anti-menggantung uninstall.
- `tools/audit_cmd_deps.py` menegakkan: setiap perintah opsional wajib
  ber-guard, dan setiap artefak cron wajib menyetel PATH.

---

## 11. Struktur File

```
install.sh                            # orchestrator (resolve path, validasi, jalankan bagian)
speedtest-repo.conf                   # kebijakan operasional terpusat (ZT, hosts, SSH, cron, reporting)
common_functions1.sh                  # pustaka: path, ini, OS/pkg/init, logging, masking, Ookla+SSH+cert helper
auto_update_lib.sh                    # pustaka self-update (dipakai selfupdate/bagian7/10/11)
speedtest-selfupdate.sh               # self-update harian (checksum, backup, re-exec, boot-sync)
bagian0.sh                            # banner
bagian1_install_dependency.sh         # dependency + CLI Ookla + lisensi + kredensial Cloudflare
bagian2_install_ooklaserver.sh        # install OoklaServer ke BASE_DIR
bagian3_install_certbot.sh            # install certbot (+plugin CF) lintas distro
bagian4_install_server_certificate.sh # terbitkan sertifikat (4 mode) + jadwal renewal/pemantau
bagian5_update_ooklaserver.sh         # set path cert + restart + verifikasi endpoint (HTTP/TLS)
bagian6_automaintenance.sh            # cron reporting speedtest (wrapper + rotasi log)
bagian7_network.sh                    # ZeroTier WAJIB + exit node/NAT (mendukung --postboot)
bagian8_cek_konfigurasi.sh            # service auto-start + verifikasi + speedtestctl.sh
bagian9_ssh_access.sh                 # akses SSH (kunci GitHub + konfigurasi sshd)
bagian10_hosts_ssh.sh                 # entri /etc/hosts + penegakan SSH (dipanggil @reboot & self-update)
bagian11_self_update.sh               # penjadwalan self-update + boot-sync
ooklaserver.sh                        # script resmi Ookla (+ command status)
uninstall.sh                          # pembersihan menyeluruh (aman untuk sistem)
data.ini.example                      # contoh konfigurasi
tests/e2e_install_test.sh             # uji E2E mock-namespace
tools/regen-checksums.sh              # regenerasi checksums.sha256
tools/publish-version.sh              # snapshot versi (versions/<VERSION>/)
tools/audit_cmd_deps.py               # audit dependensi perintah & PATH cron
```
