# Bagian V
# Memeriksa apakah layanan OoklaServer sedang berjalan
source /root/speedtest/common_functions1.sh
source /root/data.ini

echo "Menghentikan semua service OoklaServer"
echo "#Percobaan 1 - Menggunakan file instalasi#"
if pgrep -x "OoklaServer" > /dev/null; then
    echo "OoklaServer sedang berjalan. Menghentikan OoklaServer..."
    ./ooklaserver.sh stop
else
    echo "OoklaServer sudah berhenti. Melanjutkan dengan skrip..."
    sleep 2

    if pgrep -x "OoklaServer" > /dev/null; then
		echo "#Percobaan 2 - Menggunakan pkill -f#"
        echo "OoklaServer sedang berjalan. Menghentikan OoklaServer..."
         pkill -f "OoklaServer"
    else
        echo "OoklaServer sudah berhenti. Melanjutkan dengan skrip..."
        sleep 2

        if pgrep -x "OoklaServer" > /dev/null; then
			echo "Percobaan 3 - Menggunakan kill -9"
            echo "OoklaServer sedang berjalan. Menghentikan OoklaServer..."
             pkill -9 -f "OoklaServer"
        else
            echo "OoklaServer sudah berhenti. Melanjutkan dengan skrip..."
            sleep 2
        fi
    fi
fi


# Ganti domain dalam OoklaServer.properties
 sed -i 's|openSSL.server.certificateFile = /etc/letsencrypt/live/[^/]\+/fullchain.pem||' /root/OoklaServer.properties
 sed -i 's|openSSL.server.privateKeyFile = /etc/letsencrypt/live/[^/]\+/privkey.pem||' /root/OoklaServer.properties
sed -i '/OoklaServer.ssl.useLetsEncrypt = true/d' OoklaServer.properties


# Tambahkan baris Certificate baru ke dalam file OoklaServer.properties
echo "openSSL.server.certificateFile = /etc/letsencrypt/live/$Domain/fullchain.pem" |  tee -a /root/OoklaServer.properties > /dev/null
echo "openSSL.server.privateKeyFile = /etc/letsencrypt/live/$Domain/privkey.pem" |  tee -a /root/OoklaServer.properties > /dev/null
echo "File OoklaServer.properties sudah ter update."

###################################################################

	# Memeriksa file OoklaServer
	echo "Malakukan Update Service OoklaServer..."
	/root/ooklaserver.sh stop
	/root/ooklaserver.sh install -f
	/root/ooklaserver.sh restart
	rm OoklaServer.properties.default
	rm OoklaServer.pid
	echo "Update Service OoklaServer Berhasil Di Update dan Dijalankan kembali..."
	print_hash 30
	
###################################################################
