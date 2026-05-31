# Ringkasan Perubahan (Revisi Path-Aware)

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
