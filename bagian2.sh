# Bagian II
# Memeriksa OoklaServer installation
source common_functions1.sh
if [ -e "/root/OoklaServer" ]; then
echo "OoklaServer sudah terinstal. Melewati ke Bagian II."
print_hash 30

else
echo "OoklaServer tidak ditemukan. Menjalankan Perintah Instalasi OoklaServer"
/root/speedtest/serverinstall.sh 
cd 
cp /root/speedtest/ooklaserver.sh /root/ooklaserver.sh
echo "OoklaServer berhasil di install"
echo "Melanjutkan Bagian II"
print_hash 30


fi
