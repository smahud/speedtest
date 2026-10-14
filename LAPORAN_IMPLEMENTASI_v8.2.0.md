# Laporan Implementasi v8.2.0 — nPerf Server (Layanan Speedtest Kedua)

Status: **selesai, terverifikasi, siap review** — commit `47693cc` pada branch
`feat/nperf-server-v8.2.0` (percabangan dari `main` = v8.1.1 `4291707`).
**Belum di-push / belum di-merge** (menunggu perintah eksplisit).

---

## 1. Ringkasan Fitur

Paket **resmi nPerf Server** (`nperf-server` dari `repository.nperf.com`)
dipasang berdampingan dengan OoklaServer di host/host yang sama, sesuai
permintaan: *di bawah root directory speedtest (mengikuti BASE_DIR dari
`data.ini`), standard instalasi, hanya port default 8081/8443, config lain
dibiarkan.*

| | OoklaServer (repo ini) | nPerf Server (baru) |
|---|---|---|
| HTTP | `8080` (OoklaServer.properties) | **`8081`** (`PORT`) |
| TLS | 443/5061 (sertifikat Let's Encrypt repo ini) | **`8443`** (`TLS_PORT`, sertifikat dikelola nPerf) |
| UDP | `5060` | — (TCP saja) |
| Redirect 80→HTTP / 443→TLS | — | **aktif** (`REDIRECT_PORT_80/443=1`, nftables) |
| Pembaruan paket | `ooklaserver.sh` | repo resmi nPerf (apt/dnf/zypper) |

Keputusan yang diminta dan sudah diterapkan:

1. **Redirect 80→8081 & 443→8443 aktif** (default paket nPerf).
2. **Pembaruan paket lewat repo resmi nPerf** — self-update repo ini tidak
   pernah menyentuh paketnya.
3. **Self-update repo ini hanya menegakkan ulang konfigurasi + service nPerf**
   (mode `--config-only`).
4. **Uninstall membersihkan nPerf sepenuhnya**; opsional `--purge` menghapus
   paket + config + UUID (default: paket & identitas server dipertahankan).

## 2. Berkas

**Baru**
- `bagian12_nperf_server.sh` — modul nPerf (601 baris):
  - `[data.ini]` = pasang/tegakkan penuh; `--config-only` = config + service
    (dipakai self-update harian, sekaligus percobaan ulang otomatis bila paket
    belum terpasang); `--status` = ringkasan read-only.
  - Repo APT: kunci GPG → `/etc/apt/keyrings/nperf.asc` (+ fallback
    `/usr/share/keyrings`), baris repo `signed-by`; khusus **Debian 13
    (trixie)** memakai `trusted=yes` sesuai instruksi resmi nPerf.
  - Repo RPM: `.../rpm/rhel/<major>.repo` → `/etc/yum.repos.d/nperf-server.repo`.
  - **Alpine tidak didukung** (tanpa paket apk) → dilewati berpesan jelas.
  - Config idempotent (hanya 4 kunci: `PORT`, `TLS_PORT`, `REDIRECT_PORT_80`,
    `REDIRECT_PORT_443`) + backup ke `$BASE_DIR/nperf/backup/`.
  - Service: systemd `daemon-reload`/`enable`/`start|restart`; fallback
    `/etc/init.d/nperf-server` + cron `@reboot`; watchdog bawaan paket
    (`/etc/cron.d/nperf-server`, dibuat `setup-initd-autostart` `*/2`) dihapus.
  - Verifikasi non-fatal: HTTP `Server: nPerf` di 8081, TLS 8443, UUID, dan
    rule nftables (redirect + anti-DOS).
  - Artefak repo (`BASE_DIR` = lokasi `data.ini`): `nperf/install-nperf.log`,
    `nperf/backup/*`, `nperf/.nperf-state`.

**Diubah**
- `install.sh` — `run_section "bagian12_nperf_server"` (setelah bagian10/11,
  **sebelum bagian7** agar paket pihak ketiga tidak tertahan bila node ZeroTier
  belum di-authorize; bagian7 tetap terakhir), masuk `SUPPORT_FILES` + blok
  `chmod`, dan `verify_final` menambah pemeriksaan nPerf.
- `speedtest-repo.conf` — blok kebijakan `NPERF_*` (enabled, port, redirect,
  autostart, tmpfs opsional).
- `common_functions1.sh` — `open_ports()` membuka 8081/8443 (config-driven,
  ufw & firewalld).
- `bagian8_cek_konfigurasi.sh` — `speedtestctl.sh` menerima
  `nperf-status|nperf-restart|nperf-logs`.
- `speedtest-selfupdate.sh` — memanggil `bagian12 --config-only` tiap update.
- `auto_update_lib.sh`, `tools/regen-checksums.sh`, `MANIFEST` — berkas baru
  ikut dipantau/di-checksum.
- `uninstall.sh` — **langkah 7c** + opsi **`--purge`**:
  stop & disable service, hapus **semua** rule nftables ber-comment
  `nPerfServer` (redirect `ip`/`ip6` nat prerouting **dan** anti-DOS
  `inet filter input` yang tidak dihapus paket saat service berhenti; batas
  iterasi + verifikasi tiap langkah → tidak mungkin menggantung), repo + kunci,
  watchdog cron, artefak `$BASE_DIR/nperf`; tag cron baru ikut dibersihkan.
- `tests/e2e_install_test.sh` — seksi **20** baru (54 check).
- Docs: `README.md` (header v8.2.0, tabel kebijakan, management, uninstall,
  struktur file, **seksi 12 nPerf**), `CHANGELOG.md` (entri v8.2.0),
  `OPTIMIZATION_NOTES.md` (ronde 3 + status verifikasi).
- `VERSION` = `8.2.0`, `MANIFEST`/`checksums.sha256`/`*.sha256` diregenerasi,
  snapshot `versions/8.2.0/` (23 file).

## 3. Risiko dari paket resmi & cara pengendaliannya

| Temuan bedah paket (nperf-server 2.2.11) | Pengendalian |
|---|---|
| Path paket tetap (`/usr/bin/nPerfServer`, `/etc/nperf/…`, `/var/lib/nperf-server/`) | Tidak di-relokasi; yang mengikuti `BASE_DIR` hanya artefak repo |
| `PORT` wajib 8080 atau 8081 | Dipakai 8081 (8080 milik Ookla); nilai lain ditolak + peringatan |
| Rule anti-DOS `inet filter input … comment "nPerfServer"` bertahan setelah stop | Dihapus di uninstall 7c (verifikasi + batas iterasi) |
| Sertifikat TLS 8443 dikelola nPerf (CERT-UPDATE) | certbot/Let's Encrypt repo ini tidak menyentuh nPerf |
| Watchdog cron `*/2` bawaan saat init.d | Dihapus bila systemd tersedia |
| Alpine tanpa paket apk | Modul dilewati, instalasi Ookla tetap utuh |
| Repo/jaringan nPerf tidak terjangkau | Kegagalan *deferrable*: instalasi tidak digagalkan, dicoba ulang otomatis tiap self-update |
| Hapus manual berkas repo/kunci | Setiap jalur instalasi memastikan repo + kunci ada (idempotent, tanpa jaringan bila sudah benar) |

## 4. Bukti Verifikasi

| Uji | Hasil |
|---|---|
| E2E harness (mock namespace, tidak menyentuh sistem) | **206 PASS / 0 FAIL** — `e2e-logs/run16.log` (final, artefak beku) |
| Audit dependensi perintah/PATH cron | `python3 tools/audit_cmd_deps.py` → `[OK]`, tanpa temuan |
| ShellCheck 0.11.0 (skrip produksi, pengecualian terdokumentasi) | **0 temuan** |
| Syntax | `bash -n` seluruh skrip OK |
| Checksum | `sha256sum -c checksums.sha256` → 22 OK; snapshot `versions/8.2.0/` 23 file |

Cakupan seksi 20 (nPerf) di harness: instalasi paket + repo + kunci, config
8081/8443 + redirect, backup config, service (jalur **systemd** dan **init.d**),
idempotensi tanpa jaringan, `--config-only` (config menyimpang ditegakkan +
service direstart), `--status`, `NPERF_ENABLED=Tidak`, repo `bookworm`
(`signed-by`) vs `trixie` (`trusted=yes`), jalur **offline** tetap `rc=0`,
uninstall (rule nftables, repo, watchdog, paket dipertahankan), `--purge`,
dan anti-menggantung saat `nft` "berbohong".

## 5. Cara Pakai / Uji di Server

```bash
# setelan (opsional; default sudah 8081/8443 + redirect aktif)
#   speedtest-repo.conf: NPERF_ENABLED, NPERF_HTTP_PORT, NPERF_TLS_PORT,
#                        NPERF_REDIRECT_80, NPERF_REDIRECT_443, NPERF_AUTOSTART

# pasang/tegakkan ulang manual
bash $BASE_DIR/bagian12_nperf_server.sh
bash $BASE_DIR/bagian12_nperf_server.sh --status
bash $BASE_DIR/speedtestctl.sh nperf-status
bash $BASE_DIR/speedtestctl.sh nperf-restart

# validasi & pendaftaran server ke nPerf (bukan otomatis):
#   https://server-check.nperf.com/   (port standar 8081/8443 terdeteksi)

# nonaktifkan modul (tidak menyentuh config/service nPerf lagi):
#   NPERF_ENABLED="Tidak" di speedtest-repo.conf, lalu self-update / rerun installer

# bersihkan: default mempertahankan paket & UUID
bash $BASE_DIR/uninstall.sh --force
# hapus total (paket + config + UUID):
bash $BASE_DIR/uninstall.sh --force --purge
```

Rollback versi sebelumnya: pin `REPO_RAW_BASE` ke `versions/8.1.1/`
(snapshot masih tersedia), atau checkout commit `4291707`.

## 6. Catatan Rilis

- Push/merge **belum** dilakukan; branch `feat/nperf-server-v8.2.0` menunggu
  perintah operator (helper: `bash /home/user/push-release.sh`).
- Token GitHub yang dipakai push v8.1.1 harus **dicabut**; kredensial
  Cloudflare pada commit lama harus **dirotasi** (tindakan operator).
