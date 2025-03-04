#!/bin/bash

# Jalankan Speedtest ke server ID dan ambil Result URL
# Sesuaikan server ID 11111 kedalam ID yang terdapat di server saat ini
result_url=$(/snap/speedtest/current/speedtest -s 11111 --accept-license --format=json | jq -r '.result.url')

# Cek apakah result URL berhasil didapatkan
if [ -n "$result_url" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Result URL: $result_url" >> /root/result.txt
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Speedtest failed or no result URL found" >> /root/result.txt
fi
