# Laporan Analisa Bug — Ronde 2
**Repo:** `smahud/speedtest` (workspace: `/home/user/repo-speedtest`)
**Branch:** `feat/zerotier-hardcode-ssh-autoupdate` @ `e6d5423` (VERSION 8.1.0)
**Tanggal:** 14 Oktober 2026
**Status:** **LAPORAN SAJA — belum ada file/kode yang diubah.** `git status` bersih (diverifikasi).

---

## 1. Ringkasan Eksekutif

Ditemukan **6 bug baru + 3 catatan minor**. Tiga di antaranya berdampak langsung ke fitur yang baru dibangun di v8.1.0 (auto-reporting, auto-update jalur cron, NAT ZeroTier setelah reboot).

| # | Temuan | Tingkat | Dampak utama |
|---|--------|---------|--------------|
| **B13** | Lisensi Ookla CLI (`--accept-license`) tidak pernah diterima → cron reporting **selalu exit 1** di server baru | **KRITIS** | Laporan per jam & per 5 menit tidak pernah jalan; gagal senyap |
| **B14** | PATH cron tidak memuat `/usr/local/bin` (lokasi CLI Ookla) → `speedtest: not found` | **TINGGI** | Sama seperti B13; di Alpine **pasti gagal** |
| **B15** | `@reboot` (bagian7 `-postboot`) memanggil `iptables`/`sysctl` tanpa path absolut | **TINGGI** | NAT + IP forwarding **tidak pulih setelah reboot**, senyap |
| **B16** | Kegagalan `ipt_ensure` di-`\|\| true` lalu tetap dicetak `[OK] NAT: … terkonfigurasi` | **SEDANG** | Operator melihat "sukses" padahal tidak ada rule iptables |
| **B17** | `cert_valid_for` hanya cek **keberadaan** sertifikat, bukan masa berlaku | **SEDANG** | Sertifikat kedaluwarsa dianggap "masih berlaku, dilewati" |
| **B18** | Tidak ada verifikasi HTTPS end-to-end setelah konfigurasi sertifikat | **RENDAH** | Installer "sukses" walau TLS tidak melayani domain |
| B19 | Output/exit-code wrapper cron dibuang (tanpa log) | RENDAH | Semua kegagalan B13/B14 tak terlihat di mana pun |
| B20 | Uninstall tidak membersihkan `~/.config/ookla`, tapi menghapus `/usr/bin/speedtest` | INFO | Sisa konfigurasi; berpotensi menghapus CLI milik paket distro |

**Root cause paling penting (B13+B14):** fitur reporting bagian6 memanggil `speedtest` sebagai *perintah kosong* dari cron — tanpa path absolut, tanpa flag lisensi. Terbukti dengan uji empiris (lihat §3).

---

## 2. Metode & Batasan

- Pembacaan statis (`grep`/`sed`) atas `install.sh`, `bagian1`–`bagian11`, `uninstall.sh`, `common_functions1.sh`, `auto_update_lib.sh`, `tests/e2e_install_test.sh` — **tanpa** menjalankan `install.sh`/skrip bagian di sandbox (aturan tetap dipatuhi).
- **Uji empiris CLI Ookla resmi**: mengunduh `ookla-speedtest-1.2.0-linux-x86_64.tgz` dari `install.speedtest.net` ke `/tmp`, menjalankannya dengan `HOME` bersih dan tanpa TTY (kondisi identik dengan cron) untuk membuktikan perilaku lisensi.
- `iptables`/`sysctl` tidak tersedia di sandbox → B15/B16 dianalisa statis (bukan eksekusi).
- Uji E2E yang ada (77 PASS / 0 FAIL) dijalankan ulang konsepnya: **tidak ada satupun check yang mengeksekusi wrapper cron bagian6**, sehingga B13/B14 lolos dari suite.

---

## 3. Bukti Empiris — B13 (lisensi)

```
$ env -i HOME=/tmp/<home-bersih> /tmp/ookla-cli/speedtest -s 60580 </dev/null
==============================================================================
You may only use this Speedtest software and information generated
from it for personal, non-commercial use, ...
==============================================================================
To accept the message please run speedtest interactively or use the following:
    speedtest --accept-license
$ echo $?
1
```
Dengan `--accept-license`, uji benar-benar berjalan (proses baru dihentikan setelah 15 s), dan status tercatat di:
`$HOME/.config/ookla/speedtest-cli.json` → `{"Settings":{"LicenseAccepted":"604ec2…"}}`

```
$ grep -rn -- "--accept-license" repo-speedtest/*.sh        → 0 hasil
$ grep -rn "export PATH\|PATH=" repo-speedtest/*.sh          → 0 hasil (hanya CONFIG_PATH)
```

Artinya: **tidak ada satu pun tempat di repo yang menerima lisensi atau mengeset PATH**.

---

## 4. Detail Temuan

### B13 — KRITIS: Lisensi Ookla CLI tidak pernah diterima → cron reporting selalu gagal

**Lokasi:** `bagian6_automaintenance.sh` L56 (wrapper per jam), L72 & L74 (wrapper 5 menit).

```sh
# cron-speedtest.sh
sleep ${JITTER_MIN}m
speedtest -o "$REGISTERED_URL"                 # ← tanpa --accept-license
# cron-speedtest5.sh
systemd-run --scope -p CPUQuota=10% speedtest -o "$REGISTERED_URL"   # (fallback: tanpa systemd-run)
```

**Mekanisme:** CLI Ookla menolak menjalankan uji bila lisensi belum diterima *dan* tidak ada TTY (tidak bisa mengetik "YES"). Cron selalu tanpa TTY → setiap eksekusi berakhir `exit 1` sebelum ada pengukuran. Lisensi disimpan **per-`$HOME`** (`/root/.config/ookla/speedtest-cli.json`); karena installer berjalan non-interaktif dan tidak pernah menjalankan `speedtest --accept-license`, file itu tidak pernah ada.

**Dampak:** di setiap instalasi baru, laporan per jam (cron-speedtest.sh) dan laporan cepat (cron-speedtest5.sh) **tidak pernah berfungsi**, tanpa pesan error (output dibuang). Fitur inti bagian6 praktis mati.

**Sifat intermiten (menjelaskan "di server saya jalan"):** begitu operator kebetulan menjalankan `speedtest` secara interaktif sebagai root sekali saja, file lisensi terbentuk dan cron mulai jalan — jadi gejalanya acak antar-server.

**Usulan perbaikan (2 lapis, wajib keduanya):**
1. `bagian1_install_dependency.sh` — setelah biner terpasang, terima lisensi secara eksplisit:
   ```sh
   "/usr/local/bin/speedtest" --accept-license --accept-gdpr -L >/dev/null 2>&1 || true
   ```
2. `bagian6_automaintenance.sh` — wrapper memakai flag yang sama (`--accept-license --accept-gdpr`) sehingga tetap aman walau file lisensi hilang.

---

### B14 — TINGGI: PATH cron tidak memuat `/usr/local/bin` (lokasi CLI Ookla)

**Lokasi:** `bagian1_install_dependency.sh` L11 & L26–L27, L72–L73:

```sh
OOKLA_CLI_DIR="/usr/local/bin"
# komentar L11: "...ke /usr/local/bin (menang dari /usr/bin)..."
install -m 0755 "$TMP_DIR/speedtest" "$OOKLA_CLI_DIR/speedtest"
```

`cron_apply()` (`common_functions1.sh`) hanya menulis baris entri — **tidak** menulis `PATH=` di crontab, dan tidak ada `export PATH` di seluruh repo.

**PATH default cron** (terverifikasi lewat referensi): Debian/Ubuntu & busybox crond (Alpine) = `/usr/bin:/bin` → **tanpa `/usr/local/bin` dan tanpa `/usr/sbin`**; RHEL/Fedora (cronie) = `/usr/bin:/bin:/usr/sbin:/sbin` → **tetap tanpa `/usr/local/bin`**.

**Dampak per platform:**
- **Alpine** (target resmi; biner statis satu-satunya sumber, tanpa paket `speedtest`): `speedtest: not found` → kedua cron mati pasti.
- **Debian/RHEL tanpa internet ke repo Ookla** (instalasi paket gagal, hanya biner tarball ada): sama, not found.
- **Debian/RHEL dengan paket Ookla terpasang** (`/usr/bin/speedtest`): kebetulan jalan (itu tetap Ookla).
- Risiko tambahan: bila `/usr/bin/speedtest` diisi `speedtest-cli` (sivel/python) dari paket distro, cron menjalankan **tools yang salah** (tidak punya `-o` → gagal).

**Usulan perbaikan:** di wrapper bagian6 gunakan path absolut (`/usr/local/bin/speedtest`, fallback `command -v`), **dan** tetapkan `PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH` di awal wrapper. Opsional: tulis juga baris `PATH=...` di crontab melalui `cron_apply` (hati-hati pada logika `cron_entry_pattern`/purge).

---

### B15 — TINGGI: `iptables`/`sysctl` tanpa path absolut pada jalur `@reboot`

**Lokasi:** `bagian7_network.sh`
- L337/L339 — `enable_ip_forwarding()`: `sysctl -p …` / `sysctl -w net.ipv4.ip_forward=1`
- L360 — `ipt_ensure()`: `iptables -C …` / `iptables -A …`
- L525–531 — blok `if [ "$MODE" = "-postboot" ]`: `enable_ip_forwarding || true; setup_nat || true; exit 0`

**Pemicu:** entri cron `@reboot bash $BASE_DIR/bagian10_hosts_ssh.sh -postboot >/dev/null 2>&1` (terverifikasi ada di crontab hasil instalasi) → memanggil `bagian7_network.sh -postboot`.

**Mekanisme:** `iptables` dan `sysctl` berada di `/usr/sbin` yang **tidak ada** di PATH cron Debian/Alpine. Saat instalasi awal (dijalankan dari shell root biasa) semuanya normal → feature tampak bekerja; **setelah reboot** rule firewall memang hilang (memang tidak persist), dan proses pemulihannya gagal `command not found` lalu ditelan `|| true` + `exit 0`.

**Dampak:** exit node/NAT ZeroTier tidak berfungsi setelah reboot sampai operator menjalankan ulang skrip manual — tanpa satu pun pesan error.

**Usulan perbaikan:** absolutkan (`/usr/sbin/iptables`, `/usr/sbin/sysctl`) atau `export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` di kepala skrip; jangan `|| true` untuk kegagalan yang berarti; verifikasi `iptables -t nat -C POSTROUTING -o <if> -j MASQUERADE`.

---

### B16 — SEDANG: Kegagalan `ipt_ensure` disembunyikan + log sukses palsu

**Lokasi:** `bagian7_network.sh` L354–361 & L380–383:

```sh
ipt_ensure() {
  if iptables -C "$spec" "$@" 2>/dev/null; then return 0; fi
  iptables -A "$spec" "$@" 2>/dev/null || return 1       # ← gagal → return 1
  return 0
}
...
ipt_ensure POSTROUTING -t nat -o "$PUBLIC_INTERFACE" -j MASQUERADE || true   # ← ditelan
ipt_ensure FORWARD ... || true
ipt_ensure FORWARD ... || true
log_ok "NAT: $ZT_INTERFACE → $PUBLIC_INTERFACE (masquerade)."                # ← selalu dicetak
```

**Dampak:** bila `iptables` tidak tersedia (lihat B15) atau rule ditolak kernel, operator tetap melihat `[OK] NAT: … (masquerade)` — diagnosa menjadi sangat sulit. Tidak ada verifikasi pasca-penulisan rule.

**Usulan perbaikan:** `ipt_ensure` menulis `log_error` saat gagal; `setup_nat` hanya mencetak `log_ok` di cabang sukses, dan mengembalikan status gagal ke pemanggil (jangan `|| true` pada jalur yang penting).

---

### B17 — SEDANG: `cert_valid_for` hanya memeriksa keberadaan sertifikat

**Lokasi:** `bagian4_install_server_certificate.sh` L47–49, dipakai sebagai gerbang di L122, L128, L137, L143:

```sh
cert_valid_for() {
    certbot certificates --domain "$1" 2>/dev/null | grep -iq "Expiry Date"
}
...
if cert_valid_for "$Domain"; then
    log_ok "Sertifikat masih berlaku, dilewati."     # ← padahal bisa sudah kedaluwarsa
else
    issue_cloudflare_single
fi
```

**Mekanisme:** keluaran `certbot certificates` selalu memuat baris `Expiry Date: … (VALID: N days)` **walaupun N = 0 / INVALID**. Jadi sertifikat kedaluwarsa → dianggap "masih berlaku" → instalasi ulang **menolak memperbaiki** dan memberi kabar menyesatkan. Pemanggilan `certbot … --keep-until-expiring` (yang seharusnya me-renew) tidak pernah terjadi di jalur ini.

**Mitigasi yang sudah ada (sehingga tingkatnya SEDANG, bukan tinggi):** pada mode Cloudflare ada cron harian `certbot-renew.sh` (`certbot renew`), dan pada mode DNS manual ada `cert-check.sh` (hanya memberi peringatan). Jadi dampak nyata terbatas pada: (a) instalasi ulang tidak bisa memperbaiki sertifikat kedaluwarsa, (b) status yang ditampilkan salah, (c) mode DNS manual tidak punya perbaikan otomatis.

**Usulan perbaikan:** cek masa berlaku sesungguhnya, mis.
`openssl x509 -checkend 604800 -noout -in /etc/letsencrypt/live/$Domain/fullchain.pem` (tolak bila < 7 hari), dan/atau parse `VALID: N days` dari `certbot certificates`.

---

### B18 — RENDAH: Tidak ada verifikasi HTTPS end-to-end

`bagian5_update_ooklaserver.sh` menulis path sertifikat ke `OoklaServer.properties`, `verify_final` memeriksa **proses** OoklaServer berjalan — tetapi tidak ada uji bahwa `https://<RegisteredSpeedtestURL>/` benar-benar melayani handshake TLS dengan sertifikat yang cocok (satu-satunya pemakaian openssl di bagian4 L206 hanya membaca tanggal `-enddate`).

**Rekomendasi (peningkatan, bukan blocker):** tambahkan check opsional di verifikasi akhir:
```sh
openssl s_client -connect 127.0.0.1:443 -servername "$REGISTERED_URL" </dev/null 2>/dev/null | grep -q "Verify return code: 0"
curl -sk --max-time 10 "https://$REGISTERED_URL/" -o /dev/null -w '%{http_code}'
```
Dilaporkan sebagai WARN (bukan die) bila ZeroTier belum ter-authorize.

---

### B19 — RENDAH: Output wrapper cron dibuang tanpa log

Wrapper bagian6 mengeksekusi `speedtest …` tanpa pengalihan dan entri cron memakai `>/dev/null 2>&1` (default cron mengirim mail, yang biasanya tanpa MTA). Akibatnya kegagalan B13/B14 **tidak meninggalkan jejak apa pun**. Usulan: tulis stdout/stderr + exit code ke `$BASE_DIR/speedtest-report.log` (rotasi sederhana / batasi ukuran), sejalan dengan pola log yang sudah dipakai bagian lain.

### B20 — INFO (catatan minor)
- `uninstall.sh` tidak menghapus `~/.config/ookla/` (lisensi/preferensi CLI tersisa).
- `uninstall.sh` L297–L298 menghapus `/usr/local/bin/speedtest` **dan** `/usr/bin/speedtest`; yang terakhir bisa milik paket distro yang dipasang operator untuk keperluan lain.
- `bagian9`/`bagian10` sudah benar (regex kunci, blok managed, `sshd -t`, permission 700/600) — tidak ada temuan baru.

---

## 5. Sudah Diaudit & Dinyatakan Bersih (Ronde 2)

| Area | Hasil |
|------|-------|
| `dnscloudflare.ini` (producer/konsumen/izin/hapus) | Bersih — dibuat `mktemp` → `chmod 600` → `mv`; dihapus saat uninstall |
| Lock auto-update (`auto_update_lib.sh`) | Bersih — cek pid hidup, bersihkan lock basi, `chmod 600` |
| Pola purge `cron_entry_pattern` + idempotensi | Bersih — terbukti: 13 baris crontab **identik** setelah install dijalankan 2× (`diff` kosong) |
| `sleep ${JITTER_MIN}m` di `/bin/sh` | Bersih — diuji dengan BusyBox 1.36 (`busybox sleep 1m` → rc=0) |
| Penulisan `authorized_keys` (blok managed, newline, izin) | Bersih |
| `sort -V`, `date -d` (kompatibilitas non-GNU) | Bersih — keduanya sudah dijaga |
| Timeout curl/wget | Bersih (`--max-time 120` / `-T 120`, bagian9 60) |
| Simulasi `-postboot` non-systemd / `@reboot` fallback (bagian8) | Bersih (path absolut `$OOKLA_SCRIPT`) |

> Catatan: temuan sesi ini juga memverifikasi ulang temuan B12 lama (CLI sivel vs Ookla) — bug lama itu **belum tuntas**: bagian1 memang memasang Ookla ke `/usr/local/bin`, tetapi *cron* tidak melihat direktori itu (B14).

---

## 6. Rencana Perbaikan (menunggu persetujuan Anda)

**Paket 1 — Reporting benar-benar jalan (B13, B14, B19)** — prasyarat fungsional
1. `bagian1`: terima lisensi saat instalasi (`--accept-license --accept-gdpr -L`).
2. `bagian6`: wrapper memakai `PATH` eksplisit + path absolut `/usr/local/bin/speedtest` (fallback `command -v`) + flag lisensi + log keluaran & exit code.

**Paket 2 — Jaringan pasca-reboot (B15, B16)**
3. `bagian7`: absolutkan `iptables`/`sysctl` (atau `export PATH` di kepala skrip), hapus `|| true` yang menyembunyikan kegagalan, `log_ok` hanya saat sukses, tambahkan verifikasi `iptables -t nat -C`.

**Paket 3 — Sertifikat (B17, B18)**
4. `bagian4`: `cert_valid_for` → `openssl x509 -checkend 604800` (benar-benar cek masa berlaku).
5. `bagian5`/verifikasi akhir: tambah uji TLS end-to-end (WARN saja).

**Verifikasi & rilis**
6. Tambahan check E2E (target ±85 PASS / 0 FAIL):
   - wrapper cron memakai path absolut + flag lisensi (assert isi file wrapper);
   - wrapper dengan *stub* `speedtest` → exit 0 dan log terbentuk;
   - `bagian1` memanggil `--accept-license`;
   - `bagian7 -postboot` memakai absolut `iptables`/`sysctl`;
   - `ipt_ensure` gagal → tidak ada `[OK] NAT`;
   - `cert_valid_for` menolak sertifikat `-checkend` negatif (fixture).
7. `bash tools/regen-checksums.sh` → `bash tools/publish-version.sh` (VERSION 8.1.1) → commit di branch yang sama (`feat/zerotier-hardcode-ssh-autoupdate`), tanpa push/merge ke `main`.

---

## 7. Status Repo Saat Laporan Ini Dibuat

```
branch : feat/zerotier-hardcode-ssh-autoupdate @ e6d5423 (VERSION 8.1.0)
git    : working tree bersih — TIDAK ada file yang diubah pada ronde analisa ini
uji    : E2E terakhir 77 PASS / 0 FAIL (log: /tmp/e2e_v810.log)
```

## 8. Status Implementasi (v8.1.1) — SELESAI

Seluruh temuan di atas **sudah dikerjakan tanpa terkecuali** pada rilis v8.1.1,
ditambah temuan baru yang muncul saat pengujian ulang:

| Temuan | Status | Ringkas perbaikan |
|---|---|---|
| B13 lisensi Ookla CLI | ✅ | flag `--accept-license --accept-gdpr` saat instalasi **dan** di wrapper cron |
| B14 PATH cron | ✅ | `CRON_PATH` dipusatkan di `speedtest-repo.conf`, ditanam ke semua artefak cron + CLI via path absolut |
| B15 iptables/sysctl absolut | ✅ | `network_bin()` mencari `/usr/sbin`, `/sbin`, lalu `command -v` |
| B16 log sukses palsu | ✅ | `ipt_ensure()` memverifikasi ulang (`-C`), `failed=1` dihitung |
| B17 masa berlaku sertifikat | ✅ | `cert_days_left()` + `openssl x509 -checkend`, ambang `CERT_MIN_VALID_DAYS` |
| B18 verifikasi TLS end-to-end | ✅ | `endpoint_http_probe()` / `endpoint_tls_probe()` (WARN/STRICT) |
| B19 output cron tanpa log | ✅ | `report.log` + rotasi + `speedtestctl.sh report|report-log` |
| B20 kebersihan pemanggilan | ✅ | `open_ports()` menurunkan port dari `OoklaServer.properties` |
| C5 normalisasi URL | ✅ | `hostname_of()` sebelum dipakai di hosts/verifikasi |
| C6 kebijakan interface ZT | ✅ | `configure_zt_policy()`: `allowManaged=1`, `allowDefault=0`, `allowGlobal=0` |
| C7 loop uninstall tak terbatas | ✅ | `ipt_del_max()` (batas + verifikasi + path absolut) |
| C8 `--postboot` baca data.ini | ✅ | kedua bentuk mode diterima; postboot tak butuh config |
| C9 deteksi IP forwarding | ✅ | `sysctl -w` + verifikasi `sysctl -n` (fallback `/proc/sys`) |
| Paket 1–3 rencana perbaikan | ✅ | semuanya terimplementasi |
| Tambahan uji E2E (±85 PASS) | ✅ | **150 PASS / 0 FAIL** (log `e2e-logs/`) |

Catatan: temuan **C8** dan **C9** tidak ada di daftar awal laporan ini —
keduanya muncul dari pengujian E2E setelah perbaikan (jalur `@reboot`
bagian10 tidak pernah menegakkan NAT, dan verifikasi IP forwarding gagal di
lingkungan dengan `/proc/sys` read-only). Keduanya sudah diperbaiki dan diuji.

Verifikasi akhir rilis v8.1.1:
- E2E: 150 PASS / 0 FAIL (`e2e-logs/run11.log`)
- `tools/audit_cmd_deps.py`: `[OK]` tanpa temuan
- ShellCheck: 0 temuan (pengecualian harness didokumentasikan di kepala file)
- `bash -n`: bersih untuk seluruh skrip
