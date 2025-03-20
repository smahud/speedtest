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
# Install Speedtest For Test
mkdir -p /root/tmp
wget -O /tmp/speedtest.tgz https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz
tar -xvzf /tmp/speedtest.tgz -C /usr/local/bin --strip-components=1 speedtest
chmod a+x /usr/local/bin/speedtest

# Sumberkan data.ini
mkdir -p /etc/letsencrypt
rm /etc/letsencrypt/dnscloudflare.ini
tee /etc/letsencrypt/dnscloudflare.ini > /dev/null <<END
#dns_cloudflare_email = $EmailCloudFlare
dns_cloudflare_api_token = $APICloudFlare
END
##############################################################
chmod 600 /etc/letsencrypt/dnscloudflare.ini
