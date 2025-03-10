# Bagian I
# Cek apakah file data.ini sudah ada
source /root/speedtest/common_functions1.sh
source /root/data.ini
echo "Melakukan input dari file data.ini"
if [ -e "/root/data.ini" ]; then
    echo "File data.ini ditemukan, melanjutkan perintah..."
	print_hash 30
else
    echo "File data.ini tidak ditemukan. Skrip dihentikan."
	print_hash 100
    exit 1
fi
# Sumberkan data.ini
mkdir -p /etc/letsencrypt
rm /etc/letsencrypt/dnscloudflare.ini
tee /etc/letsencrypt/dnscloudflare.ini > /dev/null <<END
#dns_cloudflare_email = $EmailCloudFlare
dns_cloudflare_api_token = $APICloudFlare
END
##############################################################
chmod 600 /etc/letsencrypt/dnscloudflare.ini
