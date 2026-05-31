# Speedtest OoklaServer Installer (Path-Aware Edition)

Installer otomatis & **non-interaktif** untuk Ookla Speedtest Server, lengkap
dengan sertifikat Let's Encrypt (Cloudflare / non-Cloudflare, wildcard /
non-wildcard), auto-start service (systemd / OpenRC / fallback), cron
maintenance, dan modul opsional ZeroTier Exit Node.

> **Versi ini telah dirombak total** agar tidak lagi bergantung pada `/root/`.
> Installer bisa dijalankan dari **direktori mana pun**, dan **semua file
> relatif mengikuti lokasi `data.ini`** (BASE_DIR).

---

## 1. Cara Kerja Path (PENTING)

- **`CONFIG_PATH`** ditentukan dengan prioritas:
  1. argumen pertama (`./install.sh /path/ke/data.ini`),
  2. direktori tempat `install.sh` berada,
  3. current working directory,
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
| `RegisteredSpeedtestURL` | ✓     | URL server speedtest terdaftar |
| `EmailCloudFlare`        | opsional | Email akun CF (untuk Global API Key) |
| `AktifkanZeroTier`       | opsional | `Ya` (default) / `Tidak` |

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

## 3. Cara Pakai per OS

> **PENTING:** Jalankan command **di direktori tempat `data.ini` berada**.
> `install.sh` bersifat **self-bootstrap**: cukup unduh SATU file `install.sh`,
> ia akan otomatis mengunduh file pendukung (common + bagian1..8 + ooklaserver.sh)
> ke `BASE_DIR` (folder `data.ini`), lalu menjalankan semuanya dan **restart
> otomatis** di akhir. Anda **tidak perlu** lagi `/root/ooklaserver.sh restart`.

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

### Penyesuaian dengan command lama Anda
Command lama Anda diakhiri `&& /root/ooklaserver.sh restart`. **Itu sudah TIDAK
diperlukan** karena installer me-restart otomatis. Jika tetap ingin restart
manual, gunakan path yang benar (BASE_DIR), mis:
```bash
$(pwd)/ooklaserver.sh restart        # bukan /root/ooklaserver.sh
# atau:
./speedtestctl.sh restart
```

### Catatan sumber unduhan
`install.sh` mengunduh file pendukung dari
`https://raw.githubusercontent.com/smahud/speedtest/main`. Anda bisa mengganti
sumbernya via environment variable:
```bash
REPO_RAW_BASE="https://raw.githubusercontent.com/USER/REPO/BRANCH" ./install.sh
```
Atau bila Anda mengekstrak archive `speedtest-final.tar.gz` (semua file ada),
tidak ada unduhan tambahan yang dilakukan.

---

## 4. Management Service

Setelah instalasi, dibuat tool `speedtestctl.sh` di `$BASE_DIR` yang bisa
dijalankan dari **mana saja** (membaca state instalasi):

```bash
$BASE_DIR/speedtestctl.sh status
$BASE_DIR/speedtestctl.sh start
$BASE_DIR/speedtestctl.sh stop
$BASE_DIR/speedtestctl.sh restart
$BASE_DIR/speedtestctl.sh uninstall
```

Service auto-start dibuat sesuai init system:
- **systemd** → `ooklaserver.service`
- **OpenRC** (Alpine) → `/etc/init.d/ooklaserver`
- **fallback** → cron `@reboot`

Restart server memakai script instalasi yang benar (`$BASE_DIR/ooklaserver.sh`),
**bukan** `/root/ooklaserver.sh`.

---

## 5. Idempotency

Installer aman dijalankan ulang:
- Speedtest CLI & certbot dilewati bila sudah ada.
- Sertifikat dilewati bila masih berlaku (`--keep-until-expiring`).
- OoklaServer.properties di-rewrite secara bersih (tanpa duplikasi baris).
- Cron job di-deduplikasi.
- `data.ini` **tidak pernah** ditimpa.

---

## 6. Log

Log lengkap ada di `$BASE_DIR/install.log`.

---

## 7. Struktur File

```
install.sh                          # orchestrator (resolve path, validasi, jalankan bagian)
common_functions1.sh                # pustaka: path, parsing/validasi ini, OS/pkg/init, logging, masking
bagian0.sh                          # banner
bagian1_install_dependency.sh       # speedtest CLI + kredensial Cloudflare
bagian2_install_ooklaserver.sh      # install OoklaServer ke BASE_DIR
bagian3_install_certbot.sh          # install certbot (+plugin CF) lintas distro
bagian4_install_server_certificate.sh # terbitkan sertifikat (4 mode)
bagian5_update_ooklaserver.sh       # set path cert + restart
bagian6_automaintenance.sh          # cron reporting speedtest
bagian7_network.sh                  # ZeroTier exit node (opsional)
bagian8_cek_konfigurasi.sh          # service auto-start + verifikasi + speedtestctl.sh
ooklaserver.sh                      # script resmi Ookla (+ command status)
data.ini.example                    # contoh konfigurasi
```
