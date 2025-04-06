#!/bin/sh

# Sumber fungsi umum (pastikan file ini ada)
source /root/speedtest/common_functions1.sh

# Fungsi untuk memeriksa apakah suatu perintah ada
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

certbot_installed() {
    command_exists certbot
}

# Cek apakah Certbot sudah terinstal
if certbot_installed; then
    echo "Certbot sudah terinstal, melewati langkah instalasi."
    print_hash 30
    sleep 1
else
    # Fungsi untuk menjalankan instalasi Certbot untuk Ubuntu/Debian
    install_certbot_ubuntu() {
        apt update
        apt install -y snapd
        snap install core
        snap refresh core
        snap install --classic certbot
        ln -s /snap/bin/certbot /usr/bin/certbot
        apt install -y certbot
        snap set certbot trust-plugin-with-root=ok
        snap install certbot-dns-cloudflare
        apt install -y python3 python3-pip python3-certbot-dns-cloudflare
        #pip install cloudflare==2.3.1 --break-system-packages
        #pip install --upgrade cloudflare --break-system-packages
    }

    # Fungsi untuk menjalankan instalasi Certbot untuk CentOS/RHEL
    install_certbot_centos() {
        yum install -y epel-release
        yum install -y snapd
        systemctl enable --now snapd.socket
        ln -s /var/lib/snapd/snap /snap
        sleep 1
        snap install core
        snap refresh core
        snap install --classic certbot
        snap set certbot trust-plugin-with-root=ok
        snap install certbot-dns-cloudflare
        ln -s /snap/bin/certbot /usr/bin/certbot
        yum install -y certbot python3 python3-pip gcc libffi-devel python3-devel openssl-devel
        pip install --upgrade pip
        pip install --upgrade certbot certbot-dns-cloudflare cryptography
        firewall-cmd --zone=dmz --add-port=8080/tcp --permanent
        firewall-cmd --reload
    }

    # Fungsi untuk menjalankan instalasi Certbot untuk openSUSE
    install_certbot_opensuse() {
        zypper install -y certbot
        if ! command_exists certbot-dns-cloudflare; then
            zypper install -y python3-certbot-dns-cloudflare
        fi
    }

    # Fungsi untuk menjalankan instalasi Certbot untuk Alpine
    install_certbot_alpine() {
        apk update
        apk add certbot certbot-dns-cloudflare

    }

    # Tentukan OS dan jalankan fungsi yang sesuai
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                install_certbot_ubuntu
                ;;
            centos|rhel|fedora)
                install_certbot_centos
                ;;
            opensuse|suse)
                install_certbot_opensuse
                ;;
            alpine)
                install_certbot_alpine
                ;;
            *)
                echo "Distribusi Linux tidak didukung."
                print_hash 100
                exit 1
                ;;
        esac
    else
        echo "Sistem operasi tidak dikenali."
        print_hash 100
        exit 1
    fi
fi
