# Bagian III
# Fungsi untuk memeriksa apakah suatu perintah ada
source /root/speedtest/common_functions1.sh
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
        # Skrip 1
        # Digunakan pada Ubuntu 18.04 dan 20.04
        # Temukan instruksi untuk OS lain di sini: https://certbot.eff.org/instructions

        # Instal Certbot melalui Snap jika belum terinstal
        sudo apt install snapd -y
        sleep 1
        snap install core
        snap refresh core
        snap install --classic certbot
        ln -s /snap/bin/certbot /usr/bin/certbot
        apt install certbot -y
	snap set certbot trust-plugin-with-root=ok
        snap install certbot-dns-cloudflare
	
 	apt install python3 -y
 	apt install python3-pip -y
  	apt install python3-certbot-dns-cloudflare
	pip install --upgrade cloudflare==2.19.4
    }

    # Fungsi untuk menjalankan instalasi Certbot untuk CentOS/RHEL
    install_certbot_centos() {
        # Skrip 2
        # Digunakan pada CentOS 7 dan 8
        # Temukan instruksi untuk OS lain di sini: https://certbot.eff.org/instructions

        # Instal Certbot melalui Snap jika belum terinstal
        yum install epel-release -y
        yum install snapd -y
        systemctl enable --now snapd.socket
        ln -s /var/lib/snapd/snap /snap
        sleep 1
        snap install core
        snap refresh core
        snap install --classic certbot
	sudo snap set certbot trust-plugin-with-root=ok
	sudo snap install certbot-dns-cloudflare
        ln -s /snap/bin/certbot /usr/bin/certbot
	
	yum install certbot -y
 	yum install python3 -y
 	yum install python3-pip -y
	pip install certbot-dns-cloudflare --root-user-action=ignore

	sudo yum -y install gcc libffi-devel python3-devel openssl-devel
 	pip install --upgrade pip
  	pip install --upgrade certbot
	pip install cryptography
 
 firewall-cmd --zone=dmz --add-port=8080/tcp --permanent
 firewall-cmd --reload
 
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
	    print_hash 30
        elif command_exists apt; then
            # Ubuntu/Debian
            install_certbot_ubuntu
	    print_hash 30
        elif command_exists yum; then
            # CentOS/RHEL
            install_certbot_centos
	    print_hash 30
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
