# Bagian II
# Memeriksa OoklaServer installation
if [ -e "/root/OoklaServer" ]; then
echo "OoklaServer sudah terinstal. Melewati ke Bagian II."
print_hash 30

else
echo "OoklaServer tidak ditemukan. Menjalankan Perintah Instalasi OoklaServer"

# Mendeteksi distribusi Linux yang digunakan
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu
    sudo apt update
    sudo apt install git -y
elif [ -f /etc/redhat-release ]; then
    # RHL/CentOS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" == "rhel" ] || [ "$ID" == "centos" ]; then
            yum update -y
			sudo yum install git -y
        fi
    fi
elif [ -f /etc/SuSE-release ]; then
    # OpenSUSE
	echo "Terdeteksi openSUSE"
    sudo zypper install git -y
else
    echo "Distribusi Linux tidak didukung atau tidak dapat dideteksi."
    exit 1
fi

git clone https://github.com/smahud/speedtest.git 
chmod a+x /root/speedtest/*.sh 
/root/speedtest/serverinstall.sh 
cd 
cp /root/speedtest/ooklaserver.sh /root/ooklaserver.sh
echo "OoklaServer berhasil di install"
echo "Melanjutkan Bagian II"
print_hash 30


fi
