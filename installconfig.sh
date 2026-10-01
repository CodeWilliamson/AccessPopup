#!/bin/bash
ver="1.01: 15th April 2026"
#Copyright Graeme Richards - RaspberryConnect.com
#Released under the GPL3 Licence (https://www.gnu.org/licenses/gpl-3.0.en.html)

#Installation and configuration script for the AccessPopup script, that switches between
#a Wifi Access Point or connects to a Wifi Network as required

osver=($(cat /etc/issue))
cpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
wdev0="wlan0"

script_path="/usr/local/bin/"
scriptname="accesspopup"
conf_path="/etc/"
conf_file="accesspopup.conf"
web_path="/usr/local/bin/ap_web"
webfile_app="/usr/local/bin/ap_web/app.py"
active_ap="n"
active=""
nw_profile=()

#service
sysd_path="/etc/systemd/system/"
service=AccessPopup.service
timer=AccessPopup.timer
webapp=ap_web_app.service
sudoers_file="/etc/sudoers.d/apu"

#Text Format
YEL='\e[38;2;255;255;0m'
GRE='\e[38;0;255;0;0m'
DEF='\e[m'
BOL='\e[1m'


nm="${osver[2]}"
if [ -z "${nm//[0-9]}" ] && [ "${osver[0]}" != 'Arch' ] ;then
	if [ "${osver[2]}" -eq 11 ]; then #OS Bullseye
		echo "OS Version" "${osver[2]}"
		echo "This script only works on PIOS 11 Bullseye if Network Manager has been enabled"
		echo "in raspi-config."
		echo "For other distributions Network Manager is required."
		read -p "Press a key to continue"
	elif [ "${osver[2]}" -lt 11 ];then #older OS
		echo "The version of PiOS is too old for the $scriptname script"
		echo "Version 11 'Bullseye' with Network Manager enabled in raspi-config is the minimum requirement"
		echo "A version for your OS is available at RaspberryConnect.com using dhcpcd instead."
		echo "www.raspberryconnect.com/projects/65-raspberrypi-hotspot-accesspoints/183-raspberry-pi-automatic-hotspot-and-static-hotspot-installer"
		read -p "Press any key to continue"
		exit 1
	fi
fi

readlink /sbin/init | grep systemd >/dev/null 2>&1
if [ "$?" -gt 0 ] ;then
	echo "systemd is not available."
	echo "This script uses SystemD services. Unable to continue."
	read -p "Press a key to continue"
	exit 1
fi


systemctl is-active --quiet NetworkManager.service
if [ $? -ne 0 ];then
	echo "NetworkManager is not available."
	echo "This script requires NetworkManager but it is not active."
	echo "Unable to continue"
	read -p "Press a key to continue"
	exit 1
fi

add_service()
{
if ! systemctl list-unit-files --all | grep $service ;then
cat > "${sysd_path}${service}" <<EOF
[Unit]
Description=Automatically generates an Access Point when a valid SSID is not in range
After=multi-user.target
Requires=network-online.target
[Service]
Type=simple
ExecStart=${script_path}${scriptname}
[Install]
WantedBy=multi-user.target
EOF
systemctl unmask $service
fi
}

add_timer_service()
{
if ! systemctl list-unit-files --all | grep $timer ;then
cat > "${sysd_path}${timer}" <<EOF
[Unit]
Description=${scriptname} network checks every 2 mins

[Timer]
OnBootSec=0min
OnCalendar=*:0/2

[Install]
WantedBy=timers.target
EOF
systemctl unmask $timer
systemctl enable $timer >/dev/null 2>&1
systemctl daemon-reload
fi
}

add_web_app_service()
{
if ! systemctl list-unit-files --all | grep $webapp ;then
	cat > "${sysd_path}${webapp}" <<EOF
[Unit]
Description=HammerTime Wi-Fi Provisioning Portal
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
User=apu
Group=apu
WorkingDirectory=/usr/local/bin/ap_web
Environment=WIFI_INTERFACE=wlan0
Environment=AP_CONNECTION=HammerTime AP
Environment=WIFI_CONNECT_TIMEOUT=25
Environment=PORTAL_HOST=0.0.0.0
Environment=PORTAL_PORT=8080
ExecStart=/usr/local/bin/ap_web/venv/bin/python /usr/local/bin/ap_web/app.py
Restart=on-failure
RestartSec=5

# nmcli needs root privileges for connection provisioning.
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
fi
}


webcheck()
{
if [ ! -f "$script_path$scriptname" ]; then
	echo "The Accesspopup script is not installed. Please install AccessPopup (Option 1) and then try again."
	echo "Press enter to continue"
	read x
	menu
fi
 echo "Web Interface Setup"
 #does systemctl acpu_web_app exist - no - install websetup
if ! systemctl list-unit-files --all | grep "$webapp" || [ ! -d "$web_path" ] >/dev/null 2>&1; then
	echo "The Web Interface not currently Installed, Installing files"
	install_web
elif systemctl -all list-unit-files "$webapp" | grep "$webapp enabled" >/dev/null 2>&1;then
	echo "Disabling the Web Interface"
	disable_web
	echo "The Web app has been disabled"
	read -p "press any key to continue"
else
	echo "Enabling the Web Interface"
	enable_web
	echo "The Web app has been enabled"
	read -p "press any key to continue"
fi
}

#Sets rel_tag and rel_url from the latest GitHub release
release_info()
{
	local api="https://api.github.com/repos/CodeWilliamson/AccessPopup/releases/latest"
	local tarball_prefix="https://api.github.com/repos/CodeWilliamson/AccessPopup/tarball/"
	local json f
	rel_tag=""; rel_url=""

	for f in curl tar python3; do
		command -v "$f" >/dev/null 2>&1 || { echo "$f is required to fetch a release but is not installed."; return 1; }
	done
	echo "Checking for the latest release..."
	json="$(curl -fsSL --max-time 30 -H 'Accept: application/vnd.github+json' "$api")" || {
		echo "Unable to get the latest release from GitHub."
		echo "Check the internet connection and that a release has been published."
		return 1
	}
	rel_tag="$(printf '%s' "$json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
	rel_url="$(printf '%s' "$json" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tarball_url",""))' 2>/dev/null)"
	if [[ ! "$rel_tag" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$rel_url" != "$tarball_prefix"* ]]; then
		echo "The GitHub response did not contain a valid release."
		return 1
	fi
}

#Extracts the release from release_info to $rel_tmp/src. The caller must rm -rf "$rel_tmp"
release_download()
{
	local f bad=""
	rel_tmp="$(mktemp -d)" || { rel_tmp=""; echo "Unable to create a temporary directory"; return 1; }
	mkdir "$rel_tmp/src"
	echo "Downloading $rel_tag..."
	if ! curl -fsSL --max-time 120 -o "$rel_tmp/release.tar.gz" "$rel_url" || ! tar -xzf "$rel_tmp/release.tar.gz" -C "$rel_tmp/src" --strip-components=1; then
		bad="The download failed."
	else
		for f in installconfig.sh accesspopup ap_web/app.py ap_web/requirements.txt; do
			[ -f "$rel_tmp/src/$f" ] || bad="The release is missing $f."
		done
	fi
	if [ -n "$bad" ]; then
		echo "$bad"
		rm -rf "$rel_tmp"; rel_tmp=""
		return 1
	fi
}

#Copies the web app files from $1 into $web_path and refreshes the venv
deploy_web()
{
	local was_active=0 rc=0
	systemctl is-active --quiet "$webapp" && was_active=1
	#Overlay copy keeps the existing venv and uploaded logo files
	mkdir -p "$web_path" && cp -rf "$1/." "$web_path" \
	&& { [ -x "$web_path/venv/bin/pip" ] || python3 -m venv "$web_path/venv"; } \
	&& "$web_path/venv/bin/pip" install -r "$web_path/requirements.txt" \
	&& "$web_path/venv/bin/pip" check \
	&& chmod 755 "$web_path/app.py" || rc=1
	if [ $was_active -eq 1 ]; then
		echo "Restarting the web app service"
		systemctl restart "$webapp"
	fi
	return $rc
}

web_setup()
{
	local pm="$(packageman)" src i rc=0
	local depend=("python3-venv" "python3-pip")
	rel_tmp=""

	if [ ! -f "$script_path$scriptname" ]; then
		echo "The Accesspopup script is not installed. Please install AccessPopup (Option 1) and then try again."
		return 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "Python3 is required for the web page feature but it is unavailable"
		return 1
	fi
	if [ "$pm" = 'apt' ]; then
		for i in "${depend[@]}"; do
			dpkg -s "$i" >/dev/null 2>&1 || apt install "$i" || {
				echo "Unable to install dependency $i"
				echo "This may be because there is no internet access or the package is unavailable"
				return 1
			}
		done
	fi

	if release_info && release_download; then
		src="$rel_tmp/src/ap_web"
	else
		echo "Using the local web app files in ${cpath}ap_web"
		src="${cpath}ap_web"
	fi
	if [ -f "$src/app.py" ] && deploy_web "$src" && add_permissions; then
		add_web_app_service
		systemctl daemon-reload
		systemctl enable --now "$webapp"
	else
		echo "Unable to complete the web setup. Removing any installed files."
		uninstall_web
		rc=1
	fi
	[ -n "$rel_tmp" ] && rm -rf "$rel_tmp"
	return $rc
}

install_web()
{
	if web_setup; then
		config_web
		echo ""
		echo -e $YEL"The web app has been installed."
		echo "In a web browser use http://localhost:8080 on this device or"
		echo -e "from another device use the http://ip_address:8080 or the http://hostname:8080"
		echo -e "From devices connected to the Access Point use http://192.168.50.1:8080" $DEF
	fi
	read -p "Press any key to continue"
}

disable_web()
{
#check if services are running, and disable them
if systemctl -all list-unit-files "$webapp" | grep "${webapp} enabled" >/dev/null 2>&1 ;then
	echo "The Web App is currently enabled, stopping and disabling Web Services"
	systemctl stop "$webapp" >/dev/null 2>&1
	systemctl disable "$webapp" >/dev/null 2>&1
	systemctl daemon-reload >/dev/null 2>&1

fi
}

enable_web()
{
#enable web services if they exist
w="$(systemctl -all list-unit-files "$webapp")"
if [ $? -gt 0 ] ;then #not installed
	echo "Web files do not exist. The Web app will be installed."
	install_web
elif systemctl -all list-unit-files "$webapp" | grep "${webapp} disabled" >/dev/null 2>&1 ;then
	echo "Enabeling AccessPopup Web app"
	systemctl enable "$webapp" >/dev/null 2>&1
	systemctl start "$webapp" >/dev/null 2>&1
fi
}

#Function what is the current active wifi
active_wifi()
{
	act="$(nmcli -t -f TYPE,NAME,DEVICE,TYPE con show --active | grep "$wdev0")" #List of active devices
	act="$(awk 1 ORS=':' <(echo "$act"))" #Replaces LF with : Delimeter
	readarray -d ':' -t active_name < <(printf "%s" "$act") #Change to array output
	if [ ! -z "$active_name" ]; then
		active="${active_name[1]}"
	else
		active=""
	fi
}

is_active_ap()
{
active_ap="n"
if [ ! -z "$active" ] ; then
	mode="$(nmcli con show "$active" | grep 'wireless.mode')"
	readarray -d ':' -t mode < <(printf "%s" "$mode")
	if [ ! -z mode ]; then
		mode2="$(echo "${mode[1]}" | sed 's/[[:blank:]]//g')"
		if [ "$mode2" = "ap" ]; then
			active_ap="y"
		fi
	fi
fi
}

switch()
{
	active_wifi
	is_active_ap
	if [ "$active_ap" = "y" ]; then #Yes active profile is an AP
		echo "Attempting to switch to WiFi Network"
		"${script_path}${scriptname}"
	else
		echo "Switching to AP"
		"${script_path}${scriptname}" "-a"
	fi
}

packageman()
{
if command -v "apt" >/dev/null 2>&1; then
	echo "apt"
elif command -v "dnf" >/dev/null 2>&1; then
	echo "dnf"
elif command -v "pacman" >/dev/null 2>&1; then
	echo "pacman"
else
	return 1
fi
}

install_general()
{
local pm="$(packageman)"
local depend1=("iw" "dnsmasq-base") #Debian
local depend2=("iw" "dnsmasq") #Fedora, Arch
local hostapd_avail=0

if [ -f "./$scriptname" ]; then
	#Debian
	if [ "$pm" = 'apt' ];then
		for i in "${depend1[@]}"; do
			dpkg -s "$i" >/dev/null 2>&1
			if [ $? -gt 0 ]; then
				apt install "$i"
				if [ $? -gt 0 ] ;then
					echo "Unable to install dependency ${depend1[@]}"
					echo "AccessPopup cannot be installed."
					echo "This may be because there is no internet access or the package is unavailable"
					echo "press enter to continue"
					read xit
					menu
				fi
			fi
		done
		dpkg -s hostapd >/dev/null 2>&1
		if [ $? -eq 0 ];then
			hostapd_avail=1
		fi

	fi
	#Fedora
	if [ "$pm" = 'dnf' ];then
		for i in "${depend2[@]}"; do
			if [ $? -gt 0 ]; then
				dnf install "$i"
				if [ $? -gt 0 ] ;then
					echo "Unable to install dependency ${depend2[@]}"
					echo "AccessPopup cannot be installed."
					echo " This may be because there is no internet access or the package is unavailable"
					echo "press enter to continue"
					read xit
					menu
				fi
			fi
		done
		rpm -qi hostapd >/dev/null 2>&1
		if [ $? -eq 0 ];then
			hostapd_avail=1
		fi

	fi
	#Arch
	if [ "$pm" = 'pacman' ];then
		for i in "${depend2[@]}" ; do
			pacman -Qi "$i" >/dev/null 2>&1
			if [ $? -gt 0 ]; then
				pacman -S "$i"
				if [ $? -gt 0 ] ;then
					echo "Unable to install dependency ${depend2[@]}"
					echo "AccessPopup cannot be installed."
					echo " This may be because there is no internet access or the package is unavailable"
					echo "press enter to continue"
					read xit
					menu
				fi
			fi
		done
		pacman -Qi hostapd >/dev/null 2>&1
		if [ $? -eq 0 ];then
			hostapd_avail=1
		fi

	fi
	systemctl is-enabled dnsmasq >/dev/null 2>&1
	if [ $? -eq 0 ] ;then
		echo "dnsmasq is enabled at start up. It will be disabled."
		systemctl disable dnsmasq >/dev/null 2>&1
		systemctl stop dnsmasq >/dev/null 2>&1
	fi

	if [ "$hostapd_avail" -eq 1 ] ;then
		systemctl is-enabled hostapd >/dev/null 2>&1
		if [ $? -eq 0 ] ;then
			echo "Hostapd is installed and enabled."
			echo "Hostapd is not required and will conflict with a NetworkManager accesspoint"
			echo "Please disable or uninstall hostapd if it is not required and try again"
			echo "To disable hostapd use: sudo systemctl disable hostapd"
			exit 1
		else
			echo "Hostapd is installed but not enabled at start up"
			echo "Hostapd is not required and will conflict with a NetworkManager Access Point"
			echo "If there is any issues connecting with the AccessPoint used in AccessPopup then"
			echo "please uninstall hostapd"
			read -p "Press a key to continue"
		fi
	fi

	if [ $wdev0 != "wlan0" ] ;then
		echo "Updating $conf_file with device name $wdev0"
		sed -i "s/wdev0=.*/wdev0='$wdev0'/" "./$conf_file"
	fi


	cp "./$scriptname" "$script_path"
	cp "./$conf_file" "${conf_path}${conf_file}"
	chmod +x "${script_path}${scriptname}"
	#Install the web app before the network script runs, as it may take the device offline
	install_web
	add_service
	add_timer_service
	systemctl start $timer
	"${script_path}${scriptname}"
	chmod +x ./nw_setup_offline.sh
	echo -e "\nAccessPopup has been installed"
	read -p "Press any key to continue"
else
	echo "$scriptname is not in the same location as this installer"
	echo "Unable to continue"
	read -p "press any key to continue"
	menu
fi

}

ap_ssid_change()
{
	if [ -f "${conf_path}${conf_file}" ] >/dev/null 2>&1; then
		echo -e "The current ssid and password for the AP are:"
		ss="$( grep -F 'ap_ssid=' $conf_path$conf_file )"
		echo "SSID:${ss:8}"
		pw="$( grep -F 'ap_pw=' ${conf_path}${conf_file} )"
		echo "Password:${pw:6}"
		prof="$( grep -F 'ap_profile_name=' ${script_path}${scriptname} )"
		echo -e $YEL"Enter the new SSID"$DEF
		echo "Press enter to keep the existing SSID"
		read newss
		if [ ! -z "$newss" ]; then
			sed -i "s/ap_ssid=.*/ap_ssid='$newss'/" "${conf_path}${conf_file}"
		fi
		echo -e $YEL"Enter the new Password"$DEF
		echo "The password must be at least 8 characters"
		echo "Press enter to keep the existing Password"
		read newpw
		if [ ! -z "Snewpw" ] && [ ${#newpw} -ge 8 ]; then
			sed -i "s/ap_pw=.*/ap_pw='$newpw'/" "${conf_path}${conf_file}"
		fi
		echo "The Access Points SSID and Password are:"
		ss="$( grep -F 'ap_ssid=' ${conf_path}${conf_file} )"
		pw="$( grep -F 'ap_pw=' ${conf_path}${conf_file} )"
		echo "SSID:${ss:8}"
		echo "Password: ${pw:6}"
		#remove AP profile
		pro="$(nmcli -t -f NAME con show | grep ${prof:17:-1} )"
		if [ ! -z "$pro" ]; then
			nmcli con delete "$pro" >/dev/null 2>&1
			nmcli con reload
		fi
		read -p "press any key to continue"
	else
		echo "$conf_file is not available."
		echo "Please install the AccessPopup script first"
		read -p "press any key to continue"
		menu
	fi
}

ap_change_ip()
{
	#IP network address
	if [ -f "${conf_path}${conf_file}" ] >/dev/null 2>&1; then
		echo "The current AccessPopup IP address is:"
		ip="$( grep -F 'ap_ip=' ${conf_path}${conf_file} )"
		echo -e $YEL"${ip:7:-1}"$DEF
		r="0"
		until [[ "$r" -eq 3 ]]; do
			echo -e "\nChoose the IP Network. The first two parts of the IP address"
			echo "1) 192.168."
			echo "2) 10.0."
			echo "3) Exit"
			read r
			if [ ! -z "$r" ]; then
				case $r in
					1)
						ipnw="192.168."
						r=3
						;;
					2)
						ipnw="10.0."
						r=3
						;;
					3)
						ipnw="0" ; clear; menu ;;
					*)
						echo -e $BOL$YEL"\nInvalid option"$DEF
						;;
					esac
				fi
			done
		#IP host 1 values
		if [[ ! $ipnw = "0" ]]; then
			r2=0
			until [ "$r2" -eq 1 ]; do
				echo -e "\n${BOL}Enter the first host number $ipnw###${DEF}"
				echo "Valid numbers are between 0 and 255"
				echo -e "The number must not match the third position of other networks connected to your"
				echo "device starting with $ipnw, such as an Ethernet ip or second wifi network ip"
				echo "Enter 999 to Cancel"
				read iph1
				if [[ $iph1 =~ ^[0-9]+$ ]]; then
					if [ $iph1 = 999 ]; then
						iph1=""
						r2=1
					elif [ $iph1 -lt 0 ] || [ $iph1 -gt 255 ]; then
						echo -e ${BOL}"\nNot a valid number\n"${DEF}
						r2=0
					else
						#Valid entry, next menu
						r2=1
					fi
				else
					r2=0
				fi
			done
		fi
		#IP host 2 values
		if [ ! -z $ipnw ] && [ ! -z $iph1 ]; then
			r3=0
			until [ "$r3" -eq 1 ]; do
				echo -e ${BOL}"\nEnter the second host number $ipnw$iph1.###"${DEF}
				echo "Valid numbers are between 0 and 253"
				echo "Enter 999 to Cancel"
				read iph2
				if [[ $iph2 =~ ^[0-9]+$ ]]; then
					if [ $iph2 -eq 999 ]; then
						iph2=""
						r3=1
					elif [ $iph2 -lt 0 ] || [ $iph2 -gt 253 ]; then
						echo -e ${BOL}"\nNot a valid number\n"${DEF}
						r3=0
					else
						#Valid entry, next menu
						r3=1
					fi
				else
					r3=0
				fi
			done
		fi
		if [ ! -z "$r3" ];then
			echo -e ${BOL}"\nUpdating the Access Point to IP address to:"${DEF}
			ipa="$ipnw$iph1.$iph2"
			ipg="$ipnw$iph1.254"
			echo -e ${YEL}$ipa${DEF}
			sed -i "s/ap_ip=.*/ap_ip='$ipa\\/24'/" "${conf_path}${conf_file}"
			sed -i "s/ap_gate=.*/ap_gate='$ipg'/" "${conf_path}${conf_file}"

			prof="$( grep -F 'ap_profile_name=' ${script_path}${scriptname} )"
			pro="$(nmcli -t -f NAME con show | grep ${prof:17:-1} )"
			if [ ! -z "$pro" ]; then
				nmcli con delete "$pro" >/dev/null 2>&1
			fi
			echo -e "\ncomplete"
			read -p "press any key to continue"
		fi
	else
		echo "$conf_file is not available."
		echo "Please install the AccessPopup script first. Option 1"
		read -p "press any key to continue"
		menu
	fi
}


saved_profiles()
{
ap_profile=()
nw_profile=()
n="$(nmcli -t -f TYPE,NAME,ACTIVE con show)" #Capture Output
n="$(awk 1 ORS=':' <(echo "$n"))" #Replaces LF with : Delimeter
readarray -d ':' -t profiles < <(printf "%s" "$n") #Change to array output
if [ ! -z profiles ]; then
	for (( c=0; c<=${#profiles[@]}; c+=3 )) #array of profiles
	do
		if [ ! -z "${profiles[$c+1]}" ] ; then
			mode="$(nmcli con show "${profiles[$c+1]}" | grep 'wireless.mode')" #show mode infrastructure, AP
			readarray -d ':' -t mode < <(printf "%s" "$mode")
			mode2="$(echo "${mode[1]}" | sed 's/[[:blank:]]//g')"
			if [ "$mode2" = "infrastructure" ]; then
				nw_profile+=("${profiles[$c+1]}")
			fi
		fi
	done
fi
}

reactivate()
{
	if [ ! -f "$script_path$scriptname" ]; then
		echo "The Accesspopup script is not installed. Please install AccessPopup (Option 1) and then try again."
		echo "Press enter to continue"
		read x
		menu
	fi
	echo -e $YEL$BOL"Wifi re-activation options"$DEF
	echo "When this device has it's wifi disabled, AccessPopup will re-activate it"
	echo "and then connect to a wifi network or generate an Access Point"
	echo "This will happen every 2 minutes."
	echo "If Wifi enable/disable is managed elsewhere on the system"
	echo "then wifi re-activation can be disabled in AccessPopup."
	re="$( grep -F 're_enable_wifi=' $conf_path$conf_file )"
	echo ""
	echo -e $BOL"Current Status: $re"$DEF
	echo ""
	echo -e "Enter $YEL n $DEF to disable wifi reactivation and $YEL y $DEF to enable re-activation"
	echo "press enter to keep the current setting"
	read r
	if [ ! -z "$r" ]; then
		if [ $r = 'y' ]; then
			sed -i "s/re_enable_wifi=.*/re_enable_wifi='y'/" "${conf_path}${conf_file}"
		elif [ $r = 'n' ]; then
			sed -i "s/re_enable_wifi=.*/re_enable_wifi='n'/" "${conf_path}${conf_file}"
		fi
	fi
	re="$( grep -F 're_enable_wifi=' ${conf_path}${conf_file} )"
	echo "The status is set to: $re"
	read -p "press a key to continue"
}

setupssid()
{
	echo -e $YEL$BOL"Add or Edit a Wifi Network"$DEF
	echo "Add a new WiFi network or change the password for an existing one that is in range"
	echo "The nearby WiFi networks will be shown below shortly:"
	ct=0; j=0 ; lp=0
	wfselect=()

	until [ $lp -eq 1 ] #wait for wifi if busy, usb wifi is slower.
	do
		IFS=$'\n:$\t' localwifi=($((iw dev $wdev0 scan ap-force | grep -E "SSID:") 2>&1)) >/dev/null 2>&1
		#if wifi device errors recheck
		if (($j >= 5)); then #if busy 5 times exit to menu
			echo "WiFi Device Unavailable, cannot scan for wifi devices at this time"
			j=99
			read -p "press a key to continue"
			break
		elif echo "${localwifi[1]}" | grep "No such device (-19)" >/dev/null 2>&1; then
			echo "No Device found,trying again"
			j=$((j + 1))
			sleep 2
		elif echo "${localwifi[1]}" | grep "Network is down (-100)" >/dev/null 2>&1 ; then
			echo "Network Not available, trying again"
			j=$((j + 1))
			sleep 2
		elif echo "${localwifi[1]}" | grep "Read-only file system (-30)" >/dev/null 2>&1 ; then
			echo "Temporary Read only file system, trying again"
			j=$((j + 1))
			sleep 2
		elif echo "${localwifi[1]}" | grep "Invalid exchange (-52)" >/dev/null 2>&1 ; then
			echo "Temporary unavailable, trying again"
			j=$((j + 1))
			sleep 2
		elif echo "${localwifi[1]}" | grep "temporarily unavailable (-11)" >/dev/null 2>&1 ; then
			echo "Temporary unavailable, trying again"
			j=$((j + 1))
			sleep 2
		elif echo "${localwifi[1]}" | grep "not supported (-95)" >/dev/null 2>&1 ; then
			ap_no_scan_options
			j=99
		elif echo "${localwifi[1]}" | grep -v "Device or resource busy (-16)"  >/dev/null 2>&1 ; then
			lp=1
		else #see if device not busy in 2 seconds
			echo "WiFi Device unavailable checking again"
			j=$((j + 1))
			sleep 2
		fi
	done
	if [ $j -eq 99 ]; then
		menu
	fi
	#Wifi Connections found - continue
	for x in "${localwifi[@]}"
	do
		if [ $x != "SSID" ]; then #list available local wifi networks
			if [ -n ${x/ /} ];then
				if [[ -n ${x/ /} ]] && [[ ! ${x/ /} =~ "x00" ]] ;then #remove hidden ssids
					ct=$((ct + 1))
					echo "$ct  ${x/ /}"
					wfselect+=("${x/ /}")
				fi
			fi
		fi
	done
	ct=$((ct + 1))
	echo  "$ct To Cancel"
	wfselect+=("Cancel")
	if [ "${#wfselect[@]}" -eq 1 ] ;then
		echo "Unable to detect local WiFi Networks. Maybe there is a temporary issue with the WiFi"
		echo "Try again in a minute"
		read -p "press enter to continue"
		menu
	fi
	echo -e "\nDuplicate SSID's are different antennas for the same network. i.e 2.4Ghz and 5ghz"
	echo -e "Select either. The correct one will be used when connecting\n"
	echo "Enter selection:"
	read wf
	if [[ $wf =~ ^[0-9]+$ ]]; then
		if [ $wf -ge 0 ] && [ $wf -le $ct ]; then
			updatessid "${wfselect[$wf-1]}"
		else
			echo -e $YEL"\nNot a Valid entry"$DEF
			setupssid
		fi
	else
		echo -e $YEL"\nNot a Valid entry"$DEF
		setupssid
	fi
	read -p "press enter to continue"
}

updatessid()
{
	d=0
	echo "$1"
	echo ""
	if [ "$1" = "Cancel" ] || [ "$1" = "" ] ; then
		clear
		menu
	fi
	saved_profiles
	for x in "${nw_profile[@]}"
	do
		idssid=$(nmcli -t con show "$x" | grep "wireless.ssid")
		#echo "The SSID for profile is ${idssid:21}"
		if [ "${idssid:21}" = "$1" ]; then
			#edit password
			echo "Enter the new password for PROFILE: $x SSID: $1"
			echo "This must be at least 8 characters."
			read ssidpw
			if [ ! -z "$ssidpw" ] && [ ${#ssidpw} -ge 8 ] ;then
				nmcli connection modify "$x" wifi-sec.psk "$ssidpw" >/dev/null 2>&1
				echo "Attempting to connect to $x"
				nmcli device wifi connect "$x" >/dev/null 2>&1
				stat=$?
				if [ $stat -eq 0 ] ; then
					echo "Connection successful"
					echo -e "\nThe Password for profile $x is"
					npw="$(nmcli -t -s con show "$x" | grep 'wireless-security.psk:' )"
					echo ${npw:29}
					d=1
					break
				else
					echo "The connection to $x Failed because of the change to the Password"
					echo "The profile for $x has been deleted. Please try again"
					nmcli connection delete "$x" >/dev/null 2>&1
					nmcli connection reload >/dev/null 2>&1
					d=2
				fi
			else
				echo "A password was not entered or is less than 8 characters"
				echo "The password has not been changed"
				d=2
			fi
		fi
	done

	if [ $d -eq 0 ]; then #no existing profile for selection, create a new one.
		echo -e $YEL"Enter the Password for the Selected Wifi Network"$DEF
		echo "This must be at least 8 characters"
		echo "Selected SSID: $1"
		echo -e "\nEnter password for the Wifi Network"
		read chgpw
		echo "Attempting to connect to the new Wifi Network"
		if [ ! -z "$chgpw" ] && [ "${#chgpw}" -ge 8 ] ;then
			#create new profile with details
			nmcli device wifi connect "$1" password "$chgpw" >/dev/null 2>&1
			stat=$?
			if [ $stat -eq 0 ] ; then
				echo "Profile Created"
				echo "$1"
				pw="$( nmcli -t -s con show $1 | grep 'wireless-security.psk:' )"
				echo ${pw:29}
				nmcli connection reload
			else
				echo "The connection to $1 Failed."
				echo "The new profile has not been saved"
				nmcli connection delete "$1" >/dev/null 2>&1
				nmcli connection reload >/dev/null 2>&1
			fi
		else
			echo "A password was not entered or is less than 8 characters"
			echo "The password has not been changed"
		fi
	fi
}

#Function Change Hostname
namehost()
{
		hn="$(nmcli general hostname)"
		echo -e $YEL"System Hostname is: $hn"$DEF
		echo "Enter a new hostname or"
		read -p "just press enter to keep existing hostname"
		if [ ! -z $r ]; then
			nmcli general hostname "$r"
			echo "The hostname has been changed"
			echo "You will need to restart the computer to complete the changes."
		fi
		hn="$(nmcli general hostname)"
		echo "Current Hostname is: $hn"
		read -p "press a key to continue"
}

ap_no_scan_options()
{
	local new_nw; local new_pw
	echo -e $YEL"\nThis device is unable to check for nearby Wifi Networks while the accesspoint is active."$DEF
	echo -e "$BOL Option 1: $DEF If you are using a screen on this device then use $BOL 1 $DEF to stop the Access Point and continue\n"
	echo -e "$BOL Option 2: $DEF If you are connected remotely such as ssh or vnc use $BOl 2 $DEF, then you can enter the network ssid and password manually."
	echo "Your connection to this device will then be disconnected while an attempt is made to connect to the new wifi network."
	echo "You will need to connect to the new network to continue"
	echo -e "\nIf there is any issues with the entered details such as; $BOL \nWifi network not in range\npassword incorrect\ngeneral connection failure $DEF"
	echo "Then the details will be deleted and the Access Point will be restarted"
	echo "You will need to reconnect to the Access Point again to continue if this happens."
	echo -e "\nType 1 or 2 to continue or just press enter to return to the min menu"
	read r
	if [ $r -eq 1 ]; then
		nmcli connection down $active
		setupssid
	elif [ $r -eq 2 ]; then
		echo -e $YEL"Enter the Wifi Network name (SSID) to be connected to:"$DEF
		echo "or just press enter to cancel"
		read n
		if [ -z "$n" ]; then
			menu
		else
			new_nw="$n"
			echo -e $YEL"Enter the password for $new_nw" $DEF
			echo "or just press enter to cancel"
			read n
			if [ -z "$n" ]; then
				menu
			else
				new_pw="$n"
				echo -e "\nA connection will be attempted to $new_nw"
				echo "Your connection with this device will be closed."
				echo "If there is a connection issue with $new_nw then the Access Point"
				echo "will be restarted. So if you cannot find this device on $new_nw"
				echo "then check for the AccessPopup wifi Access Point to connect to."
				echo "Please allow at least 30 seconds for this device to appear on $new_nw or the AP"
				echo "Press Enter to continue"
				read r
				nmcli connection down $active
				nohup ./nw_setup_offline.sh -s "$new_nw" -p "$new_pw" >/dev/null 2>&1 &
				menu
			fi
		fi

	else
		menu
	fi

}

devices()
{
	local devs=()
	local sorted_pairs=()
	for dev in /sys/class/net/*; do
		dev=$(basename "$dev")
		dev_path=$(readlink -f "/sys/class/net/$dev/device")
		if [[ -d "/sys/class/net/$dev/wireless" ]]; then
			if echo "$dev_path" | grep 'usb' >/dev/null 2>&1; then
				devs+=("wx ${dev}")
			else
				devs+=("wi ${dev}")
			fi
		fi
	done

	if [ -z "$devs" ]; then #no wifi device found
		echo ""
		echo "No Wifi device found."
		echo "The default of wlan0 will be used. AccessPopup will not work correctly if this is incorrect."
		echo "Manually update /etc/accesspopup.conf with the correct wifi device name when it is available"
		echo
		read -p "press any key to continue"
	else
		while IFS= read -r line; do
			sorted_pairs+=("$line")
		done < <(
			for pair in "${devs[@]}"; do
			printf "%s\n" "$pair"
			done | sort -k1,1   # Sorts by key
		)
		for i in "${sorted_pairs[@]}"; do
			read key val <<< "$i"
			[[ "$wdev0" = "wlan0" && ( "$key" == "wi" || "$key" == "wx" ) ]] && wdev0="$val"
		done
	fi
}

create_user()
{
# Create a dedicated system user without login shell
if ! id -u apu >/dev/null 2>&1; then
    echo "Creating apu system user..."
    useradd -r -s /usr/sbin/nologin -d /nonexistent apu
fi
}

add_permissions()
{
# Create sudoers file with restricted privileges
echo "apu ALL=(ALL) NOPASSWD: /usr/bin/nmcli, /usr/sbin/iw, /usr/bin/tee /etc/accesspopup.conf, /usr/local/bin/accesspopup" > "$sudoers_file"
chmod 440 "$sudoers_file"

if visudo -cf "$sudoers_file"; then
    echo "Sudoers file validated successfully."
    #add apu user
	if ! id apu >/dev/null 2>&1; then
		useradd --system --no-create-home --shell /usr/sbin/nologin apu
	fi
	return 0
else
    echo "Error: invalid sudoers file, removing..."
    rm -f "$sudoers_file"
    uninstall_web
    return 1
fi
}

webport()
{
	if [ ! -f "$sysd_path$webappsock" ]; then
		echo "The Web Page feature is not installed. Unable to change the port"
		echo "Press enter to continue"
		read x
		menu
	fi
	wp="$( grep -F ListenStream= ${sysd_path}${webappsock} )"
	ls="ListenStream=0.0.0.0:"
	if [ $? = 0 ];then
	echo -e $YEL"Raspberryconnect.com"
	echo "AccessPopup installation and setup"
	echo -e "Wep App Port Number"$DEF
	echo "Change the wep app web port from http://ipaddress:${wp:21}"
	echo "Enter the new port number"
	echo "or Press enter to keep the existing port number"
	read port
		if [ ! -z "$port" ]; then
			sed -i "s/ListenStream=.*/${ls}${port}/" "${sysd_path}${webappsock}"
			wp="$( grep -F ListenStream= ${sysd_path}${webappsock} )"
			echo "Web port changed to ${wp:21}"
			echo ""
			echo "Resetting Web Services."
			systemctl daemon-reload
			if systemctl -all list-unit-files "$webback" | grep "$webback enabled" >/dev/null 2>&1;then
				echo "Resetting the Web App to update changes"
				disable_web
				enable_web
			fi
			read -p "Press a key to continue"
		fi
	fi
}

update_release()
{
	local cur ans f
	local rc=0

	release_info || { read -p "Press any key to continue"; return 1; }
	cur="$(cat "${cpath}.release" 2>/dev/null)"
	echo "Installed release: ${cur:-unknown}"
	echo "Latest release:    $rel_tag"
	if [ "$cur" = "$rel_tag" ]; then
		echo "Already up to date."
		read -p "Press any key to continue"
		return 0
	fi
	read -p "Update to $rel_tag now? [y/N] " ans
	if [[ ! "$ans" =~ ^[Yy]$ ]]; then
		return 0
	fi

	release_download || { echo "Nothing has been changed."; read -p "Press any key to continue"; return 1; }

	echo "Updating project files in $cpath"
	#Write to a temp name then mv, so the running installer keeps reading its original file
	while IFS= read -r -d '' f; do
		mkdir -p "$(dirname "${cpath}${f}")" && cp -p "$rel_tmp/src/$f" "${cpath}${f}.new" && mv -f "${cpath}${f}.new" "${cpath}${f}" || { rc=1; break; }
	done < <(cd "$rel_tmp/src" && find . -type f -print0)

	if [ $rc -eq 0 ] && [ -d "$web_path" ]; then
		echo "Updating the web app in $web_path"
		deploy_web "$rel_tmp/src/ap_web" || rc=1
	elif [ $rc -eq 0 ]; then
		echo "The web app is not installed, only the project files were updated."
	fi
	rm -rf "$rel_tmp"

	if [ $rc -ne 0 ]; then
		echo "The update failed part way through. Please check the files and try again."
		read -p "Press any key to continue"
		return 1
	fi
	printf '%s\n' "$rel_tag" > "${cpath}.release"
	echo -e $YEL"Updated to release $rel_tag"$DEF
	read -p "Press any key to restart the installer"
	exec bash "${cpath}installconfig.sh"
}

config_web()
{
	local name logo ext base size dest tmp
	local logo_name=""
	local bad_re='["\\%]'

	if [ ! -f "${sysd_path}${webapp}" ] || [ ! -d "$web_path" ]; then
		echo "The Web Interface is not installed. Install it first from this menu (option 1)."
		read -p "Press any key to continue"
		return 1
	fi
	echo -e $YEL$BOL"Configure the Web App"$DEF
	echo "Enter the product name shown in the web app"
	echo "or just press enter to use the default"
	read -r name
	if [[ "$name" =~ $bad_re ]] || [[ "$name" =~ [[:cntrl:]] ]] || [ ${#name} -gt 64 ]; then
		echo "The product name must be 64 characters or less and cannot contain \" \\ or %"
		read -p "Press any key to continue"
		return 1
	fi

	echo "Enter the full path to the logo file (png, jpg, jpeg, gif, svg or webp, max 2MB)"
	echo "or just press enter to use the default"
	read -r logo
	if [ -n "$logo" ]; then
		ext="${logo##*.}"
		ext="${ext,,}"
		if [ ! -f "$logo" ] || [ ! -r "$logo" ]; then
			echo "The logo file $logo was not found or is not readable."
			read -p "Press any key to continue"
			return 1
		fi
		case "$ext" in
			png|jpg|jpeg|gif|svg|webp) ;;
			*) echo "The logo must be a png, jpg, jpeg, gif, svg or webp file."
			   read -p "Press any key to continue"
			   return 1 ;;
		esac
		size="$(stat -c %s "$logo")"
		if [ "$size" -gt 2097152 ]; then
			echo "The logo file is larger than 2MB."
			read -p "Press any key to continue"
			return 1
		fi
		base="$(basename "$logo")"
		base="${base//[^A-Za-z0-9._-]/_}"
		base="${base#.}"
		dest="$web_path/static/$base"
		mkdir -p "$web_path/static"
		if [ "$(readlink -f "$logo")" != "$(readlink -f "$dest")" ]; then
			if ! install -m 644 "$logo" "$dest"; then
				echo "Unable to copy the logo to $web_path/static"
				read -p "Press any key to continue"
				return 1
			fi
		fi
		logo_name="$base"
	fi

	#Replace any previous branding lines, then add the new ones before ExecStart
	tmp="$(mktemp)" || return 1
	awk -v n="$name" -v l="$logo_name" '
		/^Environment="?FLASK_(PRODUCT_NAME|LOGO_FILENAME)=/ { next }
		/^ExecStart=/ {
			if (n != "") print "Environment=\"FLASK_PRODUCT_NAME=" n "\""
			if (l != "") print "Environment=\"FLASK_LOGO_FILENAME=" l "\""
		}
		{ print }
	' "${sysd_path}${webapp}" > "$tmp" && cat "$tmp" > "${sysd_path}${webapp}"
	rm -f "$tmp"
	systemctl daemon-reload
	if systemctl is-active --quiet "$webapp"; then
		systemctl restart "$webapp"
	fi

	echo ""
	echo "Product name: ${name:-default}"
	echo "Logo file:    ${logo_name:-default}"
	read -p "Press any key to continue"
}

uninstall()
{
	echo "Uninstalling $scriptname"
	#Remove Timer service
	if systemctl -all list-unit-files $timer | grep $timer ;then
		systemctl unmask $timer
		systemctl disable $timer
		rm /etc/systemd/system/$timer
		systemctl daemon-reload
	fi
	if systemctl -all list-unit-files $service | grep $service ;then
		systemctl unmask $service
		systemctl disable $service
		rm /etc/systemd/system/$service
	fi
	#Remove AP and NM profile
	if [ -f "${script_path}${scriptname}" ]; then
		profap="$( grep -F ap_profile_name= ${conf_path}${conf_file} )"
		nmcli con delete "${profap:17:-1}" >/dev/null 2>&1
		nmcli con reload
		rm "${script_path}${scriptname}"
		rm "${conf_path}${conf_file}"
	fi
	echo "Uninstalled AccessPopup Files"
	uninstall_web
}

uninstall_web()
{
	#Remove webfiles if exist
	if [ -d $web_path ]; then
		rm -r $web_path
	fi
	#remove systemd services
	if systemctl -all list-unit-files $webapp | grep $webapp ;then
		systemctl stop $webapp
		systemctl disable $webapp
		systemctl daemon-reload
		rm /etc/systemd/system/$webapp
	fi
	#remove visudo file
	if [ -f $sudoers_file ]; then
		rm -r $sudoers_file >/dev/null 2>&1
	fi
	#remove apu user
	if id apu ; then
		delgroup apu >/dev/null 2>&1
		deluser apu >/dev/null 2>&1

	fi
	echo "Uninstalled Web Files"
	read -p "Press any key to continue"
}

go()
{
	opt="$1"
	if [ "$opt" = "INS" ] ;then
		if ls "${script_path}${scriptname}" >/dev/null 2>&1; then
			echo "$scriptname is already installed"
			read -p "Press a key to continue"
		else
			echo "Installing Script"
			install_general
		fi
	elif [ "$opt" = "SSI" ] ;then
		#"Change the Access Points SSID and Password"
		ap_ssid_change
	elif [ "$opt" = "NWK" ] ;then
		setupssid
	elif [ "$opt" = "SWI" ] ;then
		echo -e $YEL"Switching between WiFi Network and WiFi Access Point."$DEF
		if [ -f "$script_path$scriptname" ]; then
			switch
		else
			echo "$scriptname is not currently installed."
			echo "Please install it first"
			read -p "Press a key to continue"
		fi
	elif [ "$opt" = "IPA" ] ;then
		echo -e "${BOL}Set IP address for AP${DEF}"
		ap_change_ip
	elif [ "$opt" = "UNI" ] ;then
		if ls "${script_path}${scriptname}" >/dev/null 2>&1 ; then
			uninstall
		else
			echo "$scriptname is not installed"
			read -p "Press a key to continue"
		fi
	elif [ "$opt" = "RUN" ] ;then
		if [ -f "${script_path}${scriptname}" ]; then
			echo "Running ${scriptname} now"
			"${script_path}${scriptname}"
			read -p "Press a key to continue"
		else
			echo "$scriptname is not available."
			echo "Please install the AccessPopup first with Option 1"
			read -p "Press a key to continue"
		fi
	elif [ "$opt" = "HST" ] ;then
		namehost
	elif [ "$opt" = "DIS" ] ;then
		reactivate
	elif [ "$opt" = "WEB" ] ;then
		webcheck
	elif [ "$opt" = "MU2" ] ;then
		menu_more
	elif  [ "$opt" = "WPO" ] ;then
		webport
	elif [ "$opt" = "UPD" ] ;then
		update_release
	elif [ "$opt" = "CFG" ] ;then
		config_web
	fi
	clear
	menu
}

menu()
{
#selection menu
clear
until [ "$select" = "9" ]; do #set number to qty of menu options
	active_wifi
	apver="$( grep -F '#version' ${scriptname} )"
	curip=$(nmcli -t con show "$active" | grep IP4.ADDRESS)
	readarray -d ':' -t ipid < <(printf "%s" "$curip")
	showip="$(echo "${ipid[1]}" | sed 's/[[:blank:]]//g')"

	echo -e $YEL"Raspberryconnect.com"
	echo "AccessPopup installation and setup"
	echo -e "Version $ver  Installs AccessPopup ver ${apver:9}"$DEF
	echo "Connects to your home network when you are home or a nearby know wifi network."
	echo "If no known wifi network is found then an Access Point is automatically activated"
	echo -e "until a known network is back in range\n"
	echo "Using wifi device $wdev0"
	if [ -z "$active" ]; then
		echo "Not currently using a Wifi profile"
	else
		echo "Currently using WiFi profile: $active"
		if [ ! -z $showip ]; then
			echo "Current WiFi IP address is: ${showip::-3}"
		fi
		hn="$(nmcli general hostname)"
		echo "System Hostname is: $hn"
	fi
	echo ""
	echo " 1 = Install AccessPopup and the Web app"
	echo " 2 = Change the AccessPopups SSID or Password"
	echo " 3 = Change the AccessPopups IP Address"
	echo " 4 = Live Switch between: Known WIFI Network <> Access Point"
	echo " 5 = Setup a New WiFi Network or change the password to an existing Wifi Network"
	echo " 6 = Change Hostname"
	echo " 7 = Run $scriptname now. It will decide between a suitable WiFi network or AP."
	echo " 8 = Additional Menu"
	echo " 9 = Exit"
	echo ""
	echo "The Wifi status will be checked every 2 minutes. Switching will happen when a"
	echo "valid wifi network comes in and out of range."
	echo "use option 4 or the command: sudo $scriptname -a"
	echo "to activate a permanent access point, until the next reboot"
	echo "or when just sudo $scriptname is used."
	echo -e -n "\nSelect an Option:"
	read select
	case $select in
	1) clear ; go "INS" ;; #Install AccessPopup
	2) clear ; go "SSI" ;; #Set the AP SSID and Password
	3) clear ; go "IPA" ;; #Set the Access Points IP Address
	4) clear ; go "SWI" ;; #Live Switch: NW <> AP
	5) clear ; go "NWK" ;; #Connect to New WiFi Network
	6) clear ; go "HST" ;; #Change Hostname
	7) clear ; go "RUN" ;; #Run the AccessPopup script now
	8) clear ; go "MU2" ;; #Additional Menu
	9) clear ; exit ;;
	*) clear; echo -e "Please select again\n";;
	esac
done
}

menu_more()
{
	#Additional menu
	clear
	until [ "$select" = "7" ]; do #set number to qty of menu options
	echo -e $YEL"Raspberryconnect.com"
	echo "AccessPopup installation and setup"
	echo -e "Additional Options"$DEF
	echo ""
	echo " 1 = Web Interface - enable & disable switch"
	echo " 2 = Change the Webport. default 8052"
	echo " 3 = When Wifi is Disabled: Automatically re-activate Y/N"
	echo " 4 = Uninstall $scriptname and Web app"
	echo " 5 = Update to the latest release (project and Web app)"
	echo " 6 = Configure the Web app (product name and logo)"
	echo " 7 = Back to the Main menu"
	echo -e -n "\nSelect an Option:"
	read select
	case $select in
	1) clear ; go "WEB" ;; #Web Interface enable disable
	2) clear ; go "WPO" ;; #Web Port number
	3) clear ; go "DIS" ;; #Wifi reactivation options
	4) clear ; go "UNI" ;; #Uninstall AccessPopup
	5) clear ; go "UPD" ;; #Update to latest release
	6) clear ; go "CFG" ;; #Configure web app branding
	7) clear ; menu ;;
	*) Clear ; echo -e "Please select again\n";;
	esac
done
}
devices
menu
