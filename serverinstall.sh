#!/bin/bash

# Get OS information
os=$(uname -s)

# Check if OS is Debian/Ubuntu
if [ "$os" = "Linux" ] && [ -f "/etc/debian_version" ]; then
    # Execute Debian/Ubuntu command
    apt update -y && apt install wget -y && apt install nano -y
	cd
wget https://install.speedtest.net/ooklaserver/stable/OoklaServer-linux64.tgz
tar -xvzf OoklaServer-linux64.tgz
chmod a+x OoklaServer
sudo tee /root/OoklaServer.properties > /dev/null <<EOT
OoklaServer.tcpPorts = 5060,8080
OoklaServer.udpPorts = 5060,8080
OoklaServer.useIPv6 = true
OoklaServer.allowedDomains = *.ookla.com, *.speedtest.net
OoklaServer.enableAutoUpdate = true
OoklaServer.ssl.useLetsEncrypt = true
# openSSL.server.certificateFile = cert.pem
# openSSL.server.privateKeyFile = key.pem
logging.loggers.app.name = Application
logging.loggers.app.channel.class = ConsoleChannel
logging.loggers.app.channel.pattern = %Y-%m-%d %H:%M:%S [%P - %I] [%p] %t
logging.loggers.app.level = information
EOT
./OoklaServer --daemon

    
# Check if OS is RHEL/CentOS
elif [ "$os" = "Linux" ] && [ -f "/etc/redhat-release" ]; then
    # Execute RHEL/CentOS command
    yum update -y && yum install wget -y && yum install nano -y
	cd
wget https://install.speedtest.net/ooklaserver/stable/OoklaServer-linux64.tgz
tar -xvzf OoklaServer-linux64.tgz
chmod a+x OoklaServer
sudo tee /root/OoklaServer.properties > /dev/null <<EOT
OoklaServer.tcpPorts = 5060,8080
OoklaServer.udpPorts = 5060,8080
OoklaServer.useIPv6 = true
OoklaServer.allowedDomains = *.ookla.com, *.speedtest.net
OoklaServer.enableAutoUpdate = true
OoklaServer.ssl.useLetsEncrypt = true
# openSSL.server.certificateFile = cert.pem
# openSSL.server.privateKeyFile = key.pem
logging.loggers.app.name = Application
logging.loggers.app.channel.class = ConsoleChannel
logging.loggers.app.channel.pattern = %Y-%m-%d %H:%M:%S [%P - %I] [%p] %t
logging.loggers.app.level = information
EOT
./OoklaServer --daemon
    
else
    # Unsupported OS
    echo "Unsupported OS."
fi


# Get OS information
os=$(uname -s)

# Check if OS is Debian/Ubuntu
if [ "$os" = "Linux" ] && [ -f "/etc/debian_version" ]; then
    # Execute Debian/Ubuntu command
	# Create file rc.local untuk Ubuntu/Debian
	tee /etc/systemd/system/rc-local.service > /dev/null <<EOT
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

tee /etc/rc.local > /dev/null <<EOT
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Ensure that the script will "exit 0" on success or any other
# value on error.
#
# To enable or disable this script, just change the execution
# bits.
#
# By default, this script does nothing.
/root/OoklaServer --daemon
exit 0
EOT

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
	# Create file rc.local untuk Centos
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

sudo tee /etc/rc.local > /dev/null <<EOT
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Ensure that the script will "exit 0" on success or any other
# value on error.
#
# To enable or disable this script, just change the execution
# bits.
#
# By default, this script does nothing.
/root/OoklaServer --daemon
exit 0
EOT

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
rm /root/OoklaServer.properties.default
