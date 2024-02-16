# Bagian VI
# Membuat perintah auto reload OoklaServer setiap pukul 00:00
# Baris perintah yang ingin ditambahkan ke crontab
source /root/speedtest/common_functions1.sh
new_cron_line="0 0 * * * /root/ooklaserver.sh stop && /root/ooklaserver.sh install && /root/ooklaserver.sh start"

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
print_hash 30
echo "Memerikasa apakah OoklaServer sudah berjalan didalam system."
sleep 3
if pgrep -x "OoklaServer" > /dev/null; then
    echo "OoklaServer sedang berjalan."

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
            echo "OoklaServer dapat diakses melalui IP public $public_ip pada port 8080."
			sleep 2
        else
            echo "OoklaServer tidak dapat diakses melalui IP public dan port 8080. Periksa konfigurasi atau jaringan Anda."
			print_hash 50
        fi
    else
        echo "Gagal mendapatkan IP public. Periksa koneksi internet atau konfigurasi API yang digunakan."
		sleep 2
    fi
else
    echo "OoklaServer tidak sedang berjalan. Periksa kembali konfigurasi. Semua proses di hentikan."
	print_hash 100
	exit 1
fi


# Memeriksa apakah rc.local sudah terbentuk dan berjalan
if [ -f "/etc/rc.local" ]; then
    echo "rc.local sudah ada."
	echo "Melakukan cek status auto start"
    if systemctl is-enabled rc-local | grep -iq "enabled"; then
        echo "rc.local diaktifkan dan sedang berjalan."
		echo "OoklaServer akan berjalan otomatis ketika system reboot atau start-up."
    else
        echo "rc.local tidak diaktifkan atau tidak sedang berjalan."
    fi
else
    echo "rc.local tidak ada. Ulangi proses. Cek ulang konfigurasi"
	print_hash 100
	exit 1
fi

print_hash 50
echo "SELAMAT!!!!!!!!!!!!"
print_hash 50
echo "Proses Install OoklaServer Sudah Selesai"
print_hash 50
echo "Pulang ke desa jalannya mulus."
sleep 1
echo "Di perjalanan ban mobil bocor halus."
sleep 1
echo "Agar silaturahmi tidak terputus."
sleep 1
echo "Pinjam dulu lah seratus."
sleep 1
echo ":D"
print_hash 50
echo "Jangan Lupa Follow, Like, and Share"
print_hash 50
