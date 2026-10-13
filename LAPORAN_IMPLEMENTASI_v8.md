# LAPORAN IMPLEMENTASI v8.1.0 — Repo Speedtest (OoklaServer Auto Installer)

**Branch review:** `feat/zerotier-hardcode-ssh-autoupdate`
**VERSION:** 8.1.0 (snapshot: `versions/8.1.0/`)
**Tanggal:** 14 Oktober 2026
**Status uji:** E2E **77 pemeriksaan / 0 gagal**, ShellCheck **0 temuan**, audit dependensi **0 temuan**

---

## 0. Ringkasan singkat (untuk yang sibuk)

| Permintaan Anda | Status | Bukti ringkas |
|---|---|---|
| 1. ZeroTier di-hardcode di repo, dihapus dari `data.ini`, **WAJIB** semua instalasi | ✅ | `speedtest-repo.conf` + `bagian7_network.sh` (gagal bila node belum di-authorize) |
| 2. `RegisteredSpeedtestURL` → localhost lewat file hosts | ✅ | `bagian10_hosts_ssh.sh` → blok `# speedtest-managed` di `/etc/hosts` |
| 3. Cek & update otomatis (tanpa kerja manual user) | ✅ | `speedtest-selfupdate.sh` + cron harian + verifikasi SHA-256 + re-exec |
| 4. Kunci publik GitHub + sshd siap login kunci | ✅ | `bagian9_ssh_access.sh` (drop-in sshd diuji `sshd -t` + rollback) |
| 5. Re-check SELURUH repo, rapikan alur, hilangkan konflik & hal yang merusak performa | ✅ | 12 bug nyata ditemukan & diperbaiki (Bab 5), alur install dirapikan (Bab 4) |
| 6. Jaminan: isi `data.ini` → jalankan **satu perintah** `…/install.sh \| bash`, semua dependensi otomatis | ✅ | Bab 3 + uji pipa di E2E (seksi 7) |

---

## 1. Apa yang berubah (peta cepat)

**File baru (±):** `speedtest-repo.conf`, `auto_update_lib.sh`, `bagian9_ssh_access.sh`,
`bagian10_hosts_ssh.sh`, `bagian11_self_update.sh`, `speedtest-selfupdate.sh`,
`MANIFEST`, `checksums.sha256`, `VERSION`, `.gitignore`, `legacy/README.md`,
`tools/regen-checksums.sh`, `tools/publish-version.sh`, `tools/audit_cmd_deps.py`,
`tests/e2e_install_test.sh`, `versions/8.1.0/` (22 file snapshot).

**File diubah (±):** `install.sh`, `bagian1`, `bagian4`, `bagian5`, `bagian6`,
`bagian7`, `bagian8`, `uninstall.sh`, `common_functions1.sh`, `data.ini.example`,
`README.md`, `CHANGELOG.md`. **Dipindah:** `serverinstall.sh` → `legacy/serverinstall.sh`.

**Prinsipnya:** semua kebijakan **operator** (ZeroTier, hosts, SSH, jadwal update,
reporting) dipusatkan di `speedtest-repo.conf`. Semua kebijakan **per-server**
(domain + kredensial sertifikat) tetap di `data.ini`. Efeknya: mengubah satu
variabel di repo langsung berlaku ke semua server lewat self-update.

---

## 2. Empat permintaan Anda — detail implementasi

### 2.1 ZeroTier hardcode & WAJIB
- Semua field ZeroTier **dihapus** dari `data.ini`/`data.ini.example`
  (statusnya dijelaskan di komentar kepala file).
- Nilai dipusatkan di `speedtest-repo.conf`:
  `ZT_NETWORK_ID=72ff30f9733a82d9`, `ZT_MOON_ID=72ff30f973`,
  `ZT_MOON_CONFIG_URL`, `ZT_ENABLE_EXIT_NODE=Ya`,
  `ZT_REQUIRE_AUTHORIZATION=Ya`, `ZT_AUTH_TIMEOUT=180`.
- `bagian7_network.sh` dijalankan **terakhir** di `install.sh` dan **gagal**
  (exit ≠ 0, pesan jelas + cara authorize) bila node belum di-authorize.
  Semua komponen lain sudah terpasang lebih dulu, jadi retry otomatis
  (self-update/boot-sync) tetap menyelesaikan instalasi setelah Anda authorize.
- Perbaikan bug lama (F14): MOON_ID kini benar-benar disuntikkan lewat heredoc
  **tanpa tanda kutip**, dan `zerotier-cli` dipanggil dengan **path absolut**.
- Binary `zerotier-one` (Alpine/x86_64) diverifikasi **SHA-256**
  (`zerotier/zerotier-one-x86_64-alpine.sha256`) sebelum dipasang; bila
  sidecar tidak ada → peringatan, mismatch → batal (F8 sebagian).
- NAT/exit-node memakai `iptables -C` (idempoten, tidak menumpuk rule) dan
  dipulihkan otomatis saat boot lewat satu titik masuk (lihat Bab 4).

### 2.2 `RegisteredSpeedtestURL` → localhost (file hosts)
- `bagian10_hosts_ssh.sh` menulis blok bertanda `# speedtest-managed` ke
  `HOSTS_FILE` (default `/etc/hosts`; konstanta bisa diubah di conf).
- **Deviasi yang saya sampaikan di awal tetap berlaku:** Anda menyebut
  `/root/hosts`; implementasi memakai `/etc/hosts` karena itulah yang dibaca
  resolver. Bila memang ingin file lain, cukup ubah `HOSTS_FILE` di
  `speedtest-repo.conf` — semua skrip mengikuti.
- Idempoten: entri lama dikenali lewat penanda, tidak pernah duplikat.
- Aman untuk container: bila `/etc/hosts` adalah *mount point* (Docker),
  `mv` gagal → otomatis fallback tulis *in-place* (ada uji khusus di E2E).
- `uninstall.sh` mengembalikan hosts (backup + hanya menghapus baris ber-penanda).

### 2.3 Cek & update otomatis (zero manual)
- `speedtest-selfupdate.sh` + `auto_update_lib.sh`:
  1. bandingkan `VERSION` repo vs lokal (lewati bila sama, kecuali `--force`),
  2. unduh ke **staging**, verifikasi **SHA-256 per file** (dari `MANIFEST`),
  3. gerbang **`bash -n`** — file yang gagal sintaks TIDAK dipasang,
  4. pasang hanya file yang **isinya berbeda** (`cmp`) → tidak memicu restart
     / penumpukan backup yang tidak perlu,
  5. backup otomatis (rotasi 5 terakhir), lock anti-tumpang-tindih,
  6. **re-exec installer** bila `install.sh` ikut berubah (anti version-skew),
  7. rotasi `update.log` (> 5 MB).
- Dijadwalkan lewat **satu** cron harian (`# speedtest-autoupdate (managed)`,
  jam 03:17 + menit acak) dan **satu** entri boot-sync `@reboot` yang
  menegakkan hosts + akses SSH + NAT ZeroTier.
- Snapshot rilis imutabel `versions/<VERSION>/` supaya update tidak ikut
  terpengaruh commit berikutnya di branch main, dan bisa di-rollback.

### 2.4 Kunci SSH + sshd siap pakai
- `bagian9_ssh_access.sh` mengunduh `https://github.com/smahud.keys`,
  memfilter baris kunci yang valid, lalu menulisnya ke
  `authorized_keys` di dalam blok penanda
  `# BEGIN/END speedtest-managed-keys` (tidak menyentuh kunci milik Anda).
- Drop-in `sshd_config.d/99-speedtest-managed.conf`: `PubkeyAuthentication yes`,
  `AuthorizedKeysFile .ssh/authorized_keys`,
  `PermitRootLogin prohibit-password` (default), password auth **tidak**
  dimatikan secara default (bisa dinyalakan via conf).
- Keamanan: konfigurasi diuji dengan `sshd -t` **sebelum** dipakai; bila gagal →
  otomatis **rollback** (tidak mungkin mengunci akses SSH Anda).
- Bila TTY tidak tersedia (mode pipe di cron/otomasi tanpa terminal), bagian9
  ditunda dengan pesan jelas dan tetap ditegakkan oleh boot-sync `@reboot`
  (atau langsung oleh bagian10 pada langkah berikutnya).

---

## 3. Jaminan “satu perintah”: isi `data.ini` → `…/install.sh | bash`

Alur yang diuji:

```bash
# di server baru, di direktori kerja (mis. /root)
cp data.ini.example data.ini && nano data.ini        # isi domain + kredensial
curl -fsSL https://raw.githubusercontent.com/smahud/speedtest/main/install.sh | bash
```

Yang otomatis terjadi (semuanya tanpa langkah manual):
1. **Mode pipe terdeteksi** (`BASH_SOURCE` kosong) → installer memakai CWD
   sebagai `SPEEDTEST_SCRIPT_DIR`, mengunduh seluruh file pendukung
   (22 file dari `MANIFEST`) ke `BASE_DIR`, verifikasi checksum, lalu
   menyalin `install.sh` sendiri ke `BASE_DIR` (agar re-exec & uninstall rapi).
2. **Dependensi dasar** dipasang sesuai distro: `bash curl wget tar jq
   ca-certificates` + paket cron (`cron`/`cronie`) + best-effort
   `iptables`, `procps`, `openssl`.
3. **Daemon cron di-*enable* & di-*start*** (`cron`/`crond`/`cronie`) —
   tanpa ini jadwal tidak akan pernah jalan di image minimal/container.
4. **OoklaServer** (bagian2, bagian5) + **Ookla Speedtest CLI resmi** (bagian1:
   binary statis 1.2.0 x86_64/aarch64/armhf/i386, diverifikasi `speedtest --version`).
5. **Sertifikat Let's Encrypt** (bagian3–4) sesuai mode di `data.ini`.
6. **Cron maintenance** (bagian6) + **service** (bagian8) + **hosts/SSH**
   (bagian9–10) + **self-update** (bagian11) + **ZeroTier wajib** (bagian7).
7. **Verifikasi akhir otomatis** (baru): daftar `[OK]/[WARN]` untuk
   OoklaServer, mapping hosts, kunci SSH, tiga cron wajib, daemon cron,
   ZeroTier, dan kesiapan self-update. Bila ada `[WARN]`, perintah perbaikannya
   dicetak langsung.

Bentuk lain yang juga didukung: `wget -O install.sh <url> && bash install.sh`
(tanpa pipe, CWD tetap jadi sumber `data.ini`), dan
`bash install.sh /path/ke/data.ini` (path eksplisit). Ingin repo lain?
Set `REPO_RAW_BASE` → installer **menghormati** lingkungan tersebut
(diperbaiki: sebelumnya selalu kembali ke default repo).

---

## 4. Alur instalasi final (urutan anti-konflik)

```
install.sh
 ├─ 0  bootstrap: unduh/verifikasi semua file ke BASE_DIR (mode pipe/unduhan)
 │     └─ self-update pra-instalasi (pakai repo/snapshot versi)
 │     └─ RE-EXEC bila install.sh berubah  (guard SPEEDTEST_REEXEC=1)
 ├─ 1  dependency + layanan cron (enable --now)
 ├─ 2  OoklaServer (binary + daemon)
 ├─ 3  certbot (+ plugin Cloudflare bila dipakai)
 ├─ 4  sertifikat  → + jadwal renewal (CF) / pemantau masa berlaku (DNS manual)
 ├─ 5  konfigurasi OoklaServer ↔ sertifikat + restart
 ├─ 6  cron reporting (jam-an; cepat 5 menit opsional)
 ├─ 8  service systemd/OpenRC/fallback + cron daily restart + firewall
 ├─ 9  akses SSH (kunci GitHub + drop-in sshd, dengan rollback)
 ├─ 10 /etc/hosts + penegakan akses SSH (blok penanda)
 ├─ 11 cron self-update harian + SATU entri @reboot (boot-sync)
 ├─ 7  ZeroTier WAJIB (install/verify/authorize/NAT) — terakhir, gate keras
 └─ VERIFIKASI AKHIR + ringkasan
```

Alasan urutan ini (dari hasil re-check):
- **ZeroTier terakhir**: karena wajib & bisa menggantung di menunggu authorize,
  semua yang lain sudah terpasang lebih dulu → tidak ada instalasi setengah jadi.
- **cron sebelum self-update**: bagian11 hanya butuh file yang sudah ada;
  self-update juga tersedia setelah bagian11 (urutan tidak memicu update ganda).
- **satu titik masuk saat boot** (`bagian10 -postboot`) menegakkan hosts + SSH,
  lalu memanggil `bagian7 -postboot` untuk NAT. Sebelumnya ada dua cron
  terpisah (`@reboot` hosts dan `zt-nat-restore`) → berpotensi balapan; kini
  **satu** entri, satu urutan.
- **semua penulisan crontab lewat satu helper** `cron_apply()`/`cron_clear()`
  (awk satu pass, selalu status 0, anti-duplikasi). Ini menghapus 5 implementasi
  berbeda yang sebelumnya rapuh.
- **tidak ada restart berlebihan**: bagian5 merestart setelah menulis
  konfigurasi; restart final hanya sekali di akhir; self-update hanya menulis
  file yang benar-benar berubah.

---

## 5. Bug & kelemahan yang ditemukan saat re-check seluruh repo

| # | Gejala | Akar masalah | Perbaikan | Bukti |
|---|---|---|---|---|
| B1 | Cron **ganda** setiap install/self-update ulang (laporan jadi 2×/jam) | `bagian6` hanya menyaring pola lama `speedtest -o ` yang sudah tidak dipakai (wrapper `cron-speedtest*.sh`) | dedup berbasis tag **+ path wrapper** lewat `cron_apply` | diff crontab run1 vs run2 (`0a1,2`) → setelah fix stabil 3× jalan |
| B2 | Instalasi mati di bagian8 (`rc=1` / `rc=141`) → cron daily restart & verifikasi tidak pernah jalan | `set -e` + `grep -v` yang menghasilkan kosong (status 1) dan pipeline ke `crontab -` yang menutup pipe | semua penulisan crontab → awk satu pass + file temporer (`cron_apply`) | installer lanjut sampai "VERIFIKASI AKHIR" di E2E |
| B3 | `uninstall.sh` berhenti (rc=2), kunci SSH tidak dibersihkan | parser mini config tidak sadar komentar inline → `UF_SSH_USERS='root"' # …` → `getent passwd 'root"'` gagal | `uf_parse_value()` (buang komentar inline + trim + lepas kutip) | trace `bash -x` sebelum/sesudah; E2E uninstall PASS |
| B4 | Entri cron bagian lain **terhapus** saat boot-sync ditulis | POSIX ERE memilih match **terpanjang**: pola `@reboot` ter-strip jadi `2>&1` → pola cocok ke banyak baris | strip jadwal eksplisit per kasus di awk + unit test regresi | repro sebelum/sesudah; E2E seksi 11 (3 pemeriksaan) |
| B5 | Paket cron terpasang tapi jadwal tak pernah jalan | daemon cron tidak pernah `enable/start` | `ensure_cron_service()` + laporan di verifikasi akhir | E2E: "Layanan cron aktif" + "Daemon cron aktif" |
| B6 | Kunci SSH bisa gagal dipasang **tanpa pesan** di Alpine minimal | `getent` tidak selalu tersedia (musl-utils) | `user_home()` portabel (getent → awk `/etc/passwd` → `/root`) dipakai bagian9/10/uninstall | E2E: `user_home` dipakai, `getent` tidak lagi dipanggil langsung |
| B7 | Potensi error karena `local var="$(cmd)"` menutupi status keluar | SC2155 | deklarasi & assignment dipisah (4 titik) + variabel dari `data.ini` dideklarasikan dengan default aman | ShellCheck 0 temuan |
| B8 | Masa berlaku sertifikat tidak pernah dicek (F6) | tidak ada pemantau | CF: `certbot renew` terjadwal + `--deploy-hook` restart (hanya bila berubah). Manual DNS: pemantau harian menulis peringatan bila < 21 hari | cron `# speedtest-cert-renew`/`# speedtest-cert-check` (E2E) |
| B9 | Kegagalan tersembunyi saat instalasi selesai “hijau” padahal cron/hosts gagal | tidak ada verifikasi akhir | laporan `[OK]/[WARN]` otomatis 8 poin di akhir instalasi | E2E: 4 pemeriksaan isi verifikasi |
| B10 | `REPO_RAW_BASE` (repo alternatif) diabaikan saat bootstrap | installer selalu menimpa dengan default | flag `REPO_RAW_BASE_FROM_ENV` → pra-instalasi self-update menghormatinya | diuji di E2E (mode pipe memakai `file://`) |
| B11 | Performa: laporan tiap 5 menit membebani server kecil & tidak bisa dimatikan | tidak ada saklar | `REPORT_FAST_ENABLED` / `REPORT_HOURLY_ENABLED` / `REPORT_FAST_SCHEDULE` di conf; jadwal yang dimatikan otomatis **dihapus** dari crontab | E2E seksi 12 (4 pemeriksaan) |
| B12 | Harness uji palsu (false pass) | mock crontab tidak membaca stdin (`crontab -`), mock OoklaServer tidak *fork*, mock ZeroTier terhapus oleh uji uninstall, bind `/etc` per-direktori | shim & mock diperbaiki; bind seluruh `/etc` di namespace | E2E 77/77 |

Bug dari analisis awal yang juga sudah tertutup di v8: F5 (cron “nyangkut”),
F9 (uninstall terlalu luas — kini daftar file terkelola), F10 (`serverinstall.sh`
dipindah ke `legacy/`), F14 (heredoc MOON_ID), F22 (unduhan tidak atomik),
serta pola berbahaya “`|` lalu redirect di baris sendiri” (SC2189) yang bisa
**menghapus crontab** — kini tidak mungkin terjadi karena semua penulisan
crontab memakai helper dan file temporer.

---

## 6. Hasil verifikasi (angka aktual)

| Uji | Hasil | Cara menjalankan |
|---|---|---|
| E2E instalasi mock (namespace, tanpa menyentuh host) | **77 PASS / 0 FAIL** | `bash tests/e2e_install_test.sh` |
| ShellCheck (severity ≥ warning, semua `*.sh`) | **0 temuan** | `shellcheck -S warning *.sh tools/*.sh tests/*.sh` |
| Audit dependensi (perintah wajib punya jalur pemasangan/guard) | **0 temuan** | `python3 tools/audit_cmd_deps.py` |
| Sintaks semua skrip | OK | `bash -n` tiap file |
| Checksum & manifest rilis | 22 file, `checksums.sha256` + `MANIFEST` | `bash tools/regen-checksums.sh` |
| Snapshot rilis | `versions/8.1.0/` (22 file) | `bash tools/publish-version.sh` |

Cakupan E2E (12 seksi): instalasi penuh di lingkungan bersih; idempotensi
(jalan kedua tanpa duplikasi hosts/kunci/cron); self-update otomatis
(versi naik, checksum, backup, log); ZeroTier wajib (gagal bila belum
authorize, sukses bila authorize + moon); uninstall non-destruktif;
instalasi **satu baris `curl | bash`**; re-exec anti version-skew; kasus
container `/etc/hosts` = mount point; ketahanan ketika crontab error;
unit test pola entri cron (regresi `@reboot`); saklar reporting.

---

## 7. Yang perlu Anda putuskan / rekomendasi lanjutan

1. **Rotasi kredensial Cloudflare** (temuan F23): file `autocertbot.sh` lama
   masih bisa diunduh dari commit historis `546dcc38`. Kredensialnya sebaiknya
   dianggap bocor → rotasi di dashboard Cloudflare (di luar scope kode).
2. **`ooklaserver.sh` versi vendored** masih rilis 2024-01-30, sedangkan
   upstream menyediakan 2.11.5.2 (F7/F12). Menggantinya menyentuh alur
   sertifikat, jadi saya belum melakukannya — silakan putuskan.
3. **`/root/hosts` vs `/etc/hosts`** (F3): masih `/etc/hosts` (bisa diubah
   lewat `HOSTS_FILE`).
4. **Sertifikat non-Cloudflare** tetap interaktif sesuai permintaan awal Anda;
   kini ada pemantau masa berlaku supaya tidak “mati mendadak”.
5. **LICENSE** repo belum ada (F8 sisa).
6. **Uji di 1 server staging** sebelum merge ke `main` — karena E2E memakai
   mock, satu kali uji nyata (VPS kecil) tetap disarankan.

---

## 8. Cara review & uji sendiri

```bash
cd repo-speedtest
git log --oneline main..feat/zerotier-hardcode-ssh-autoupdate
git diff main --stat

# 1) uji fungsional lengkap (mock, tidak menyentuh host)
bash tests/e2e_install_test.sh

# 2) statis
for f in *.sh tools/*.sh tests/*.sh; do bash -n "$f"; done
shellcheck -S warning *.sh tools/*.sh tests/*.sh
python3 tools/audit_cmd_deps.py

# 3) rilis (sudah dijalankan)
bash tools/regen-checksums.sh
bash tools/publish-version.sh
```

Lampiran: peta variabel `speedtest-repo.conf`

| Variabel | Default | Fungsi |
|---|---|---|
| `REPO_RAW_BASE_DEFAULT` | `.../smahud/speedtest/main` | sumber unduhan bootstrap & self-update |
| `ZT_NETWORK_ID` / `ZT_MOON_ID` / `ZT_MOON_CONFIG_URL` | 72ff30f9733a82d9 / 72ff30f973 / moon.zerotier.my.id | jaringan kontrol wajib |
| `ZT_ENABLE_EXIT_NODE` | Ya | aktifkan NAT/forwarding exit node |
| `ZT_REQUIRE_AUTHORIZATION` / `ZT_AUTH_TIMEOUT` | Ya / 180 | gate wajib authorize (detik tunggu) |
| `HOSTS_FILE` / `HOSTS_TARGET_IP` / `HOSTS_MARKER` | /etc/hosts / 127.0.0.1 / speedtest-managed | mapping domain → localhost |
| `SSH_KEYS_URL` / `SSH_TARGET_USERS` / `SSH_MANAGE_SSHD` | github.com/smahud.keys / root / Ya | pasang kunci + konfigurasi sshd |
| `SSH_ROOT_LOGIN` / `SSH_DISABLE_PASSWORD_AUTH` | prohibit-password / Tidak | kebijakan sshd |
| `AUTO_UPDATE_ENABLED` / `..._SCHEDULE_HOUR/_MIN` | Ya / 3 / 17 | self-update harian |
| `AUTO_UPDATE_REEXEC_INSTALL` / `..._KEEP_BACKUPS` / `..._MAX_LOG_MB` | Ya / 5 / 5 | re-exec, rotasi backup, rotasi log |
| `REPORT_HOURLY_ENABLED` / `REPORT_FAST_ENABLED` / `REPORT_FAST_SCHEDULE` | Ya / Ya / `*/5 * * * *` | saklar beban reporting |

> Catatan operasional: mengubah nilai di `speedtest-repo.conf` **di repo** akan
> berlaku ke seluruh server pada self-update berikutnya (tanpa masuk ke server).
