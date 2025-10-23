#!/bin/bash

# Deteksi sistem operasi
if [ -f "/etc/alpine-release" ]; then
    OS="alpine"
elif [ -f "/etc/debian_version" ]; then
    OS="debian"
elif [ -f "/etc/redhat-release" ]; then
    OS="centos"
elif [ -f "/etc/os-release" ] && grep -qi "opensuse" /etc/os-release; then
    OS="opensuse"
else
    echo "Sistem operasi tidak dikenali. Skrip dihentikan."
    exit 1
fi

echo "Sistem operasi terdeteksi: $OS"

# Menambahkan crontab untuk auto restart setiap pukul 00:00 dan saat reboot
if [[ "$OS" == "debian" || "$OS" == "centos" || "$OS" == "opensuse" ]]; then
    (crontab -l 2>/dev/null; echo "0 0 * * * /root/ooklaserver.sh restart") | sort -u | crontab -
    (crontab -l 2>/dev/null; echo "@reboot /root/OoklaServer --daemon") | sort -u | crontab -
elif [ "$OS" == "alpine" ]; then
    echo "Menggunakan cronie di Alpine Linux..."

    # Pastikan cronie terinstal
    if ! command -v crond &> /dev/null; then
        apk add cronie
    fi

    # Aktifkan cronie saat boot
    rc-update add crond
    rc-service crond start

    # Tambahkan crontab khusus Alpine
    (crontab -l 2>/dev/null; echo "0 0 * * * /root/ooklaserver.sh restart") | sort -u | crontab -
fi

# Jika menggunakan Alpine OS, buat service untuk OpenRC
if [ "$OS" == "alpine" ]; then
    echo "Menyiapkan service untuk OpenRC..."
    cat <<EOF > /etc/init.d/ooklaserver
#!/sbin/openrc-run

name="OoklaServer"
description="Ookla Speedtest Server"
command="/root/OoklaServer"
command_args="--daemon"
pidfile="/var/run/ooklaserver.pid"

depend() {
    need net
}
EOF

    chmod +x /etc/init.d/ooklaserver
    rc-update add ooklaserver default
    rc-service ooklaserver start
fi

# Memeriksa apakah OoklaServer berjalan
echo "Memeriksa status OoklaServer..."
if pgrep -x "OoklaServer" > /dev/null; then
    echo "OoklaServer berjalan."

    # Memeriksa akses dari IP publik di port 8080
    public_ip=$(curl -4 -s https://api64.ipify.org)
    if [ -n "$public_ip" ] && curl -4 -s "http://$public_ip:8080" | grep -q "<title>OoklaServer</title>"; then
        echo "OoklaServer dapat diakses di $public_ip:8080."
    else
        echo "OoklaServer tidak dapat diakses. Periksa konfigurasi jaringan."
    fi
else
    echo "OoklaServer tidak berjalan. Periksa konfigurasi!"
    exit 1
fi

# Restart OoklaServer dan konfirmasi instalasi
/root/ooklaserver.sh restart

# Pantun ala Installer 😆
echo "Pulang ke desa jalannya mulus."
sleep 1
echo "Di perjalanan ban mobil bocor halus."
sleep 1
echo "Agar silaturahmi tidak terputus."
sleep 1
echo "Pinjam dulu lah seratus. :D"
sleep 1

echo "Instalasi OoklaServer selesai!"
echo "Jangan lupa Follow, Like, and Share!"
