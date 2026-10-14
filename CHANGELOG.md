## v8.2.0 — nPerf Server (layanan speedtest kedua)

Fitur baru: **nPerf Server** (`nperf-server` resmi dari `repository.nperf.com`)
dipasang berdampingan dengan OoklaServer, lengkap sampai pembersihan.

**Modul baru `bagian12_nperf_server.sh`**
1. Paket resmi nPerf: repo APT (`signed-by`, khusus Debian 13/trixie memakai
   `trusted=yes` sesuai instruksi nPerf) atau repo RPM (`rhel/<major>.repo`).
   Alpine tidak didukung → dilewati berpesan.
2. Config nPerf **idempotent** (`PORT`/`TLS_PORT`/`REDIRECT_PORT_80`/`REDIRECT_PORT_443`)
   dengan backup ke `$BASE_DIR/nperf/backup/`; default **8081/8443** + redirect
   80→8081 & 443→8443 aktif (config lain dibiarkan bawaan nPerf).
3. Service: systemd `enable/start/restart`, fallback init.d + cron `@reboot`;
   watchdog `/etc/cron.d/nperf-server` bawaan paket dihapus agar tidak bentrok.
4. Verifikasi: HTTP `Server: nPerf` di 8081, TLS 8443, UUID, dan rule
   `nftables` (redirect + anti-DOS) — semuanya non-fatal.
5. Mode `--config-only` (dipakai self-update harian) dan `--status`
   (dipakai `speedtestctl.sh nperf-status`).
6. Kegagalan yang bersifat *deferrable* (repo/jaringan nPerf tidak terjangkau)
   **tidak** menggagalkan instalasi Ookla — dicoba ulang otomatis tiap hari.

**Integrasi**
- `install.sh`: bagian12 dijalankan **sebelum** bagian7 (gerbang ZeroTier tetap
  terakhir), masuk `SUPPORT_FILES` + `chmod`, dan `verify_final` menambah
  pemeriksaan nPerf.
- `speedtest-repo.conf`: blok kebijakan `NPERF_*`.
- `common_functions1.sh`: port 8081/8443 dibuka di firewall (`open_ports`).
- `bagian8`: aksi baru `nperf-status`, `nperf-restart`, `nperf-logs` di
  `speedtestctl.sh`.
- `speedtest-selfupdate.sh`: menegakkan konfigurasi nPerf tiap self-update.
- `auto_update_lib.sh` + `tools/regen-checksums.sh` + MANIFEST: berkas baru ikut
  dipantau/checksum.
- `uninstall.sh`: langkah **7c** membersihkan service, **semua** rule nftables
  ber-comment `nPerfServer` (batas iterasi + verifikasi anti-menggantung), repo +
  kunci, watchdog cron, dan artefak `$BASE_DIR/nperf`; opsi baru **`--purge`**
  untuk menghapus paket + config + UUID (default: paket dipertahankan).
- Uji E2E: seksi 20 baru (instalasi, idempotensi, `--config-only`, `--status`,
  jalur offline, jalur systemd **dan** init.d, bookworm/trixie, uninstall &
  `--purge`).

## v8.1.1 — Perbaikan menyeluruh hasil audit ronde 2 (B13–B20 + C5–C7) — Perbaikan menyeluruh hasil audit ronde 2 (B13–B20 + C5–C7)
Semua temuan `LAPORAN_ANALISA_RONDE2.md` dikerjakan **tanpa terkecuali**, ditambah
temuan baru yang muncul saat uji ulang. Ringkas:

**Reporting / cron (B13, B14, B19)**
1. **Lisensi Ookla CLI diterima non-interaktif.** CLI Ookla menolak berjalan tanpa
   TTY bila lisensi belum diterima → cron reporting selalu gagal senyap.
   `bagian1` kini memanggil CLI dengan `--accept-license --accept-gdpr`
   (`SPEEDTEST_CLI_LICENSE_FLAGS`), dan wrapper cron selalu membawa flag tersebut.
2. **PATH eksplisit di semua artefak cron.** Kunci `CRON_PATH` dipusatkan di
   `speedtest-repo.conf`; wrapper bagian6, `speedtestctl.sh`, artefak bagian4
   (`certbot-renew.sh`, `cert-check.sh`), `speedtest-selfupdate.sh`, dan bagian10
   memuat PATH itu (pustaka `path_augment_from_cron_path()` di common). CLI Ookla
   juga dipanggil via path absolut.
3. **Log & exit code laporan.** Setiap eksekusi menulis satu baris `rc=…` ke
   `$BASE_DIR/report.log` dengan rotasi (`REPORT_LOG_MAX_KB`), plus perintah
   `speedtestctl.sh report` / `report-log`. Kegagalan tidak lagi senyap.

**Jaringan pasca-reboot (B15, B16, C6)**
4. `iptables`/`sysctl`/`ip` dipanggil via path absolut (`network_bin()` mencari
   `/usr/sbin`, `/sbin`, lalu `command -v`) sehingga jalur `@reboot` tidak lagi
   bergantung pada PATH cron.
5. `ipt_ensure()` menambah **verifikasi ulang** (`-C` setelah `-A`); pesan sukses
   NAT hanya muncul bila seluruh rule benar-benar terpasang (log sukses palsu
   dihapus).
6. **NAT dibatasi subnet ZeroTier** (`-s $ZT_SUBNET`), bukan masquerade generik →
   tidak menumbuk NAT Docker/libvirt/K8s dan uninstall bisa menghapus hanya rule
   milik kita.
7. **Kebijakan interface ZeroTier (C6, baru)** — `configure_zt_policy()` di bagian7
   menegakkan `zerotier-cli set <net> allowManaged=1`, `allowDefault=0`,
   `allowGlobal=0` saat instalasi dan pada setiap `--postboot`. `allowDefault=0`
   mencegah server memakai jaringan exit-node sebagai default route-nya sendiri
   (loop / konektivitas putus). Non-fatal: kegagalan hanya WARN.
8. `bagian7` menerima `--postboot` **dan** `-postboot`; sebelumnya `--postboot`
   (yang dipakai bagian10/11 & dokumentasi) mencoba membaca `data.ini` bernama
   `--postboot` lalu berhenti dengan error → NAT pasca-reboot tidak pernah ditegakkan.
9. `enable_ip_forwarding()` menulis nilai runtime (`sysctl -w`) dan memverifikasi
   lewat `sysctl -n` (fallback `/proc/sys`), bukan hanya lewat file `/etc/sysctl.d`.

**Sertifikat (B17, B18)**
10. `cert_valid_for()` benar-benar memeriksa masa berlaku (`openssl x509 -checkend`
    + `cert_days_left()`, ambang `CERT_MIN_VALID_DAYS`, default 10 hari) — versi lama
    hanya memeriksa keberadaan file sehingga sertifikat kedaluwarsa dianggap layak.
11. Verifikasi akhir menambah uji endpoint TLS (`TLS_VERIFY_ENABLED`, `TLS_VERIFY_STRICT`,
    default WARN saja) via `endpoint_*_probe()`.

**Konfigurasi & kebersihan (B20, C5, C7)**
12. **C5**: `RegisteredSpeedtestURL` boleh berisi URL lengkap → dinormalisasi ke
    hostname (`hostname_of()`) sebelum ditulis ke `/etc/hosts`, sehingga muncul
    kembali sebagai bug "hosts tidak cocok".
13. **C7**: `open_ports()` menurunkan port ZeroTier dari `OoklaServer.properties`
    (`ookla_props_ports()`), dengan fallback `8080 5060` — port tidak lagi
    di-hardcode dan tidak ada dua daftar yang bisa menyimpang.
14. **Uninstall anti-menggantung**: `ipt_del_max()` (maksimum N, verifikasi tiap
    langkah, path absolut) menggantikan loop tak terbatas yang bisa hang bila
    backend iptables "mengaku ada" tetapi tidak menghapus. Rule generik warisan
    versi lama dihapus maksimum satu + peringatan operator. Penghapusan CLI hanya
    untuk CLI Ookla (CLI `speedtest-cli` Python milik operator tidak disentuh).
15. `bagian4` menanam `PATH="__CRON_PATH__"` ke artefak cron hasil generate dan
    `certbot-renew.sh` mendeteksi `CERTBOT_BIN`; bagian5 memakai `CERT_LIVE_DIR`.
16. Pemanggilan rentan / tanpa guard dibersihkan (`open_ports` iptables absolut,
    `pkill`/`while iptables`/pemanggilan `speedtest -o` telanjang), dan
    `tools/audit_cmd_deps.py` diperluas (bagian A/B/B2/D/E) untuk menegakkan
    disiplin ini di masa depan.

**Pengujian**
17. Harness E2E diperluas jauh: instalasi Nyata di namespace (`unshare`),
    idempotensi, self-update, gerbang ZeroTier (belum/sudah authorize), uninstall
    (termasuk mode iptables "berbohong" anti-hang), mode pipe `curl | bash`,
    `/etc/hosts` sebagai mount point, uji laporan cron pada PATH minimal (dengan
    kontrol positif/negatif lisensi), NAT `--postboot`, masa berlaku sertifikat
    (fixture), dan normalisasi config. **142 check, 0 FAIL** (log: `e2e-logs/`).

## v8.1.0 — ZeroTier hardcode, hosts localhost, auto-update, SSH kunci GitHub + audit menyeluruh
Ringkas (rincian lengkap: `LAPORAN_IMPLEMENTASI_v8.md`):

1. **ZeroTier hardcode & WAJIB.** Semua input ZeroTier dihapus dari `data.ini`;
   nilai (Network ID, Moon, exit node) dipusatkan di `speedtest-repo.conf`.
   Instalasi GAGAL bila node belum di-authorize di controller (pesan jelas).
   Binary ZeroTier diverifikasi SHA-256 sebelum dipasang.
2. **Mapping `RegisteredSpeedtestURL` → localhost.** Blok `# speedtest-managed`
   ditulis ke `/etc/hosts` (dapat diubah via `HOSTS_FILE`), idempotent, dan
   aman ketika `/etc/hosts` adalah mount point (kasus Docker).
3. **Self-update otomatis tanpa pekerjaan manual.** `speedtest-selfupdate.sh`
   + cron harian, checksum SHA-256 per file, gerbang `bash -n`, staging,
   lock, backup terotasi, dan re-exec installer bila `install.sh` ikut berubah.
4. **Akses SSH siap pakai.** Kunci publik dari `https://github.com/smahud.keys`
   dipasang ke `authorized_keys` (blok penanda), drop-in sshd
   `99-speedtest-managed.conf` diuji dengan `sshd -t` + rollback otomatis.
5. **Audit menyeluruh + perbaikan bug** yang ditemukan saat uji:
   cron ganda (bagian6 tidak idempotent), `bagian8` mati karena `grep -v` di
   bawah `set -e`, parser config `uninstall.sh` menelan komentar inline,
   entri `@reboot` salah-strip sehingga menghapus cron lain, paket cron tidak
   pernah di-*enable*, `getent` tidak portabel, dan celah dependensi lain.
6. **Verifikasi otomatis** di akhir instalasi (OoklaServer, hosts, kunci SSH,
   cron, daemon cron, ZeroTier) + uji E2E 73/73 di namespace mock
   (`tests/e2e_install_test.sh`), ShellCheck bersih, dan audit dependensi
   (`tools/audit_cmd_deps.py`) tanpa temuan.


## Update lanjutan (self-bootstrap + sertifikat interaktif non-CF)
- **install.sh self-bootstrap**: cukup unduh SATU file `install.sh` (mis.
  `wget bit.ly/ooklaserverlinux`). Script otomatis mengunduh file pendukung
  (common + bagian1..8 + ooklaserver.sh) ke `BASE_DIR` dari repo, lalu menjalankan
  semuanya. Sumber unduhan dapat diganti via `REPO_RAW_BASE`.
- **Prioritas data.ini diubah**: argumen → **CWD (tempat command dijalankan)** →
  direktori script. Sesuai kebiasaan menjalankan command di folder data.ini.
- **Auto-restart final**: installer me-restart OoklaServer dari BASE_DIR di akhir,
  sehingga `/root/ooklaserver.sh restart` TIDAK lagi diperlukan.
- **Sertifikat non-Cloudflare = INTERAKTIF** (sesuai permintaan):
  - non-CF wildcard DAN non-CF non-wildcard kini memakai certbot `--manual`
    DNS-01 yang berhenti menampilkan record TXT dan menunggu Anda update DNS
    lalu menekan Enter.
  - Mode Cloudflare tetap sepenuhnya otomatis.
  - Bila tidak ada TTY, installer berhenti dengan pesan jelas (tidak hang/crash).
- **Fix `set -e` + `ini_get`**: `ini_get` selalu return 0 (key kosong tidak lagi
  mematikan script saat dipakai dalam command substitution).


## Arsitektur Path
- **Hapus seluruh hardcode `/root/`.** Tersisa hanya di komentar dokumentasi.
- Tambah `resolve_config_path()`: menentukan `CONFIG_PATH` dari (1) argumen,
  (2) direktori `install.sh`, (3) CWD; error jelas bila tidak ada.
- `BASE_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd)"`.
- `init_paths()` menurunkan semua path dari `$BASE_DIR`:
  `OOKLA_SCRIPT`, `OOKLA_BIN`, `OOKLA_PROPERTIES`, `OOKLA_PIDFILE`,
  `TMP_DIR`, `STATE_FILE`, `LOG_FILE`.
- Tidak ada asumsi CWD; `script_dir()` memakai `BASH_SOURCE`, bukan `pwd`.
- Setiap `bagianX.sh` menerima `CONFIG_PATH` sebagai argumen → mandiri & konsisten.

## Parsing & Validasi `data.ini`
- Tidak lagi `source /root/data.ini` (rawan eksekusi kode). Diganti `ini_get()`
  yang aman: hanya membaca `key=value`, menangani komentar inline & tanda kutip.
- `load_and_validate_config()` memvalidasi: domain & registered URL (format FQDN),
  `Ya/Tidak`, dan token Cloudflare (wajib + panjang minimum) saat CF=Ya.
- Normalisasi `Ya/Tidak` (menerima yes/true/1/no/false/0, dsb).
- Pesan error spesifik bila field wajib kosong / format salah.

## Keamanan
- Token Cloudflare **tidak pernah** dicetak penuh → `mask_secret()` (`abcd********wxyz`).
- Kredensial Cloudflare ditulis dengan `umask 077` + `chmod 600`.
- `data.ini` di-`chmod 600` setelah dibaca.
- State file `chmod 600`.

## Lintas Distro
- `detect_os()` mengenali Debian/Ubuntu, RHEL/CentOS/Alma/Rocky/Fedora, Alpine,
  openSUSE — via `ID`/`ID_LIKE` + fallback file penanda.
- Pemilihan package manager nyata: `apt` / `dnf` / `yum` / `apk` / `zypper`,
  semua non-interaktif (`DEBIAN_FRONTEND=noninteractive`, `-y`, `--no-cache`).
- Nama paket cron dipetakan (`cron` vs `cronie`).
- Certbot: utamakan paket native, fallback snap (Debian/RHEL) bila perlu;
  validasi plugin `dns-cloudflare` benar-benar terpasang.

## Service / Init System
- `detect_init()`: systemd / openrc / none.
- systemd → `ooklaserver.service` (WorkingDirectory + ExecStart/Stop berbasis BASE_DIR).
- OpenRC → `/etc/init.d/ooklaserver` berbasis BASE_DIR.
- Fallback → cron `@reboot` berbasis BASE_DIR.
- **Restart memakai `$OOKLA_SCRIPT` (BASE_DIR), bukan `/root/ooklaserver.sh`.**

## Idempotency
- Lewati Speedtest CLI/certbot bila sudah ada.
- Sertifikat: `--keep-until-expiring` + cek `Expiry Date`.
- `OoklaServer.properties` di-rewrite bersih (hapus baris lama → tulis ulang).
- Cron di-deduplikasi (report & restart & moon-updater).
- `data.ini` tidak pernah ditimpa saat sinkronisasi script ke BASE_DIR.

## Management Tool
- `speedtestctl.sh` di-generate di BASE_DIR (membaca `.speedtest-install.state`),
  mendukung `start|stop|restart|status|uninstall`, jalan dari direktori mana pun.
- `ooklaserver.sh` ditambah command `status`.

## Logging
- Logger berwarna (hanya di TTY) + tee ke `$BASE_DIR/install.log`.
- `print_hash` dipertahankan namanya namun **tanpa `sleep`** (instalasi cepat).

## Lain-lain
- Hapus `serverinstall.sh` (legacy, penuh hardcode `/root`, tidak dipakai).
- ZeroTier (bagian7) dipertahankan & diperbaiki:
  - bug escaping pada `configure_client_settings` diperbaiki,
  - `$EUID` → `id -u` (portabel),
  - dukungan systemd & openrc untuk start service ZT,
  - Network ID/Moon ID dapat dioverride via env (`ZT_NETWORK_ID`, dll),
  - bisa dimatikan via `AktifkanZeroTier="Tidak"`.
- Tambah `data.ini.example`.
