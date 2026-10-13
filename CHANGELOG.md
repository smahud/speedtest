# Ringkasan Perubahan (Revisi Path-Aware)

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
