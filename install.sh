#!/bin/bash
set -e
echo "Sedang Update System"
###################################################################################################>
# Mendeteksi distribusi Linux yang digunakan
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu
    apt update > /dev/null 2>&1 
    apt install nala -y > /dev/null 2>&1
    apt install git -y > /dev/null 2>&1
    apt install curl -y > /dev/null 2>&1
    apt install tar -y > /dev/null 2>&1
    apt install wget -y > /dev/null 2>&1
    apt install cron -y > /dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    # RHL/CentOS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" == "rhel" ] || [ "$ID" == "centos" ]; then
            yum update -y > /dev/null 2>&1
            yum install git -y > /dev/null 2>&1
            yum install curl -y > /dev/null 2>&1
            yum install tar -y > /dev/null 2>&1
            yum install wget -y  > /dev/null 2>&1
            yum install cron -y  > /dev/null 2>&1
        fi
    fi
elif [ -f /etc/SuSE-release ]; then
    # OpenSUSE
    zypper install git -y > /dev/null 2>&1
else
    echo "Distribusi Linux tidak didukung atau tidak dapat dideteksi."
    exit 1
fi
###################################################################################################>
# Melakukan operasi lainnya dari skrip install.sh
rm -rf /root/speedtest
test ! -d /root/speedtest && git clone https://github.com/smahud/speedtest.git && cd /root/speedtest && git fetch origin &&git reset --hard origin/main
chmod a+x /root/speedtest/*.sh
source /root/speedtest/common_functions1.sh
/root/speedtest/bagian0.sh
###################################################################################################>
# Fungsi untuk menjalankan setiap bagian dan memeriksa log error
run_section() {
    local section_name=$1
    echo "Masuk $section_name"
    print_hash 30
    /root/speedtest/"$section_name".sh
    print_hash 30
}

# Eksekusi setiap bagian
run_section "Bagian I - Install Dependency"
run_section "Bagian II - Install OoklaServer"
run_section "Bagian III - Install Certbot"
run_section "Bagian IV - Install Server Certificate"
run_section "Bagian V - Update OoklaServer"
run_section "Bagian VI - Melakukan Cek Konfigurasi"
