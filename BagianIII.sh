# Bagian III
# Fungsi untuk memeriksa apakah suatu perintah ada
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Fungsi untuk memeriksa apakah Certbot sudah terinstal
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
        # Skrip 1
        # Digunakan pada Ubuntu 18.04 dan 20.04
        # Temukan instruksi untuk OS lain di sini: https://certbot.eff.org/instructions

        # Instal Certbot melalui Snap jika belum terinstal
        sudo apt install snapd -y
        sleep 1
        sudo snap install core
        sudo snap refresh core
        sudo snap install --classic certbot
        sudo ln -s /snap/bin/certbot /usr/bin/certbot
        sudo snap set certbot trust-plugin-with-root=ok
        sudo snap install certbot-dns-cloudflare
		sudo apt install certbot -y
        sudo apt -y install python3-certbot-dns-cloudflare

    }

    # Fungsi untuk menjalankan instalasi Certbot untuk CentOS/RHEL
    install_certbot_centos() {
        # Skrip 2
        # Digunakan pada CentOS 7 dan 8
        # Temukan instruksi untuk OS lain di sini: https://certbot.eff.org/instructions

        # Instal Certbot melalui Snap jika belum terinstal
        sudo yum install epel-release -y
        sudo yum install snapd -y
        sudo systemctl enable --now snapd.socket
        sudo ln -s /var/lib/snapd/snap /snap
        sleep 1
        sudo snap install core
        sudo snap refresh core
        sudo snap install --classic certbot
        sudo ln -s /snap/bin/certbot /usr/bin/certbot
		sudo yum install -y python2-cloudflare python2-certbot-dns-cloudflare
        sudo yum -y install python3-certbot-dns-cloudflare
        sudo snap set certbot trust-plugin-with-root=ok
		sudo yum install certbot -y
        sudo snap install certbot-dns-cloudflare
    }

    # Fungsi untuk menjalankan instalasi Certbot untuk openSUSE
    install_certbot_opensuse() {
        # Skrip 3
        # Digunakan pada openSUSE Leap 15.0 dan 15.1
        # Temukan instruksi untuk OS lain di sini: https://certbot.eff.org/instructions

        # Instal Certbot melalui Zypper jika belum terinstal
        sudo zypper install certbot

        # Instal plugin DNS CloudFlare jika belum terinstal
        if ! command_exists certbot-dns-cloudflare; then
            sudo zypper install python3-certbot-dns-cloudflare
        fi
    }

    # Tentukan OS dan jalankan fungsi yang sesuai
    if [[ "$OSTYPE" == "linux-gnu" ]]; then
        if command_exists zypper; then
            # openSUSE
            install_certbot_opensuse
        elif command_exists apt; then
            # Ubuntu/Debian
            install_certbot_ubuntu
        elif command_exists yum; then
            # CentOS/RHEL
            install_certbot_centos
        else
            echo "Distribusi Linux tidak didukung."
            print_hash 100
			exit 1
        fi
    else
        echo "Sistem operasi tidak didukung."
        print_hash 100
		exit 1
    fi
fi


echo "Masuk Bagian IV"
print_hash 30
