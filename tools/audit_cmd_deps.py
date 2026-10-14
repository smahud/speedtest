#!/usr/bin/env python3
"""audit_cmd_deps.py — Audit statis ketergantungan perintah (dev tool, bukan bagian instalasi).

Tujuan: memastikan SETIAP perintah eksternal yang dipakai skrip installer punya
jalur otomatis, sehingga klaim "satu perintah install = semua dependensi terpasang"
bisa diverifikasi, bukan sekadar diasumsikan.

Cara kerja:
  1. Pindai semua .sh di repo (heredoc dibuang, komentar dibuang).
  2. Ambil token pada POSISI PERINTAH saja: awal baris, setelah | || && ; $( ` ,
     setelah if/then/do/while/until/else/!/time/sudo/env.
  3. Buang assignment (VAR=...), nama fungsi repo, dan builtin shell.
  4. Bandingkan dengan:
       - paket yang dipasang installer (BASE_PKGS di install.sh + apt/apk/yum/zypper),
       - daftar aman (coreutils/POSIX yang pasti ada di semua distro target),
       - perintah opsional yang WAJIB diawali guard (dicek 'command_exists'/'-v').
  5. Laporkan perintah yang tidak masuk kategori mana pun → indikasi "lubang dependensi".

Pakai:  python3 tools/audit_cmd_deps.py     (exit 1 bila ada temuan)
"""
from __future__ import annotations

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── A. Perintah POSIX/coreutils yang ADA di semua distro target ────────────────
SAFE = {
    "free", "sysctl", "pgrep", "pkill", "logger", "flock", "timeout", "openssl",
    "echo", "printf", "read", "cd", "exit", "return", "local", "export", "unset",
    "set", "shift", "eval", "exec", "source", "test", "let", "trap", "umask",
    "wait", "type", "hash", "command", "ulimit", "times", "pwd", "break",
    "continue", "true", "false", "declare", "shopt", "readarray", "mapfile",
    "cat", "cp", "mv", "rm", "ln", "mkdir", "rmdir", "chmod", "chown", "touch",
    "ls", "df", "du", "dd", "sync", "stat", "mktemp", "install", "readlink",
    "realpath", "basename", "dirname", "sed", "awk", "grep", "egrep", "fgrep",
    "sort", "uniq", "head", "tail", "cut", "tr", "wc", "tee", "xargs", "env",
    "find", "cmp", "diff", "which", "seq", "expr", "sleep", "kill", "ps", "pgrep",
    "pkill", "id", "whoami", "groups", "date", "hostname", "uname", "getent",
    "sha256sum", "sha1sum", "md5sum", "tar", "gzip", "gunzip", "zip", "unzip",
    "openssl", "sh", "bash", "dash", "sudo", "su", "logname", "users", "w",
    "timeout", "flock", "nohup", "setsid", "mktemp", "install", "ip", "ifconfig",
    "route", "ss", "netstat", "dig", "nslookup", "host", "ping", "curl", "wget",
    "hostnamectl", "locale", "iconv", "comm", "join", "paste", "split", "csplit",
    "tac", "nl", "od", "shred", "truncate", "mknod", "mkfifo", "sync", "wall",
}

# ── B. Perintah yang WAJIB punya guard `command_exists`/`-v` di skrip ──────────
# Perintah yang boleh dipakai TANPA guard bila file-nya melakukan dispatch
# berdasarkan variabel yang dideteksi (Package manager / init system).
DISPATCH_VARS = ("PKG_MGR", "INIT_SYSTEM", "OS_FAMILY", "OS_ID", "PKG_INSTALL")
DISPATCHABLE = {
    "firewall-cmd", "apk", "apt", "apt-get", "dnf", "yum", "zypper", "pacman", "xbps-install",
    "systemctl", "rc-service", "rc-update", "service", "update-rc.d",
    "chkconfig", "journalctl", "certbot", "snap", "sysctl", "iptables",
}

OPTIONAL_REQUIRES_GUARD = {
    "nft", "ufw", "restorecon", "semanage", "snap", "systemd-run", "rc-service",
    "rc-update", "service", "update-rc.d", "chkconfig", "journalctl", "systemctl",
    "certbot", "zerotier-cli", "zerotier-one", "iptables", "sysctl", "crontab",
    "sshd", "ssh-keygen", "crontab", "mariadb", "mysql", "logrotate", "ufw",
    "apk", "apt-get", "apt", "dnf", "yum", "zypper", "pacman", "xbps-install",
    "pip3", "python3", "pip", "systemd-run", "semanage", "modprobe", "nft",
}

# ── E1. Artefak yang DIEKSEKUSI OLEH CRON ─────────────────────────────────────
# Dasar bug v8.1.0 (B14/B15): cron Debian/Ubuntu/Alpine hanya memberi
# PATH=/usr/bin:/bin → /usr/local/bin (CLI Ookla) dan /usr/sbin (iptables,
# sysctl, ip) TIDAK terlihat, sehingga laporan & NAT mati tanpa pesan.
# Aturan yang ditegakkan di sini: setiap artefak cron WAJIB menyetel PATH
# eksplisit (umumnya dari $CRON_PATH di speedtest-repo.conf).
CRON_ARTIFACTS = [
    "bagian6_automaintenance.sh",   # menulis wrapper cron-speedtest*.sh
    "bagian7_network.sh",           # dipanggil @reboot (--postboot)
    "bagian10_hosts_ssh.sh",        # dipanggil @reboot + self-update
    "speedtest-selfupdate.sh",      # cron harian (update + penegakan config)
    "auto_update_lib.sh",           # dimuat oleh skrip cron di atas
]

# Wajib ada di wrapper yang DIBUAT (di dalam heredoc bagian6): PATH eksplisit,
# path absolut CLI, dan flag lisensi (CLI menolak jalan tanpa TTY bila lisensi
# belum diterima — bug B13).
CRON_TEMPLATE_REQUIREMENTS = [
    ("bagian6_automaintenance.sh", 'PATH="$CRON_PATH_RESOLVED"'),
    ("bagian6_automaintenance.sh", "SPEEDTEST_FLAGS"),
    ("bagian7_network.sh", "export PATH"),
    # Artefak cron yang DIBUAT bagian4 (heredoc): wajib punya PATH eksplisit
    # juga — kalau tidak, renewal/pemantau sertifikat dapat gagal senyap.
    ("bagian4_install_server_certificate.sh", 'PATH="__CRON_PATH__"'),
]

HEREDOC_RE = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
SEP_RE = re.compile(r"\|\||&&|;;|;|\||\(|\)|\$\(|`|&")
PREFIX_RE = re.compile(
    r"^(?:if|then|else|elif|do|while|until|!|time|sudo|env(?:\s+\w+=\S+)*)\s+"
)
CMDNAME_RE = re.compile(r"^([A-Za-z][\w.+-]*)")
SHELL_KEYWORDS = {
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "in", "function", "select", "time", "{", "}", "[[", "]]",
}
CASE_LIST_RE = re.compile(r"(?m)^\s*(?:[A-Za-z0-9_*?.\[\]-]+\|)*[A-Za-z0-9_*?.\[\]-]+\)\s*")

# Token yang muncul dari teks pesan/heredoc setelah masking (bukan perintah).
# Setiap penambahan ke daftar ini harus disertai alasan singkat.
NOISE = {
    # nama file/host/artefak produk (sering jadi argumen/teks pesan)
    "OoklaServer", "OoklaServer.pid", "OoklaServer.properties",
    "OoklaServer.properties.default", "Speedtest", "Sertifikat", "Domain",
    "Port", "Network", "Node", "ZeroTier", "Alpine", "Debian", "Linux",
    "Darwin", "FreeBSD", "Docker", "Uninstall", "Self-update", "Re-exec",
    "Verifikasi", "Idempotensi", "Instalasi", "Jalankan", "Uji", "Kasus",
    "Cukup", "OK", "otomatis", "hosts", "logs", "restart", "uninstall",
    "version", "help", "status", "fetch", "identity", "backup", "user",
    "file", "rule", "nilai", "mungkin", "untuk", "sama", "valid", "drop-in",
    "kunci", "konfigurasi", "kredensial", "detail", "virtual/hostname",
    # nama arsitektur/kode distro (label 'case')
    "aarch64", "x86_64", "i386", "i686", "arm64", "armhf", "armv7l",
    "alpine", "debian", "rhel", "suse", "ubuntu", "rocky", "almalinux",
    "centos", "fedora", "opensuse", "systemd", "openrc", "busybox",
    # sub-perintah CLI yang terbaca sebagai kata pertama argumen
    "authorize", "list", "listnetworks", "orbit", "cek", "bagian4",
}

def strip_inline_comment(code: str) -> str:
    """Potong komentar '#' (di luar tanda kutip) dari satu baris kode."""
    out = []
    quote = None
    i = 0
    while i < len(code):
        c = code[i]
        if quote is not None:
            out.append(c)
            if c == "\\" and i + 1 < len(code):
                out.append(code[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "#" and (i == 0 or code[i - 1].isspace()):
            break
        out.append(c)
        i += 1
    return "".join(out)


def mask_quotes(text: str) -> str:
    """Ganti isi string ('...' / "...") dengan spasi agar teks pesan tidak
    terbaca sebagai perintah. Isi '$(...)' di dalam string tetap diproses."""
    out = []
    i = 0
    quote = None
    while i < len(text):
        c = text[i]
        if quote is not None:
            if c == "\\":
                out.append("  ")
                i += 2
                continue
            if c == quote:
                quote = None
                out.append(" ")
                i += 1
                continue
            if text.startswith("$(", i):
                depth = 0
                j = i
                while j < len(text):
                    if text[j] == "(":
                        depth += 1
                    elif text[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                inner = text[i + 2:j] if j < len(text) else text[i + 2:]
                out.append(" " + mask_quotes(inner) + " ")
                i = j + 1
                continue
            out.append(" ")
            i += 1
            continue
        if c in "\"'":
            quote = c
            out.append(" ")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def iter_commands(path: str):
    """Hasilkan (nomor_baris, nama_perintah) pada posisi perintah."""
    heredoc = None
    in_string = False  # None | "dq" | "sq"
    pending: list[str] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh):
            line = raw.rstrip("\n")
            if heredoc is not None:
                if line.strip() == heredoc:
                    heredoc = None
                continue
            m = HEREDOC_RE.search(line)
            if m:
                heredoc = m.group(1)
            # 1) Buang komentar inline (di luar tanda kutip), baru analisis.
            code = strip_inline_comment(line)
            if not code.strip():
                continue
            # 2) Lewati isi string multi-baris (body awk/sed atau teks pesan).
            n_dq = len(re.findall(r'(?<!\\)"', code))
            n_sq = len(re.findall(r"(?<!\\)'", code))
            if in_string:
                if (n_dq % 2 == 1) or (in_string == "sq" and n_sq % 2 == 1):
                    in_string = False
                continue
            if n_dq % 2 == 1 and not code.rstrip().endswith("\\"):
                in_string = "dq"
            elif n_sq % 2 == 1 and re.search(r"\b(awk|sed|perl)\b[^']*'", code):
                # body awk/sed multi-baris
                in_string = "sq"
            # 3) Buang parameter expansion ${...} (berisi pesan, bukan perintah)
            code = re.sub(r"\$\{[^{}]*\}", "", code)
            # gabung baris lanjutan (backslash) supaya pipeline tetap terbaca
            pending.append(code)
            if code.rstrip().endswith("\\"):
                continue
            text = " ".join(pending)
            pending = []
            masked = CASE_LIST_RE.sub("", mask_quotes(text))
            for seg in SEP_RE.split(masked):
                seg = seg.strip()
                if not seg:
                    continue
                while True:
                    new = PREFIX_RE.sub("", seg, count=1)
                    if new == seg:
                        break
                    seg = new.strip()
                label = re.match(r"([A-Za-z_][\w.|*-]*)\)\s*", seg)
                if label:
                    seg = seg[label.end():].strip()
                if not seg or seg.startswith("-"):
                    continue
                mm = CMDNAME_RE.match(seg)
                if not mm:
                    continue
                name = mm.group(1).rstrip(".-+")
                if name in SHELL_KEYWORDS:
                    continue
                if name in NOISE or name.lower() in {n.lower() for n in NOISE}:
                    continue
                # lewati label 'case' (mis. AUTO_UPDATE_ENABLED) & konstanta huruf besar
                if re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
                    continue
                # lewati assignment (VAR=...) dan definisi fungsi (nama()
                rest = seg[mm.end():]
                if rest.startswith("=") or rest.startswith("()"):
                    continue
                yield lineno + 1, name


def repo_functions(files):
    funcs = set()
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"\s*(?:function\s+)?([A-Za-z_]\w*)\s*\(\)\s*\{?", line)
                if m:
                    funcs.add(m.group(1))
    return funcs


def installer_packages():
    pkgs = set()
    src = os.path.join(REPO, "install.sh")
    txt = open(src, encoding="utf-8", errors="replace").read() if os.path.exists(src) else ""
    for block in re.findall(r"BASE_PKGS=\((.*?)^\)", txt, re.S | re.M):
        for line in block.splitlines():
            line = line.split("#")[0].strip().strip('"\'')
            pkgs.update(t for t in line.split() if t)
    # paket yang muncul di blok pemasangan per distro
    for line in txt.splitlines():
        if re.search(r"(apt-get|apk|dnf|yum|zypper)\b.*install", line):
            for tok in re.findall(r"[a-z0-9][a-z0-9.+-]{2,}", line):
                if tok not in {"install", "update", "upgrade", "yes", "dev", "null",
                               "quiet", "force", "auto", "get", "apt", "apk", "dnf",
                               "yum", "zypper", "add", "repo", "no", "and", "or",
                               "if", "then", "fi", "bash", "log", "info"}:
                    pkgs.add(tok)
    return pkgs


# ═══════════════════════════════════════════════════════════════════════════════
# F–I. Audit konfigurasi & integritas (hardening v8.2.1)
#   Kelas bug yang dicegah: kunci speedtest-repo.conf yang DIABAIKAN karena
#   tidak ada di au_load_repo_config (kasus NPERF_* di v8.2.0), kunci repo yang
#   dieksekusi sebagai shell, hilangnya gerbang verifikasi checksum, dan
#   hilangnya pin SHA-256 untuk biner pihak ketiga.
# ═══════════════════════════════════════════════════════════════════════════════
def _read(path: str) -> str:
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def config_parity_audit() -> bool:
    ok = True
    conf = os.path.join(REPO, "speedtest-repo.conf")
    au = os.path.join(REPO, "auto_update_lib.sh")
    common = os.path.join(REPO, "common_functions1.sh")
    install = os.path.join(REPO, "install.sh")
    selfup = os.path.join(REPO, "speedtest-selfupdate.sh")
    b1 = os.path.join(REPO, "bagian1_install_dependency.sh")
    b7 = os.path.join(REPO, "bagian7_network.sh")

    # ── F. Parity kunci: speedtest-repo.conf ↔ au_load_repo_config() ──────────
    print("=== F. Parity kunci speedtest-repo.conf ↔ au_load_repo_config() ===")
    conf_text = _read(conf)
    conf_keys = set(re.findall(r"^([A-Z_][A-Z0-9_]*)=", conf_text, re.M))
    au_text = _read(au)
    m = re.search(r"au_load_repo_config\(\)\s*\{.*?\n\}", au_text, re.S)
    au_keys = set()
    if m:
        au_keys = set(re.findall(r"^\s+([A-Z_][A-Z0-9_]*)\)", m.group(0), re.M))
    ignored = sorted(conf_keys - au_keys)
    if ignored:
        ok = False
        print("   [MASALAH] kunci ini ada di speedtest-repo.conf tetapi TIDAK")
        print("             dibaca au_load_repo_config() (akan diabaikan senyap):")
        for k in ignored:
            print(f"             - {k}")
    else:
        print(f"   OK: {len(conf_keys)} kunci conf semuanya dikenali loader.")
    print()

    # ── G. speedtest-repo.conf TIDAK boleh dieksekusi sebagai shell ───────────
    print("=== G. speedtest-repo.conf tidak dieksekusi sebagai shell ===")
    offenders = []
    prod = []
    for root, dirs, names in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in {".git", "legacy", "versions", "node_modules", "tests", "tools"}]
        for n in names:
            if n.endswith(".sh"):
                prod.append(os.path.join(root, n))
    for path in sorted(prod):
        rel = os.path.relpath(path, REPO)
        for lineno, line in enumerate(_read(path).splitlines(), 1):
            stripped = strip_inline_comment(line)
            if "speedtest-repo.conf" not in stripped:
                continue
            if re.search(r"(^|[;&|(]|\s)(\.|source)\s+\S*speedtest-repo\.conf", stripped):
                offenders.append(f"{rel}:{lineno}")
    if offenders:
        ok = False
        print("   [MASALAH] file conf dieksekusi (source) — gunakan load_repo_conf():")
        for o in offenders:
            print(f"             - {o}")
    else:
        print("   OK: tidak ada 'source speedtest-repo.conf' di jalur produksi.")
    print()

    # ── H. Gerbang verifikasi integritas wajib ada ───────────────────────────
    print("=== H. Gerbang verifikasi integritas (checksums.sha256) ===")
    need = [
        (common, "verify_checksums_manifest()", "fungsi verify_checksums_manifest"),
        (common, "sha256_of_file()", "fungsi sha256_of_file"),
        (install, "--verify-only", "mode install.sh --verify-only"),
        (install, "verify_checksums_manifest", "pemanggilan verifikasi di install.sh"),
    ]
    miss = [desc for path, token, desc in need if token not in _read(path)]
    # Self-update boleh memakai fungsi langsung ATAU memanggil install.sh
    # --verify-only (satu implementasi); salah satu wajib ada.
    selfup_text = _read(selfup)
    if "verify_checksums_manifest" not in selfup_text and "--verify-only" not in selfup_text:
        miss.append("verifikasi pasca-update di self-update")
    if miss:
        ok = False
        print("   [MASALAH] gerbang integritas hilang/tidak lengkap:")
        for d in miss:
            print(f"             - {d}")
    else:
        print("   OK: verifikasi checksum tersedia di common, install.sh, dan self-update.")
    print()

    # ── I. Pin SHA-256 untuk biner pihak ketiga ──────────────────────────────
    print("=== I. Pin SHA-256 biner pihak ketiga ===")
    b1t, b7t = _read(b1), _read(b7)
    problems = []
    if "OOKLA_CLI_SHA256_X86_64" not in b1t or "OOKLA_CLI_ALLOW_UNVERIFIED" not in b1t:
        problems.append("bagian1: pin/penolakan hash CLI Ookla tidak ditemukan")
    if "OOKLA_CLI_ALLOW_UNVERIFIED" in b1t and "biner TIDAK dipasang" not in b1t:
        problems.append("bagian1: tidak menolak saat hash tidak tersedia")
    if "ZT_ALLOW_UNPINNED_BINARY" not in b7t or "Biner TIDAK dipasang" not in b7t:
        problems.append("bagian7: pin/penolakan hash biner ZeroTier tidak ditemukan")
    if problems:
        ok = False
        print("   [MASALAH] verifikasi biner pihak ketiga tidak lengkap:")
        for p_ in problems:
            print(f"             - {p_}")
    else:
        print("   OK: CLI Ookla & biner ZeroTier diverifikasi sebelum dipasang.")
    print()
    return ok

def main() -> int:
    files = []
    for root, dirs, names in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in {".git", "legacy", "versions", "node_modules"}]
        for n in names:
            if n.endswith(".sh"):
                files.append(os.path.join(root, n))
    files.sort()

    funcs = repo_functions(files)
    pkgs = installer_packages()
    allowed = SAFE | pkgs | funcs

    unguarded = {}
    guarded = {}
    dispatched = {}
    unknown = {}
    for path in files:
        rel = os.path.relpath(path, REPO)
        if rel.startswith("tools/") and rel.endswith(".sh"):
            continue  # tools dev tidak ikut instalasi
        text = open(path, encoding="utf-8", errors="replace").read()
        for lineno, cmd in iter_commands(path):
            if cmd in allowed or cmd.startswith("$"):
                continue
            if cmd in OPTIONAL_REQUIRES_GUARD or cmd in DISPATCHABLE:
                # cek apakah ada guard di sekitar file ini
                if re.search(rf"command_exists\s+{cmd}\b|command\s+-v\s+{cmd}\b", text):
                    guarded.setdefault(cmd, set()).add(rel)
                elif cmd in DISPATCHABLE and any(v in text for v in DISPATCH_VARS):
                    dispatched.setdefault(cmd, set()).add(rel)
                else:
                    unguarded.setdefault(cmd, []).append(f"{rel}:{lineno}")
            else:
                unknown.setdefault(cmd, []).append(f"{rel}:{lineno}")

    print("=== A. Paket yang dipasang otomatis oleh installer ===")
    print("   " + ", ".join(sorted(pkgs)) or "   (kosong)")
    print()

    print("=== E. Audit konteks cron (PATH eksplisit wajib) ===")
    cron_bad = []
    for art in CRON_ARTIFACTS:
        path = os.path.join(REPO, art)
        if not os.path.exists(path):
            print(f"   - {art:<32} [TIDAK ADA]")
            cron_bad.append(art)
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        # Dua mekanisme yang diterima:
        #  1) PATH="..." eksplisit (mis. PATH="$CRON_PATH")
        #  2) path_augment_from_cron_path() — menambahkan $CRON_PATH tanpa
        #     menimpa PATH yang sudah ada (dipakai bagian7/10/self-update/lib)
        has_path = (re.search(r"(?m)^\s*(export\s+)?PATH=", text) is not None
                    or "path_augment_from_cron_path" in text)
        print(f"   - {art:<32} {'OK' if has_path else 'TANPA PATH eksplisit'}")
        if not has_path:
            cron_bad.append(art)
    for art, needle in CRON_TEMPLATE_REQUIREMENTS:
        path = os.path.join(REPO, art)
        text = open(path, encoding="utf-8", errors="replace").read() if os.path.exists(path) else ""
        ok = needle in text
        print(f"   - {art}: '{needle}' {'ada' if ok else 'HILANG'}")
        if not ok:
            cron_bad.append(f"{art}:{needle}")
    print()

    print(f"=== B. Perintah opsional dengan guard 'command -v': {len(guarded)} ===")
    print("   " + ", ".join(sorted(guarded)))
    print()
    print(f"=== B2. Perintah via dispatch (PKG_MGR/INIT_SYSTEM, bukan perintah buta): {len(dispatched)} ===")
    print("   " + ", ".join(sorted(dispatched)))
    print()

    bad = False
    if cron_bad:
        bad = True
        print("=== E2. MASALAH: artefak cron tanpa PATH eksplisit ===")
        for item in cron_bad:
            print(f"   - {item}")
        print("   Tindakan: tambahkan PATH=\"$CRON_PATH\" + export PATH, atau pakai")
        print("             path absolut (mis. $IPTABLES_BIN, $SPEEDTEST_CLI_PATH).")
        print()
    if unguarded:
        bad = True
        print("=== C. MASALAH: perintah opsional TANPA guard ===")
        for cmd in sorted(unguarded):
            print(f"   - {cmd:<16} {', '.join(unguarded[cmd][:5])}")
        print()

    if unknown:
        print("=== D. INFORMASI: token di luar daftar aman — tinjau manual ===")
        for cmd in sorted(unknown):
            locs = unknown[cmd]
            extra = "" if len(locs) <= 4 else f" (+{len(locs) - 4} lokasi)"
            print(f"   - {cmd:<16} {', '.join(locs[:4])}{extra}")
        print()

    # ── F–I. Audit konfigurasi & integritas (hardening v8.2.1) ───────────────
    if not config_parity_audit():
        bad = True

    if not bad:
        print("[OK] Tidak ada perintah opsional tanpa guard di jalur produksi.")
        if unknown:
            print("[CATATAN] Kategori D di atas bersifat informasi (sebagian besar")
            print("          berasal dari text pesan/body awk, bukan perintah). ")
        return 0
    print(
        "Tindakan: pastikan tiap perintah di (C)/(D) (a) ditambahkan ke BASE_PKGS/"
        "bagian1, (b) diberi guard `command_exists`, atau (c) memang ada di semua "
        "distro target (maka tambahkan ke daftar SAFE di tools ini)."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
