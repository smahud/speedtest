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

## Status Verifikasi (diuji via harness mock end-to-end)
- [x] Debian/Ubuntu: alur lengkap bagian0..8 OK, idempoten OK.
- [x] RHEL/Rocky: OS family terdeteksi `rhel`, systemd unit dibuat OK.
- [x] Alpine: OS family terdeteksi `alpine`; repo community diaktifkan; OpenRC
      init script valid POSIX sh.
- [x] Re-run (idempotency): biner & certbot dilewati; crontab tidak duplikat
      (tepat 2 baris report + 1 baris restart).
- [x] Sertifikat valid existing → issuance dilewati.
- [x] bagian7 `-postboot` jalan TANPA common (fallback) — fix bug boot.
- [x] Semua file: `bash -n` OK, `shellcheck -S warning` 0 error/0 warning.

## Kompatibilitas Shell
- Semua script memakai shebang `#!/usr/bin/env bash` & dipanggil via `bash`.
- `install.sh` dipanggil `bash ./install.sh` di Alpine (default shell ash).
- Fitur bash (array `BASH_SOURCE`, substring `${s: -4}`) aman karena dieksekusi
  oleh bash, bukan ash/dash.
