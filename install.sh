#!/bin/bash
set -e

echo "Sedang Update System"

# Mendeteksi distribusi Linux yang digunakan
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu
    echo "OS Terdeteksi Sebagai Turunan Debian/Ubuntu"
    apt update > /dev/null 2>&1 
    apt install git curl tar wget cron jq -y > /dev/null 2>&1
    echo "Sukses Install App Pendukung"
    sleep 5

elif [ -f /etc/redhat-release ]; then
    . /etc/os-release
    if [[ "$ID" == "rhel" || "$ID" == "centos" ]]; then
        echo "OS Terdeteksi Sebagai Turunan RHL/CentOS"
        yum update -y > /dev/null 2>&1
        yum install git curl tar wget cron jq -y > /dev/null 2>&1
        echo "Sukses Install App Pendukung"
        sleep 5
    fi

elif grep -qi "opensuse" /etc/os-release; then
    # OpenSUSE
    echo "OS Terdeteksi Sebagai OpenSUSE"
    zypper install git curl tar wget cron jq -y > /dev/null 2>&1
    echo "Sukses Install App Pendukung"
    sleep 5

elif grep -qi "alpine" /etc/os-release; then
    # Alpine Linux
    echo "OS Terdeteksi Sebagai Alpine Linux"
    apk update > /dev/null 2>&1
    apk add git curl tar wget cronie jq > /dev/null 2>&1
    echo "Sukses Install App Pendukung"
    sleep 5

else
    echo "Distribusi Linux tidak didukung atau tidak dapat dideteksi."
    exit 1
fi

# Melakukan operasi lainnya dari skrip install.sh
echo "Melakukan Upgrade Script"
rm -rf /root/speedtest
if git clone https://github.com/smahud/speedtest.git /root/speedtest; then
    cd /root/speedtest
    git fetch origin && git reset --hard origin/main
    echo "Sukses Update Script"
else
    echo "Gagal meng-clone repository, cek koneksi internet atau URL repo."
    sleep 5
    exit 1
fi

chmod a+x /root/speedtest/*.sh
source /root/speedtest/common_functions1.sh
/root/speedtest/bagian0.sh

# Fungsi untuk menjalankan setiap bagian dan memeriksa log error
run_section() {
    local section_file=$1
    echo "Masuk $section_file"
    print_hash 30
    if [ -f "/root/speedtest/$section_file.sh" ]; then
        /root/speedtest/"$section_file".sh
    else
        echo "File $section_file.sh tidak ditemukan, lewati bagian ini."
    fi
    print_hash 30
}

# Eksekusi setiap bagian
run_section "bagian1_install_dependency"
run_section "bagian2_install_ooklaserver"
run_section "bagian3_install_certbot"
run_section "bagian4_install_server_certificate"
run_section "bagian5_update_ooklaserver"
run_section "bagian6_cek_konfigurasi"
