# Bagian II
# Memeriksa OoklaServer installation
source /root/speedtest/common_functions1.sh
if [ -e "/root/OoklaServer" ]; then
echo "OoklaServer sudah terinstal. Melewati ke Bagian II."
print_hash 30
else
echo "OoklaServer tidak ditemukan. Menjalankan Perintah Instalasi OoklaServer"
#/root/speedtest/serverinstall.sh (lawas, tidak dipakai)

echo "Membuat file OoklaServer.properties "
cat <<EOF | sudo tee /root/OoklaServer.properties > /dev/null
OoklaServer.tcpPorts = 5060,8080
OoklaServer.udpPorts = 5060,8080
OoklaServer.useIPv6 = true
OoklaServer.allowedDomains = *.ookla.com, *.speedtest.net
OoklaServer.enableAutoUpdate = true
OoklaServer.ssl.useLetsEncrypt = true
logging.loggers.app.name = Application
logging.loggers.app.channel.class = ConsoleChannel
logging.loggers.app.channel.pattern = %Y-%m-%d %H:%M:%S [%P - %I] [%p] %t
logging.loggers.app.level = information
EOF


cd 
cp /root/speedtest/ooklaserver.sh /root/ooklaserver.sh
echo "OoklaServer berhasil di install"
print_hash 30
fi
