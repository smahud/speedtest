#!/bin/sh
##################
# OoklaServer install and management script
# (C) 2024 Ookla
##################
# Last Update 2024-01-30

BASE_DOWNLOAD_PATH="https://install.speedtest.net/ooklaserver/stable/"
DAEMON_FILE="OoklaServer"
INSTALL_DIR=''
PID_FILE="$DAEMON_FILE.pid"

display_usage() {
	echo "OoklaServer installation and Management Script"
	echo "Usage:"
	echo "$0 [-f|--force] [-i|--installdir <dir>] command"
	echo ""
	echo "  Valid commands: install, start, stop, restart"
	echo "   install - downloads and installs OoklaServer"
	echo "   start   - starts OoklaServer if not running"
	echo "   stop    - stops OoklaServer if running"
	echo "   restart - stops OoklaServer if running, and restarts it"
	echo " "
	echo "  -i|--install <dir>   Install to specified folder instead of the current folder"
	echo "  -h|--help            This help"
	echo ""
}

has_command() {
	type "$1" >/dev/null 2>&1
}

detect_platform() {
	case $(uname -s) in
	Darwin)
		server_package='macosx'
		;;
	Linux)
		server_package='linux-aarch64-static-musl'
		arch=$(uname -m)
		if [ "$arch" = "x86_64" ]; then
			server_package='linux-x86_64-static-musl'
		fi
		;;
	FreeBSD)
		server_package='freebsd13_64'
		;;
	*)
		echo "Unsupported platform"
		exit 1
	esac

	echo "Server Platform is $server_package"
}

goto_speedtest_folder() {
	dir_full=$(pwd)
	dir_base=$(basename "$dir_full")

	if [ "$INSTALL_DIR" != "" ]; then
		if [ "$dir_base" != "$INSTALL_DIR" ]; then
			if [ ! -d "$INSTALL_DIR" ]; then
				mkdir "$INSTALL_DIR"
				scriptname=$(basename "$0")
				cp "$scriptname" "$INSTALL_DIR"
			fi

			cd "$INSTALL_DIR" || exit
		fi
	fi
}

download_install() {
	gzip_download_file="OoklaServer-$server_package.tgz"
	gzip_download_url="$BASE_DOWNLOAD_PATH$gzip_download_file"

	curl_path=$(command -v curl)
	wget_path=$(command -v wget)
	fetch_path=$(command -v fetch)

	echo "Downloading Server Files"
	if [ -n "$curl_path" ]; then
		curl -O "$gzip_download_url"
	elif [ -n "$wget_path" ]; then
		wget "$gzip_download_url" -O "$gzip_download_file"
	elif [ -n "$fetch_path" ]; then
		fetch -o "$gzip_download_file" "$gzip_download_url"
	else
		echo "This script requires CURL, WGET, or FETCH"
		exit 1
	fi

	if [ -f "$gzip_download_file" ]; then
		echo "Extracting Server Files"
		tar -zxovf "$gzip_download_file"
		rm "$gzip_download_file"
		if [ ! -f "${DAEMON_FILE}.properties" ]; then
			cp "${DAEMON_FILE}.properties.default" "${DAEMON_FILE}.properties"
		fi
	else
		echo "Error downloading server package"
		exit 1
	fi
}

restart_if_running() {
	stop_if_running
	start
}

stop_process() {
	daemon_pid="$1"
	printf "Stopping $DAEMON_FILE Daemon ($daemon_pid)"
	kill "$daemon_pid" >/dev/null 2>&1
	for _ in $(seq 1 20); do
		if kill -0 "$daemon_pid" >/dev/null 2>&1; then
			sleep 1
			printf "."
		else
			break
		fi
	done
	echo ""
}

stop_if_running() {
	if [ -f "$PID_FILE" ]; then
		daemon_pid=$(cat "$PID_FILE")
		if [ "$daemon_pid" ]; then
			stop_process "$daemon_pid"
			if has_command pgrep; then
				pids=$(pgrep OoklaServer 2>&1)
				if [ -n "$pids" ]; then
					echo "Stopping additional $DAEMON_FILE processes"
					kill -9 $pids
				fi
			fi
		fi
	fi
}

start_if_not_running() {
	if [ -f "$PID_FILE" ]; then
		daemon_pid=$(cat "$PID_FILE")
		if [ "$daemon_pid" ]; then
			if kill -0 "$daemon_pid" >/dev/null 2>&1; then
				echo "$DAEMON_FILE ($daemon_pid) is already running"
				exit 1
			fi
		fi
	fi
	start
}

start() {
	printf "Starting $DAEMON_FILE"
	dir_full=$(pwd)
	if [ -f "$DAEMON_FILE" ]; then
		chmod +x "$DAEMON_FILE"
		daemon_cmd="./$DAEMON_FILE --daemon --pidfile=$dir_full/$PID_FILE"
		$daemon_cmd
	else
		echo ""
		echo "Daemon not installed. Please run install first."
		exit 1
	fi

	for _ in $(seq 1 10); do
		sleep 1
		[ -f "$PID_FILE" ] && break
		printf "."
	done
	echo ""
	[ -f "$PID_FILE" ] && echo "Daemon Started ($(cat $PID_FILE))" || echo "Failed to Start Daemon"
}

##### Main

action=help
while [ "$1" != "" ]; do
	case $1 in
	install) action=install ;;
	stop) action=stop ;;
	start) action=start ;;
	restart) action=restart ;;
	help) action=help ;;
	-i | --installdir) shift; INSTALL_DIR=$1 ;;
	-h | --help) display_usage; exit ;;
	*) display_usage; exit 1 ;;
	esac
	shift
done

case $action in
	install)
		detect_platform
		goto_speedtest_folder
		download_install
		restart_if_running
		;;
	start) start_if_not_running ;;
	stop) stop_if_running ;;
	restart) restart_if_running ;;
	help) display_usage ;;
esac
