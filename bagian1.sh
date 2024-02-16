# Cek apakah file data.ini sudah ada
source common_functions1.sh
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
sudo mkdir -p /etc/letsencrypt
rm /etc/letsencrypt/dnscloudflare.ini
sudo tee /etc/letsencrypt/dnscloudflare.ini > /dev/null <<END
dns_cloudflare_email = $EmailCloudFlare
dns_cloudflare_api_key = $APICloudFlare
END
sudo chmod 0600 /etc/letsencrypt/dnscloudflare.ini
##############################################################
