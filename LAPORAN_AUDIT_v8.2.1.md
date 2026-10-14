# Laporan Audit Mendalam — v8.2.1

**Objek audit:** repo `speedtest` (installer OoklaServer + ZeroTier + SSH + auto-update + nPerf Server)
**Tanggal:** 14 Oktober 2026
**Versi:** `8.2.1` (cabang `feat/nperf-server-v8.2.0`)
**Sifat audit:** pencarian potensi *leak*, *bug*, dan *error* yang baru muncul di masa depan,
plus verifikasi bahwa **semua spesifikasi teknis & kriteria proyek terimplementasi**.

---

## 1. Ringkasan eksekutif

| Aspek | Hasil |
|---|---|
| Uji E2E (harness mock, `unshare -rm`) | **241 PASS / 0 FAIL**, RC=0 (`e2e-logs/run21.log`) |
| Audit dependensi & gerbang otomatis | **RC 0**, tanpa temuan (`tools/audit_cmd_deps.py`) |
| ShellCheck (seluruh **22 skrip**) | **0 temuan** (flag produksi + pengecualian terdokumentasi) |
| Integritas artefak | `checksums.sha256`: **22/22 OK**; `versions/8.2.1/`: **23 berkas**, 22 hash OK |
| Validasi sintaks | `bash -n` bersih untuk semua skrip |
| Kepatuhan spesifikasi teknis | **Terpenuhi** (lihat §4) |

**Kesimpulan:** tidak ada lagi temuan terbuka di dalam kode. Satu bug senyap nyata
ditemukan dan diperbaiki pada audit ini (escaping substitusi `sed`, temuan A11).
Dua hal **di luar kode** tetap menjadi tanggung jawab operator: **rotasi kredensial**
(token Cloudflare & PAT GitHub yang pernah beredar) dan, bila diinginkan,
**pembersihan riwayat git** (nomor telepon legacy). Detail di §6.

---

## 2. Ruang lingkup & metodologi

**Statis**
- Pembacaan baris-per-baris 22 skrip produksi + konfigurasi terpusat
  (`speedtest-repo.conf`, 54 kunci terkelola) dan `data.ini`.
- Pelacakan aliran data kunci: `data.ini` → `speedtest-repo.conf` → nilai
  ter-*generate* (`speedtestctl.sh`, unit systemd, `nperf-server.conf`,
  `certbot-renew.sh`) → dipakai layanan.
- Pencarian pola rentan: `curl|bash` tanpa verifikasi, `eval`, `source` berkas
  data, substitusi `sed` tanpa escaping, `chmod` berlebihan, TOCTOU pada berkas
  sementara, penanganan `rc` pada jalur non-kritis, kebocoran path/URL internal.

**Dinamis**
- Harness E2E menjalankan instalasi **nyata** di dalam namespace terisolasi
  (`unshare -rm --map-root-user`) dengan `/etc`, `/root`, `/usr/local/bin`,
  `/usr/sbin` dan tool sistem di-mock: 241 asersi (instalasi bersih, idempotensi,
  self-update, gerbang ZeroTier, uninstall, mode pipe `curl | bash`, container,
  `@reboot`, NAT, sertifikat, nPerf 8081/8443, jalur DEFERRABLE, hardening).
- Tidak satu pun skrip produksi dijalankan langsung di host sandbox
  (tidak menyentuh root/systemd/certbot sistem).

**Batas audit**
- Tidak menguji server produksi pengguna; tidak mem-*reverse-engineer* biner
  pihak ketiga (Ookla CLI, ZeroTier, paket nPerf) — hanya **pin hash** & verifikasi
  tanda tangan repo.

---

## 3. Temuan & perbaikan (kode)

Tabel penuh beserta dampaknya ada di `OPTIMIZATION_NOTES.md` (Ronde 4, A1–A13);
CHANGELOG v8.2.1 item 1–17. Ringkasannya:

| # | Temuan | Tingkat | Status |
|---|---|---|---|
| A1 | `speedtest-repo.conf` di-`source` → dieksekusi sebagai shell root | **Tinggi** | **FIXED** — parser `KEY=VALUE` murni (`load_repo_conf`), kunci berbahaya dilewati |
| A2 | Loader self-update tidak mengenali kunci `NPERF_*` (perubahan konfigurasi diabaikan) | **Tinggi** | **FIXED** + gate otomatis di `audit_cmd_deps.py` |
| A3 | Verifikasi `checksums.sha256` hanya per-berkas saat unduh | Sedang | **FIXED** — `verify_checksums_manifest()`, `install.sh --verify-only`, verifikasi pasca-self-update |
| A4 | Biner pihak ketiga dipasang tanpa hash | **Tinggi** | **FIXED** — pin SHA-256 per arsitektur (Ookla CLI 4 arch, ZeroTier) + tolak bila tak terverifikasi |
| A5 | Repo APT nPerf memakai `trusted=yes` di Debian 13 | **Tinggi** | **FIXED** — diverifikasi: `InRelease` **bookworm & trixie** sah → `signed-by` untuk semua codename |
| A6 | Backup drop-in sshd di `/tmp` | Sedang | **FIXED** — `/var/backups/speedtest-sshd-dropin.conf.bak` |
| A7 | Firewall dipilih dari keberadaan biner, bukan backend aktif | Sedang | **FIXED** |
| A8 | `install.log` tumbuh tanpa batas; `--help` butuh root | Rendah | **FIXED** |
| A9 | `speedtestctl nperf-restart` gagal senyap tanpa systemd/init.d | Rendah | **FIXED** |
| A10 | nPerf ramdisk: `cp` sebelum `mkdir` | Rendah | **FIXED** |
| A11 | **Substitusi `sed -i "s\|__X__\|$VAR\|"` korup bila nilai memuat `&`/`\|`** | **Tinggi (bug senyap)** | **FIXED** — helper `sed_escape_repl()` di **semua 10 titik** + uji E2E |
| A12 | Kegagalan repo nPerf DEFERRABLE tidak terlihat di ringkasan akhir | Sedang (operasional) | **FIXED** — penanda `repo_skipped` + peringatan penutup (mode install & `--config-only`) |
| A13 | Kode mati `die()` di fallback `bagian7` (SC2329) | Rendah | **FIXED** — dihapus; ShellCheck 0/22 skrip |

**Catatan A11 (paling penting pada ronde ini):** bila path sistem memuat `&`,
`sed` menafsirkannya sebagai *backreference* sehingga berkas hasil generate
(`speedtestctl.sh`, unit service, config nPerf) bisa **korup tanpa pesan error**;
karakter `|` bahkan memutus delimiter. Kini seluruh nilai placeholder di-escape
(`\` → `\\`, `&` → `\&`, `|` → `\|`) dan diuji dengan simulasi `sed` nyata.

---

## 4. Verifikasi kepatuhan spesifikasi teknis

| Kriteria (permintaan proyek) | Implementasi | Bukti uji |
|---|---|---|
| Instalasi **satu perintah**; operator hanya mengisi `data.ini`; semua dependensi otomatis | `install.sh` (`curl ... \| bash`) menyiapkan file pendukung, urutan bagian0–12 bebas konflik | E2E §1, §7 (mode pipe), §8 (anti version-skew) |
| **ZeroTier wajib** & data ZT **hardcode di repo**, bukan di `data.ini` | `speedtest-repo.conf:20-27` (network/moon/exit-node/auth) + gerbang `bagian7` | E2E §4 (belum authorize → GAGAL), §5 (authorize → SUKSES) |
| `RegisteredSpeedtestURL` dipetakan ke **localhost** via `/etc/hosts` | `HOSTS_MANAGED/HOSTS_FILE=/etc/hosts/HOSTS_TARGET_IP=127.0.0.1` + marker `speedtest-managed` | E2E §18 (normalisasi URL), §9 (kasus container: `/etc/hosts` mount point) |
| **SSH kunci otomatis** dari `https://github.com/smahud.keys` + konfigurasi sshd | `bagian9_ssh_access.sh:34` (+ backup drop-in di `/var/backups`) | E2E §1 (instalasi penuh), audit statis |
| **Auto-update tanpa intervensi**: setiap instalasi memeriksa repo & self-update | `speedtest-selfupdate.sh` + cron + `install.sh --verify-only` pasca-update | E2E §3 (repo mock naik ke 99.0.0), §21 (verifikasi integritas pasca-update) |
| Self-update hanya **menegakkan ulang konfigurasi** (tidak mengubah kebijakan) | mode `--config-only` pada `bagian12` & bagian lain | E2E §21 (PORT kembali 8081, redirect 443 kembali `1`) |
| **nPerf server koeksistensi** dengan Ookla: Ookla 5060/8080 + LE cert; nPerf **8081/8443** | `NPERF_HTTP_PORT=8081`, `NPERF_TLS_PORT=8443`; peringatan bentrok port Ookla | E2E §20 (paket, config, status, uninstall), §21 (jalur systemd & non-systemd) |
| Redirect **80 → 8081** dan **443 → 8443** aktif | `NPERF_REDIRECT_80/443=1` + aturan nftables | E2E §20 (redirect 443 dipulihkan), §21 |
| Paket nPerf dari **repo resmi** + paket terverifikasi | `signed-by` semua codename + pin `NPERF_GPG_FINGERPRINT` | E2E §21: kunci asing **DITOLAK**, kunci asli **diterima**, jalur darurat `trusted=yes` opt-in |
| Anti-DOS nft & **watchdog** bawaan nPerf | aturan `nft` anti-DOS (bounded ≤20) + hapus `/etc/cron.d/nperf-server` | E2E §20/§21 (rule `nPerfServer` terpasang, watchdog dihapus) |
| TLS nPerf **self-managed** (bukan certbot) | `bagian12` tidak pernah memanggil certbot; sertifikat LE hanya untuk Ookla | E2E §20 (config TLS 8443), audit statis |
| Uninstall bersih + opsi **`--purge`** | `uninstall.sh` (rule nft, repo, watchdog, paket, `MANAGED_FILES`) | E2E §6, §17, §19, §20-G |
| Jalur non-kritis **tidak menggagalkan** instalasi utama | kegagalan repo/nPerf → rc 0 + peringatan jelas | E2E §21-F, §21 D3 (penolakan repo DEFERRABLE) |
| Integritas unduhan end-to-end | `MANIFEST`, `checksums.sha256`, `<file>.sha256` per berkas | E2E §21-C (`--verify-only`: bersih rc 0, dirusak rc 1 + nama berkas), §21-D |

---

## 5. Bukti eksekusi gate (artefak final v8.2.1)

```
bash tests/e2e_install_test.sh      → HASIL: 241 PASS / 0 FAIL   (RC=0)   [run21.log]
python3 tools/audit_cmd_deps.py     → RC 0 (parity conf 54/54, tanpa perintah tanpa guard)
shellcheck -s bash -e SC1091,SC1090,SC2154,SC2034  (22 skrip) → 0 temuan
sha256sum -c checksums.sha256       → 22/22 OK
versions/8.2.1/                     → 23 berkas; sha256sum -c → 22 OK
bash -n (semua skrip)               → bersih
```

Riwayat uji (transparansi): `run17` = 224 PASS / 8 FAIL (seluruh 8 = ekspektasi
harness yang usang, bukan regresi — sudah diperbaiki), `run18` = tidak sah (harness
sedang diedit saat berjalan), `run19` = 236 / 2 (D3 pin kunci; ekspektasi rc &
sumber pin diperbaiki di harness), **`run20` & `run21` = 241 / 0**.

---

## 6. Risiko tersisa (di luar kode) & rekomendasi

| # | Risiko | Dampak | Tindakan yang disarankan |
|---|---|---|---|
| ① | Token Cloudflare nyata masih ter-*commit* di `legacy/autocertbot.sh` (riwayat git) & dapat diunduh publik | penyalahgunaan API domain/DNS Anda | **Rotasi token CF sekarang**; bila mau, bersihkan riwayat (`git filter-repo`) lalu force-push |
| ② | PAT GitHub yang pernah dipakai push | akses repo tanpa izin | **Cabut PAT** di GitHub → Settings → Developer settings |
| ③ | Nomor telepon/email pada header `legacy/serverinstall.sh` | *privacy leak* kecil | opsional: hapus di riwayat (bersamaan dengan ①) |
| ④ | Biner ZeroTier tersimpan di riwayat repo (dipakai installer) | ukuran repo; biner tak dapat diaudit publik | sudah dikunci dengan pin SHA-256; biarkan bila tak mengganggu |
| ⑤ | `curl \| bash` pihak ketiga (packagecloud, install.zerotier.com, installer certbot) — tidak ada checksum resmi | rantai pasok | tidak bisa dipin; sudah didokumentasikan + komponen diverifikasi ulang setelah instalasi |
| ⑥ | Rotasi kunci repo nPerf di masa depan | repo nPerf mati bila kunci berubah | kini **terdeteksi**: pesan `Fingerprint kunci repo nPerf TIDAK cocok` + peringatan penutup; perbarui `NPERF_GPG_FINGERPRINT` saat nPerf berganti kunci |
| ⑦ | Sisa berkas sumber nPerf (`.dat` 1 GiB) di ramdisk | butuh RAM ~1,2 GiB | sudah konfigurable & non-aktif secara default (`NPERF_HTTP_FILES_DIR`), status menampilkan jika aktif |

**Rekomendasi operasional:** rotasi kredensial terautomasi tiap 90 hari, aktifkan
*secret scanning* + *push protection* di GitHub, dan jalankan
`bash tests/e2e_install_test.sh` + `python3 tools/audit_cmd_deps.py` sebelum tiap rilis.

---

## 7. Cara memverifikasi sendiri (audit ulang)

```bash
cd repo-speedtest
bash tests/e2e_install_test.sh          # 241 asersi, mock namespace (aman di server apa pun)
python3 tools/audit_cmd_deps.py         # RC 0 = lolos semua gerbang
shellcheck -s bash -e SC1091,SC1090,SC2154,SC2034 *.sh tools/*.sh tests/*.sh
bash install.sh --verify-only ; echo "rc=$?"   # 0 = artefak utuh, 1 = ada yang berubah/rusak, 2 = manifest hilang
sha256sum -c checksums.sha256
```

---

## 8. Status rilis

- `VERSION` = **8.2.1**; `versions/8.2.1/` = 23 berkas (snapshot resmi untuk auto-update).
- Perubahan v8.2.1 bersifat **hardening tanpa mengubah perilaku instalasi**:
  operator tetap mengisi `data.ini`, menjalankan satu perintah, sisanya otomatis.
- Belum di-*commit*/push pada sesi ini sampai Anda mengizinkan (lihat pesan akhir).

*Dokumen ini disusun otomatis dari hasil audit & uji pada 14 Oktober 2026;
setiap klaim di §5 dapat direproduksi dengan perintah di §7.*
