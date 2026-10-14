# Analisa Runtime End-to-End & Optimalisasi

Dokumen ini merangkum analisa logika/alur runtime, bug yang ditemukan, dan
perbaikan yang diterapkan agar installer berjalan mulus di **Debian/Ubuntu**,
**RHEL/CentOS/Alma/Rocky/Fedora**, dan **Alpine**.

## Alur Runtime (ringkas)
1. `install.sh` → resolve `data.ini` (arg → CWD → script dir) → set `BASE_DIR`.
2. Self-bootstrap: unduh/sinkron file pendukung ke `BASE_DIR`.
3. Source `common_functions1.sh` → `detect_os` → `detect_init`.
4. `pkg_update` + install dependency dasar (per package manager).
5. `load_and_validate_config` (validasi + masking token).
6. Jalankan bagian0..8, lalu auto-restart final.

## Bug & Perbaikan

### B1. (KRITIS) bagian7 `-postboot` gagal saat boot
`/usr/local/bin/zt-exitnode.sh -postboot` (dipanggil systemd saat boot)
men-`source` `common_functions1.sh` lewat `SPEEDTEST_SCRIPT_DIR`, padahal saat
boot variabel itu kosong → file tidak ditemukan → service crash tiap boot.
**Fix:** bagian7 hanya butuh fungsi minimal saat `-postboot`. Jadikan source
common bersifat *opsional* + sediakan fallback logger/`detect_os` mandiri.
Service systemd juga menyalin common ke `/usr/local/bin` & set
`Environment=SPEEDTEST_SCRIPT_DIR=...`.

### B2. (KRITIS) OoklaServer start prematur tanpa sertifikat
`ooklaserver.sh install -f` memanggil `restart_if_running` → start daemon
SEBELUM path sertifikat di-set (bagian5). Dengan `ssl.useLetsEncrypt=true`
tanpa cert, daemon bisa gagal start. **Fix:** di bagian2 jangan langsung start;
pakai `install -f` lalu `stop`. Start sebenarnya dilakukan bagian5 setelah cert
siap. Juga komentari `ssl.useLetsEncrypt` saat belum ada cert.

### B3. bagian5 selalu re-download biner (boros, kurang idempotent)
`ooklaserver.sh install -f` mengunduh ulang biner tiap run. **Fix:** hanya
`stop` → tulis properties → `start`. Tidak reinstall biner jika sudah ada.

### B4. `sort -u` merusak urutan crontab
`crontab - | sort -u` mengurutkan SELURUH baris crontab user (merusak urutan &
menggabung entri tak terkait). **Fix:** dedup hanya baris milik kita
(filter by tag), pertahankan sisanya apa adanya.

### B5. `tar -C /usr/local/bin` tanpa `mkdir -p`
Di image minimal, `/usr/local/bin` bisa belum ada → `tar` gagal. **Fix:**
`mkdir -p /usr/local/bin` dulu.

### B6. Verifikasi publik `curl -4` saja
Host IPv6-only gagal deteksi IP & verifikasi. **Fix:** coba IPv4 lalu IPv6,
dan jangan jadikan kegagalan verifikasi sebagai error fatal (hanya warning).

### B7. Alpine: `apk add` butuh repo community untuk certbot-dns-cloudflare
**Fix:** bagian3 memastikan repo community aktif sebelum `apk add` plugin.

### B8. Alpine: paket `cron` vs `cronie` vs busybox crond
**Fix:** pemetaan paket cron sudah benar (`cronie`), tambah penanganan service
`crond` OpenRC + cek ketersediaan `crontab`.

### B9. `pkg_install` gagal-diam menyembunyikan error penting
`pkg_install pkg >/dev/null 2>&1` menelan semua error. **Fix:** untuk paket
KRUSIAL (mis. certbot) error tetap tampil; untuk paket opsional tetap diredam.

### B10. Idempotensi kredensial Cloudflare
`bagian1` menulis ulang kredensial tiap run (OK), tapi `rm` lama bisa warning.
**Fix:** tulis atomik via temp + `mv`, umask 077.

### B11. `set -e` + pipeline `grep | grep` di bagian5
Jika `grep` pertama tidak menemukan match (file properties minimal), exit code
non-zero bisa menggagalkan pipeline. **Fix:** bungkus dengan `|| true` yang aman
dan gunakan file temp.

### B12. ENTROPI: deteksi "OoklaServer berjalan" via pgrep -x
Kompatibel busybox (Alpine) — sudah diverifikasi `pgrep -x` didukung busybox.

### B13. (FIX) Cron `$RANDOM` & `%` tidak portabel
`sleep $(( RANDOM % 50 ))m` di crontab gagal karena cron memakai `/bin/sh`
(ash/dash di Alpine), `$RANDOM` kosong → syntax error; `%` di crontab berarti
newline. **Fix:** jitter ditentukan saat install (angka tetap), dan `%` untuk
CPUQuota di-escape jadi `\%`.

### B14. (FIX) Komentar inline di baris cron
Tag `# managed` di belakang perintah cron diperlakukan literal oleh busybox
crond (Alpine). **Fix:** tag ditulis sebagai baris komentar TERPISAH untuk
semua cron (report, daily-restart, @reboot).

### B16. (FIX) `ensure_support_files` tidak memperbarui file yang sudah ada
Installer bootstrap hanya mengunduh file jika file tersebut tidak ada di disk. Hal ini menyebabkan update skrip (patch) tidak terunduh jika instalasi sebelumnya gagal.
**Fix:** Skrip sekarang selalu mencoba menyelaraskan (sync/update) file pendukung ke versi terbaru dari repository saat proses bootstrap dijalankan.

### B17. (FIX) Argumen parsing `ooklaserver.sh` tidak kompatibel BusyBox
Loop parsing argumen sebelumnya memicu pesan `Usage` pada beberapa shell minimal.
**Fix:** Menyederhanakan loop parsing argumen agar lebih robust dan mengabaikan flag `-f` secara eksplisit tanpa memicu error.

### B18. (OPTIMASI) Paket `iptables` di Alpine
Modul ZeroTier membutuhkan `iptables` untuk NAT.
**Fix:** Memastikan paket `iptables` terpasang di Alpine via dependency dasar di `install.sh`.

## Ronde 2 (v8.1.1) — bug yang ditemukan lewat uji runtime nyata

### B13. (KRITIS) Lisensi Ookla CLI tidak pernah diterima → cron reporting selalu gagal
CLI Ookla memerlukan penerimaan lisensi/eula; pada konteks tanpa TTY (cron) ia
menolak berjalan (`License not accepted. Exiting.`, exit 1). Wrapper cron v8.1.0
memanggil `speedtest -o <host> …` → tiap laporan gagal, dan output dibuang.
**Bukti empiris:** `speedtest -s <id>` exit 1 tanpa `--accept-license`;
`-L --accept-license --accept-gdpr` exit 0 dan menulis
`~/.config/ookla/speedtest-cli.json`.
**Fix:** `bagian1` menerima lisensi saat instalasi (`SPEEDTEST_CLI_LICENSE_FLAGS`),
wrapper cron selalu membawa flag yang sama.

### B14. (TINGGI) PATH cron tidak memuat `/usr/local/bin` (lokasi CLI Ookla)
Cron berjalan dengan `PATH=/usr/bin:/bin`; CLI Ookla dipasang di `/usr/local/bin`.
**Fix:** `CRON_PATH` (di `speedtest-repo.conf`) ditanam eksplisit ke setiap artefak
cron; CLI juga dipanggil via path absolut + fallback `command -v`.

### B15. (TINGGI) `iptables`/`sysctl` tanpa path absolut pada jalur `@reboot`
Binary jaringan ada di `/usr/sbin` (atau `/sbin`) yang tidak terlihat pada PATH
cron minimal → NAT pasca-reboot tidak pernah terpasang.
**Fix:** `network_bin()` mencari `/usr/sbin`, `/sbin`, baru `command -v`.

### B16. (SEDANG) Kegagalan `ipt_ensure` disembunyikan + log sukses palsu
Pemanggilan `|| true` membuat NAT yang gagal tetap tercatat "berhasil".
**Fix:** kegagalan dihitung (`failed=1`), rule diverifikasi ulang dengan `-C`,
dan `log_ok` hanya muncul bila semuanya benar-benar terpasang.

### B17. (SEDANG) `cert_valid_for` hanya memeriksa keberadaan sertifikat
Sertifikat kedaluwarsa tetap dianggap "valid" → tidak pernah diperbarui.
**Fix:** `openssl x509 -checkend` + `cert_days_left()` dengan ambang
`CERT_MIN_VALID_DAYS`; `certbot-renew.sh`/`cert-check.sh` memakai pustaka bersama.

### B18. (RENDAH) Tidak ada verifikasi HTTPS end-to-end
Sertifikat "ada" belum berarti endpoint TLS melayani domain tersebut.
**Fix:** `endpoint_http_probe()` / `endpoint_tls_probe()` di verifikasi akhir
(`TLS_VERIFY_ENABLED`, `TLS_VERIFY_STRICT`; default WARN agar tidak memblokir).

### B19. (RENDAH) Output wrapper cron dibuang tanpa log
Laporan gagal tanpa jejak apa pun. **Fix:** `report.log` (+rotasi
`REPORT_LOG_MAX_KB`), satu baris per eksekusi dengan `rc=`, dan aksi
`speedtestctl.sh report|report-log`.

### B20. (INFO) Kebersihan pemanggilan & port
Port ZeroTier di-`open_ports()` kini diturunkan dari `OoklaServer.properties`
(`ookla_props_ports()`, fallback `8080 5060`) — satu sumber kebenaran, tidak
mungkin menyimpang dari konfigurasi server.

### C5. (FIX) `RegisteredSpeedtestURL` boleh berupa URL lengkap
Nilai mentah ditulis ke `/etc/hosts` (mis. `https://host/path`) sehingga mapping
tidak pernah cocok. **Fix:** `hostname_of()` menormalkan sebelum dipakai
(hosts, verifikasi, laporan) — diuji sebagai unit test.

### C6. (FIX, baru) Kebijakan interface ZeroTier belum pernah diterapkan
Topologi exit-node mensyaratkan setelan sisi server:
`allowManaged=1` (route/IP terkelola tetap dipasang),
`allowDefault=0` (**mencegah server memakai jaringan exit-node sebagai default
route-nya sendiri** — bila controller mem-push `0.0.0.0/0`, host dapat mengirim
traffic internetnya kembali ke tunnel miliknya sendiri → loop/putus koneksi),
`allowGlobal=0` (route bertanda global diabaikan di sisi server).
**Fix:** `configure_zt_policy()` di bagian7 dipanggil saat instalasi dan pada
setiap `--postboot`, non-fatal (WARN) agar tidak memblokir instalasi bila
`zerotier-cli` belum siap.

### C7. (FIX) `uninstall.sh` bisa menggantung tak terbatas
Loop `while iptables -C …; do iptables -D …; done` tanpa batas iterasi dan tanpa
path absolut: bila backend "mengaku ada" tetapi gagal menghapus, uninstall
menggantung selamanya. **Fix:** `ipt_del_max()` (batas iterasi, verifikasi tiap
penghapusan, path absolut `IPT_BIN`). Diuji dengan mode iptables "berbohong"
(`E2E_IPTABLES_LIE`) di bawah `timeout`.

### C8. (FIX) `bagian7 --postboot` membaca `data.ini` bernama `--postboot`
Pengecualian mode hanya mengenali `-postboot` (satu strip), sementara cron
`@reboot` bagian10 memanggil `--postboot` → pesan `data.ini tidak ditemukan:
'--postboot'`, NAT pasca-reboot **tidak pernah** ditegakkan (ditemukan pada E2E
run #7). **Fix:** kedua bentuk diterima; mode postboot memakai
`SPEEDTEST_SCRIPT_DIR` sebagai BASE_DIR dan melewati pembacaan config sepenuhnya.

### C9. (FIX) Deteksi IP forwarding gagal di lingkungan terbatas
Nilai verifikasi hanya dibaca dari `/proc/sys/net/ipv4/ip_forward`; pada container
dengan `/proc/sys` read-only (atau saat `sysctl` tersedia tetapi nilai runtime
belum diterapkan) fungsi mengembalikan WARN walau `/etc/sysctl.d` sudah benar.
**Fix:** nilai runtime diterapkan dengan `sysctl -w`, verifikasi lewat
`sysctl -n` lalu fallback `/proc/sys`.

## Ronde 3 (v8.2.0) — nPerf Server (layanan kedua)

**Risiko yang dikendalikan (hasil bedah paket resmi nperf-server 2.2.11):**
1. **Path paket bersifat tetap** (`/usr/bin/nPerfServer`, `/etc/nperf/nperf-server.conf`,
   `/var/lib/nperf-server/`, unit `nperf-server`) → tidak di-relokasi; yang
   mengikuti `BASE_DIR` hanya artefak repo (`$BASE_DIR/nperf/`).
2. **`PORT` wajib 8080 atau 8081** → karena 8080 dipakai OoklaServer, dipakai
   8081; nilai lain ditolak & dikembalikan ke 8081 dengan peringatan.
3. **Rule anti-DOS `nftables` bertahan setelah service berhenti**
   (`inet filter input … comment "nPerfServer"`) → pembersihannya di
   `uninstall.sh` langkah 7c, dengan batas iterasi + verifikasi tiap langkah
   (pola yang sama dengan perbaikan C7 di iptables) agar tidak pernah menggantung.
4. **Sertifikat TLS 8443 milik nPerf** (CERT-UPDATE) → certbot repo ini tidak
   menyentuh nPerf; tidak ada konflik renewal.
5. **Watchdog cron bawaan** (`setup-initd-autostart`, `*/2`) → dihapus bila
   systemd tersedia, agar tidak ada dua mekanisme autostart.
6. **Alpine tanpa paket apk** → modul dilewati berpesan, instalasi Ookla
   tetap utuh.
7. **Kegagalan deferrable** (repo/jaringan nPerf) tidak menggagalkan instalasi
   utama dan dicoba ulang oleh self-update harian.

## Ronde 4 (v8.2.1) — audit keamanan/ketahanan mandiri

Temuan & perbaikan (ringkas; detail di CHANGELOG v8.2.1):

| # | Temuan | Dampak | Perbaikan |
|---|---|---|---|
| A1 | `speedtest-repo.conf` di-`source` (dievaluasi sebagai shell root) | baris berbahaya dieksekusi; komentar inline merusak nilai | dibaca sebagai `KEY=VALUE` (`load_repo_conf`), nama kunci dibatasi, nama berbahaya dilewati |
| A2 | `au_load_repo_config()` tidak mengenali `NPERF_*` | perubahan `NPERF_ENABLED`/port **tidak pernah** dibaca self-update; self-update dengan service unit berbeda bisa mengembalikan port ke 8080 | loader mengenali seluruh kunci conf; **gerbang otomatis** di `tools/audit_cmd_deps.py` (parity conf) |
| A3 | Verifikasi `checksums.sha256` hanya per-file saat unduh (tidak ada verifikasi menyeluruh setelah instalasi) | file rusak/dimodifikasi tidak terdeteksi | `verify_checksums_manifest()` + item verifikasi akhir + `install.sh --verify-only` + self-update memverifikasi pasca-update |
| A4 | Biner pihak ketiga (CLI Ookla, ZeroTier statis) dipasang tanpa hash | eksekusi root dari sumber yang bisa berubah | pin SHA-256 per arsitektur + penolakan bila hash tidak tersedia (`*_ALLOW_UNVERIFIED`) |
| A5 | Repo APT nPerf memakai `trusted=yes` di Debian 13 | verifikasi tanda tangan apt dimatikan untuk repo itu | diverifikasi ulang (InRelease trixie sah) → `signed-by` untuk semua codename + pin fingerprint kunci; `trusted=yes` hanya jalur darurat |
| A6 | Backup drop-in sshd di `/tmp` | bisa hilang/ditempel pihak lain; operator tak tahu lokasinya | dipindah ke `/var/backups/speedtest-sshd-dropin.conf.bak` |
| A7 | Firewall dipilih berdasarkan keberadaan biner | rule bisa ditulis ke backend yang tidak aktif | backend aktif dideteksi (ufw `Status: active` / firewalld `--state`) |
| A8 | `install.log` tumbuh tanpa batas; `--help` butuh root | disk penuh; UX buruk | rotasi log di awal installer; `--help` bebas root |
| A9 | `speedtestctl nperf-restart` bisa gagal senyap tanpa systemd & init.d | operator bingung | pesan jelas + saran perintah |
| A10 | nPerf ramdisk: `cp` sebelum `mkdir`, path tetap | berkas HTTP tidak tersalin tanpa jejak | `mkdir -p` sebelum salin, `NPERF_HTTP_FILES_DIR` konfigurable |
| A11 | Substitusi placeholder `sed -i "s|__X__|$VAR|"` di `bagian8`/`bagian4`: nilai berisi `&` atau `|` merusak file hasil generate (`&` = backreference, `|` = delimiter) | file konfigurasi/script hasil generate korup senyap bila path sistem memuat karakter tsb | helper `sed_escape_repl()` (escape `\`, `&`, `|`) dipakai di **semua** 10 titik substitusi + uji E2E (unit + simulasi `sed` nyata) |
| A12 | Kegagalan repo nPerf (termasuk **penolakan kunci asing**) bersifat DEFERRABLE → instalasi lanjut, tetapi ringkasan akhir tidak menyebut bahwa repo tidak terpasang | operator mengira pembaruan paket nPerf mengalir otomatis padahal tidak | penanda internal `repo_skipped` + peringatan penutup eksplisit di mode install **dan** `--config-only` (self-update) |
| A13 | Fungsi `die()` mati di blok fallback `bagian7` (SC2329) | kode mati membingungkan & menutupi temuan ShellCheck nyata | dihapus; ShellCheck 0 temuan di **seluruh** 22 skrip (`bash -s` + pengecualian terdokumentasi) |

**Kredensial (operasional, di luar kode):** token Cloudflare nyata masih
dapat diunduh publik dari commit lama `autocertbot.sh` di GitHub → harus
**dirotasi**; PAT GitHub yang pernah dipakai push harus **dicabut**.

## Status Verifikasi (diuji via harness mock end-to-end)
- [x] Debian/Ubuntu: alur lengkap bagian0..8 OK, idempoten OK.
- [x] RHEL/Rocky: OS family terdeteksi `rhel`, systemd unit dibuat OK.
- [x] Alpine: OS family terdeteksi `alpine`; repo community diaktifkan; OpenRC
      init script valid POSIX sh.
- [x] Re-run (idempotency): biner & certbot dilewati; crontab tidak duplikat
      (tepat 2 baris report + 1 baris restart).
- [x] Sertifikat valid existing → issuance dilewati.
- [x] bagian7 `-postboot` jalan TANPA common (fallback) — fix bug boot.
- [x] bagian7 `--postboot` (jalur `@reboot` bagian10) jalan tanpa `data.ini`.
- [x] Wrapper cron laporan sukses pada PATH minimal + flag lisensi (kontrol
      negatif tanpa flag → gagal, kontrol positif dengan flag → sukses).
- [x] NAT `--postboot`: 3 rule terpasang, scoped ke subnet ZeroTier, idempotent,
      IP forwarding aktif, dan GAGAL bila iptables tidak bekerja (tanpa log palsu).
- [x] Kebijakan interface ZeroTier ditegakkan (allowManaged/allowDefault/allowGlobal).
- [x] Masa berlaku sertifikat: valid=90 hari → lolos; sisa 5 hari / kedaluwarsa /
      tidak ada → diperbarui (regresi B17).
- [x] Uninstall tidak menggantung walau iptables "berbohong" (`timeout` 90 s, rc=0).
- [x] nPerf (v8.2.0): repo resmi ditambahkan (signed-by bookworm / trusted=yes
      trixie), config ditegakkan 8081/8443 + redirect 80/443, service start &
      restart (jalur systemd **dan** init.d), `--config-only`, `--status`,
      jalur offline tetap rc=0, uninstall menghapus semua rule nPerfServer tanpa
      menggantung walau `nft` "berbohong", dan `--purge` menghapus paket+UUID.
- [x] Semua file: `bash -n` OK, `shellcheck -S warning` 0 error/0 warning
      (kecuali pengecualian yang didokumentasikan).

## Kompatibilitas Shell
- Semua script memakai shebang `#!/usr/bin/env bash` & dipanggil via `bash`.
- `install.sh` dipanggil `bash ./install.sh` di Alpine (default shell ash).
- Fitur bash (array `BASH_SOURCE`, substring `${s: -4}`) aman karena dieksekusi
  oleh bash, bukan ash/dash.
