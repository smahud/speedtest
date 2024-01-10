#!/bin/bash

# Bagian I
# WAJIB DI BACA DENGAN SEKSAMA
# Data awal, isi data dulu bro
# 
#
# Jika menggunakan domain wildcard, cukup isi dengan domain utama saja di kolom Domain
# Contoh example.com
#
# Jika bukan wildcard, isi nama domain atau subdomain secara lengkap di kolom Domain
# Contoh speedtest.example.com
#
# Wildcard CloudFlare wajib ambil yang API Global
# Wildcard selain CloudFlare harus update manual DNS, pehatikan perintah yang diberikan
# Selain wildcard harus open port 80
#
# Pilih Ya atau Tidak

# DATA AWAL #
ApakahDomainWildcard="Ya"
ApakahPakaiCloudflare="Ya"
Domain="j-tech.my.id"
EmailCloudFlare="jtech.network@outlook.co.id"
APICloudFlare="ed5e267bcd9af3d4b1cbb149e5778e1105f6d"
# ######### #


sudo mkdir -p /etc/letsencrypt
rm /etc/letsencrypt/dnscloudflare.ini
sudo tee /etc/letsencrypt/dnscloudflare.ini > /dev/null <<END
dns_cloudflare_email = $EmailCloudFlare
dns_cloudflare_api_key = $APICloudFlare
END
sudo chmod 0600 /etc/letsencrypt/dnscloudflare.ini

# Bagian II
# Memeriksa OoklaServer installation
if [ -e "/root/OoklaServer" ]; then
    # Script A
echo "OoklaServer sudah terinstal. Melewati ke Bagian II."
else
    # Script B
echo "OoklaServer tidak ditemukan. Menjalankan Skrip B..."

    # Menentukan jenis distribusi Linux
    if command -v zypper &> /dev/null; then
        # openSUSE
        echo "Terdeteksi openSUSE"
		sleep 5
        sudo zypper install git -y && git clone https://github.com/smahud/speedtest.git && cd /root/speedtest && chmod a+x *.sh && ./serverinstall.sh && cd && cp /root/speedtest/ooklaserver.sh /root/ooklaserver.sh
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        echo "Terdeteksi CentOS/RHEL"
		sleep 5
        yum update -y && yum install git -y && git clone https://github.com/smahud/speedtest.git && cd /root/speedtest && chmod a+x *.sh && ./serverinstall.sh && cd && cp /root/speedtest/ooklaserver.sh /root/ooklaserver.sh
    elif command -v apt &> /dev/null; then
        # Ubuntu/Debian
        echo "Terdeteksi Ubuntu/Debian"
		sleep 5
        apt update -y && apt install git -y && git clone https://github.com/smahud/speedtest.git && cd /root/speedtest && chmod a+x *.sh && ./serverinstall.sh && cd && cp /root/speedtest/ooklaserver.sh /root/ooklaserver.sh
    else
		echo "Distribusi Linux tidak didukung."
		sleep 5
        exit 1
    fi
fi



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
	sleep 10
else
    # Fungsi untuk menjalankan instalasi Certbot untuk Ubuntu/Debian
    install_certbot_ubuntu() {
        # Skrip 1
        # Digunakan pada Ubuntu 18.04 dan 20.04
        # Temukan instruksi untuk OS lain di sini: https://certbot.eff.org/instructions

        # Instal Certbot melalui Snap jika belum terinstal
        sudo apt install snapd -y
        sleep 10
        sudo snap install core; sleep 10; sudo snap refresh core
        sudo snap install --classic certbot
        sudo ln -s /snap/bin/certbot /usr/bin/certbot

        # Instal plugin DNS CloudFlare jika belum terinstal
        if ! command_exists certbot-dns-cloudflare; then
            sudo snap set certbot trust-plugin-with-root=ok
            sudo snap install certbot-dns-cloudflare
            sudo apt -y install python3-certbot-dns-cloudflare
        fi
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
        sleep 10
        sudo snap install core; sleep 10; sudo snap refresh core
        sudo snap install --classic certbot
        sudo ln -s /snap/bin/certbot /usr/bin/certbot

        # Instal plugin DNS CloudFlare jika belum terinstal
        if ! command_exists certbot-dns-cloudflare; then
            sudo snap set certbot trust-plugin-with-root=ok
            sudo snap install certbot-dns-cloudflare
            sudo yum install python3-certbot-dns-cloudflare -y
        fi
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
            exit 1
        fi
    else
        echo "Sistem operasi tidak didukung."
        exit 1
    fi
fi



# Bagian IV
# Bagian IV Script 1
if [ "$ApakahPakaiCloudflare" == "Ya" ]; then
    if [ "$ApakahDomainWildcard" == "Ya" ]; then
        # Jika Wildcard dan menggunakan Cloudflare
        if sudo certbot certificates --domain "*.$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat wildcard baru..."
            sudo certbot certonly -d "*.$Domain"  \
                --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/dnscloudflare.ini \
                --non-interactive --agree-tos \
                --email "administrator@$Domain"
        fi
    else
        # Jika bukan Wildcard dan menggunakan Cloudflare
        if sudo certbot certificates --domain "$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat baru..."
            sudo certbot certonly -d "$Domain" \
                --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/dnscloudflare.ini \
                --non-interactive --agree-tos \
                --email "administrator@$Domain"
        fi
    fi
else
    # Jika bukan Cloudflare
    if [ "$ApakahDomainWildcard" == "Ya" ]; then
        # Jika Wildcard tapi bukan Cloudflare
        if sudo certbot certificates --domain "*.$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat wildcard."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat wildcard baru..."
            sudo certbot certonly --manual --preferred-challenges=dns -d "*.$Domain" \
                --agree-tos --email "administrator@trisuladata.net.id" 
        fi
    else
        # Jika bukan Wildcard dan bukan Cloudflare
        if sudo certbot certificates --domain "$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat baru..."
            sudo certbot certonly --standalone --domain $Domain \
                --non-interactive --agree-tos --preferred-challenges http \
                --email "administrator@$Domain"
        fi
    fi
fi


# Bagian IV Script 2
# Memeriksa apakah layanan OoklaServer sedang berjalan
if pgrep -x "OoklaServer" > /dev/null; then
    echo "OoklaServer sedang berjalan. Menghentikan OoklaServer..."

    # Menjalankan script update dan restart OoklaServer
    ./ooklaserver.sh stop
    sleep 2

    # Mencoba menghentikan proses OoklaServer menggunakan sudo pkill -f
    sudo pkill -f "OoklaServer"
    sleep 2  # Tunggu 2 detik untuk memastikan bahwa OoklaServer berhenti sepenuhnya
	

    # Jika proses masih berjalan, mencoba menggunakan kill -9
    if pgrep -x "OoklaServer" > /dev/null; then
        echo "Memaksa OoklaServer berhenti menggunakan kill -9..."
        sudo pkill -9 -f "OoklaServer"
        sleep 2  # Tunggu 2 detik untuk memastikan bahwa OoklaServer berhenti sepenuhnya
    fi

    # Memeriksa kembali setelah mencoba menghentikan proses
    if pgrep -x "OoklaServer" > /dev/null; then
        echo "OoklaServer masih berjalan. Menjalankan ulang skrip dari awal..."
        exec "$0" "$@"  # Menjalankan kembali skrip dari awal
    else
        echo "OoklaServer sudah berhenti. Melanjutkan dengan skrip..."
    fi
fi





# Ganti domain dalam OoklaServer.properties
sudo sed -i 's|openSSL.server.certificateFile = /etc/letsencrypt/live/[^/]\+/fullchain.pem||' /root/OoklaServer.properties
sudo sed -i 's|openSSL.server.privateKeyFile = /etc/letsencrypt/live/[^/]\+/privkey.pem||' /root/OoklaServer.properties

# Tambahkan baris Certificate baru ke dalam file OoklaServer.properties
echo "openSSL.server.certificateFile = /etc/letsencrypt/live/$Domain/fullchain.pem" | sudo tee -a /root/OoklaServer.properties > /dev/null
echo "openSSL.server.privateKeyFile = /etc/letsencrypt/live/$Domain/privkey.pem" | sudo tee -a /root/OoklaServer.properties > /dev/null
echo "OoklaServer sudah berhenti "
echo "File OoklaServer.properties sudah ter update."
echo "Melanjutkan dengan skrip..."


###################################################################

	# Memeriksa file OoklaServer
	echo "Runing Update Service OoklaServer..."
	./ooklaserver.sh install
	echo "Service OoklaServer Berhasil Dijalankan..."
    sleep 5
	
###################################################################


# Bagian Akhir
# Membuat perintah auto reload OoklaServer setiap pukul 00:00
# Baris perintah yang ingin ditambahkan ke crontab
new_cron_line="0 0 * * * /root/OoklaServer stop && /root/OoklaServer --daemon"

# Mendapatkan isi crontab saat ini
existing_cron=$(crontab -l 2>/dev/null)

# Memeriksa apakah baris perintah sudah ada dalam crontab
if [[ ! $existing_cron =~ $new_cron_line ]]; then
    # Menambahkan baris perintah ke crontab
    (crontab -l 2>/dev/null; echo "$new_cron_line") | sort -u | crontab -
    echo "Baris perintah berhasil ditambahkan ke crontab."
else
    echo "Baris perintah sudah ada dalam crontab. Tidak ada yang ditambahkan."
fi


# Memeriksa apakah OoklaServer sedang berjalan
if pgrep -x "OoklaServer" > /dev/null; then
    echo "OoklaServer sedang berjalan."

    # Memberikan waktu untuk proses
    sleep 2

    # Memeriksa ketersediaan akses dari IP public dan port 8080...
    echo "Memeriksa ketersediaan akses dari IP public dan port 8080..."

    # Memberikan waktu untuk proses
    sleep 2

    # Mendapatkan IP public dari PC yang sedang berjalan (hanya IPv4)
    public_ip=$(curl -4 -s https://api64.ipify.org?format=text)

    # Memeriksa apakah IP public berhasil didapatkan
    if [ -n "$public_ip" ]; then
        # Melakukan curl ke IP public dan port 8080 untuk memastikan OoklaServer berjalan
        result=$(curl -4 -s "http://$public_ip:8080" || echo "Failed")

        # Memeriksa hasil curl
        if [ "$result" == "<html><head><title>OoklaServer</title></head><body><h1>OoklaServer</h1><p>It worked!<br /></p></body></html>" ]; then
            echo "OoklaServer dapat diakses melalui IP public dan port 8080."
        else
            echo "OoklaServer tidak dapat diakses melalui IP public dan port 8080. Periksa konfigurasi atau jaringan Anda."
        fi
    else
        echo "Gagal mendapatkan IP public. Periksa koneksi internet atau konfigurasi API yang digunakan."
    fi
else
    echo "OoklaServer tidak sedang berjalan."
fi


# Memeriksa apakah rc.local sudah terbentuk dan berjalan
if [ -f "/etc/rc.local" ]; then
    echo "rc.local sudah ada."
    if systemctl is-enabled rc-local | grep -iq "enabled"; then
        echo "rc.local diaktifkan dan sedang berjalan."
		echo "OoklaServer akan berjalan otomatis setelah reboot."
    else
        echo "rc.local tidak diaktifkan atau tidak sedang berjalan."
    fi
else
    echo "rc.local tidak ada."
fi
