#!/bin/bash
# Get OS information
source /root/speedtest/common_functions1.sh
os=$(uname -s)

echo "Membuat file OoklaServer.properties "
sudo tee /root/OoklaServer.properties > /dev/null <<EOT
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
EOT

echo "Membuat file rc.local" 
tee /etc/rc.local > /dev/null <<EOT
#!/bin/sh -e
# rc.local
/root/OoklaServer --daemon
exit 0
EOT

echo "Membuat file rc-local.service"
sudo tee /etc/systemd/system/rc-local.service > /dev/null <<EOT
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local

[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
EOT

# Get OS information
os=$(uname -s)

# Check if OS is Debian/Ubuntu
if [ "$os" = "Linux" ] && [ -f "/etc/debian_version" ]; then
    # Execute Debian/Ubuntu command
chmod +x /etc/rc.local && systemctl enable rc-local.service && systemctl start rc-local.service
apt-get install curl -y
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get install speedtest
    
    # Check if all commands executed successfully
    if [ $? -eq 0 ]; then
        echo "Orang pertama yang baca ini saya kasih Rp 50.000"
	echo "082319199930"
    fi
    
	
	
# Check if OS is RHEL/CentOS
elif [ "$os" = "Linux" ] && [ -f "/etc/redhat-release" ]; then
    # Execute RHEL/CentOS command
sudo chmod +x /etc/rc.local && systemctl enable rc-local.service && systemctl start rc-local.service
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash
sudo yum install speedtest -y

    
    # Check if all commands executed successfully
    if [ $? -eq 0 ]; then
        cd
	cd
    fi
    
else
    # Unsupported OS
    echo "Unsupported OS."
fi

cd
cp /root/speedtest/ooklaserver.sh /root/ooklaserver.sh
chmod a+x ooklaserver.sh
/root/ooklaserver.sh
rm /root/OoklaServer.properties.default
