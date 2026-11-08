#!/bin/bash
#version 0.2
#date 31 May 2025
#Script for use by installconfig.sh by RaspberryConnect.com as part of AccessPopup 
#Adds a Network Manager profile from the supplied ssid and password.
#This script will be run in the background from the web app when the user chooses to add a new Wifi network
#from another wifi device as the connection will be closed with the webserver before the setup is compete.


ssid=""
pwd=""
wdev0=""

usage() {
  echo "Usage: $0 -s <ssid> -p <password> [-i <wifi interface>]"
  exit 1
}

while getopts "s:p:i:" opt; do
  case $opt in
    s)
      ssid="$OPTARG"
      ;;
    p)
      pwd="$OPTARG"
      ;;
    i)
      wdev0="$OPTARG"
      ;;
    *)
      usage
      ;;
  esac
done

#Fall back to the device configured for AccessPopup
if [ -z "$wdev0" ] && [ -f /etc/accesspopup.conf ]; then
  wdev0="$(sed -n "s/^[[:space:]]*wdev0=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" /etc/accesspopup.conf 2>/dev/null | head -n1)"
fi
[ -n "$wdev0" ] || wdev0="wlan0"

if [ -z "$ssid" ] || [ -z "$pwd" ]; then
  exit 1
fi

#A USB adapter can take a few seconds to enumerate after the AP is stopped
for _ in $(seq 1 10); do
  [ -d "/sys/class/net/$wdev0/wireless" ] && break
  sleep 1
done

if [ ! -d "/sys/class/net/$wdev0/wireless" ]; then
  echo "The WiFi device $wdev0 is not available."
  echo "Update wdev0 in /etc/accesspopup.conf or use the installer's Change WiFi Device option."
  exit 1
fi

echo "Attempting to connect to the new Wifi Network using $wdev0"
if [ ! -z "$ssid" ] && [ "${#pwd}" -ge 8 ] ;then
	#create new profile with details
	nmcli device wifi connect "$ssid" password "$pwd" ifname "$wdev0" >/dev/null 2>&1
	stat=$?
	if [ $stat -eq 0 ] ; then
		echo "Profile Created"
		echo "$ssid"
		nmcli connection modify "$ssid" connection.interface-name "$wdev0" >/dev/null 2>&1
		pw="$( nmcli -t -s con show $ssid | grep 'wireless-security.psk:' )"
		echo ${pw:29}
		nmcli connection reload
	else
		echo "The connection to $ssid Failed."
		echo "The new profile has not been saved"
		nmcli connection delete "$ssid" >/dev/null 2>&1
		nmcli connection reload >/dev/null 2>&1
	fi
else
	echo "Password is less than 8 characters, unable to continue"
fi
