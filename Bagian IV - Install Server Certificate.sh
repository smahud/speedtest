# Bagian IV
source /root/speedtest/common_functions1.sh
source /root/data.ini
if [ "$ApakahPakaiCloudflare" == "Ya" ]; then
    if [ "$ApakahDomainWildcard" == "Ya" ]; then
        # Jika Wildcard dan menggunakan Cloudflare
        if  certbot certificates --domain "*.$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat wildcard baru..."
             certbot certonly -d "*.$Domain" -d "$Domain"  \
                --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/dnscloudflare.ini \
                -n --agree-tos \
                --email "administrator@$Domain"
        fi
    else
        # Jika bukan Wildcard dan menggunakan Cloudflare
        if  certbot certificates --domain "$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat baru..."
             certbot certonly -d "$Domain" \
                --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/dnscloudflare.ini \
                -n --agree-tos \
                --email "administrator@$Domain"
        fi
    fi
else
    # Jika bukan Cloudflare
    if [ "$ApakahDomainWildcard" == "Ya" ]; then
        # Jika Wildcard tapi bukan Cloudflare
        if  certbot certificates --domain "*.$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat wildcard."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat wildcard baru..."
             certbot certonly --manual --preferred-challenges=dns -d "*.$Domain" \
                --agree-tos --email "administrator@trisuladata.net.id" 
        fi
    else
        # Jika bukan Wildcard dan bukan Cloudflare
        if  certbot certificates --domain "$Domain" | grep -iq "Expiry Date"; then
            echo "Sertifikat sudah ada dan masih berlaku. Melewati pembuatan sertifikat."
        else
            echo "Sertifikat tidak ditemukan atau kadaluarsa. Membuat sertifikat baru..."
             certbot certonly --standalone --domain $Domain \
                -n --agree-tos --preferred-challenges http \
                --email "administrator@$Domain"
        fi
    fi
fi

# Memeriksa apakah Certificate File berhasil dibuat
FullChainPath="/etc/letsencrypt/live/$Domain/fullchain.pem"

if [ -f "$FullChainPath" ]; then
	echo "Sertifikat berhasil di buat atau sudah ada"
else
    echo "Gagal membuat sertifikat atau file Certificate yang di butuhkan tidak ditemukan. Script dihentikan."
	print_hash 100
    exit 1
fi

# Lanjutkan dengan perintah-perintah lainnya setelah berhasil membuat sertifikat
echo "BERHASIL!!!! Melanjutkan perintah berikutnya..."
print_hash 30
