#!/bin/bash

echo "== Menyiapkan dan Mengupdate CRONTAB Speedtest =="

# Ambil RegisteredSpeedtestURL dari data.ini
SPEEDTEST_DATA="/root/data.ini"
REGISTERED_URL=$(grep '^RegisteredSpeedtestURL=' "$SPEEDTEST_DATA" | cut -d'=' -f2 | tr -d '"')

CRON1="0 * * * * sleep \$(( RANDOM % 50 ))m && speedtest -o $REGISTERED_URL"
CRON2="*/5 * * * * systemd-run --scope -p CPUQuota=10% speedtest -o $REGISTERED_URL"

# Backup dan update crontab root
crontab -l 2>/dev/null | grep -v 'speedtest -o ' > /tmp/crontab.tmp

echo "$CRON1" >> /tmp/crontab.tmp
echo "$CRON2" >> /tmp/crontab.tmp

crontab /tmp/crontab.tmp
rm -f /tmp/crontab.tmp

echo "Crontab berhasil diupdate dengan RegisteredSpeedtestURL: $REGISTERED_URL"
