#!/bin/bash
#Original Copyright Graeme Richards - RaspberryConnect.com
#Released under the GPL3 Licence (https://www.gnu.org/licenses/gpl-3.0.en.html)

#Installation and configuration script for the AccessPopup script, that switches between
#a Wifi Access Point or connects to a Wifi Network as required

#Run this script directly from GitHub without downloading a release:
#curl -fsSL https://raw.githubusercontent.com/CodeWilliamson/AccessPopup/main/installconfig.sh | sudo bash
#It downloads the latest published release and offers to install or update.

osver=($(cat /etc/issue))
standalone="n"
cpath=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	cpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
fi
#Without a local release folder the script was piped from the GitHub raw URL
if [ -z "$cpath" ] || [ ! -f "${cpath}accesspopup" ] || [ ! -f "${cpath}accesspopup.conf" ]; then
	standalone="y"
	cpath=""
fi
wdev0="${WIFI_DEVICE:-wlan0}"
ap_profile_name="AccessPopup"

#When the script comes from a pipe, read prompts from the terminal instead
if [ "$standalone" = "y" ] && [ ! -t 0 ]; then
	if ! { exec 3</dev/tty; } 2>/dev/null; then
		echo "A terminal is required to run the installer."
		echo "Run it from an interactive shell, or use:"
		echo "sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/CodeWilliamson/AccessPopup/main/installconfig.sh)\""
		exit 1
	fi
	read() { builtin read -u 3 "$@"; }
fi

#Reads a key press from the terminal even when the script itself came from a pipe
pause_key()
{
	local msg="${1:-Press a key to continue}"
	if [ -t 0 ]; then
		read -p "$msg" _
	elif [ -c /dev/tty ]; then
		read -p "$msg" _ < /dev/tty
	fi
}

script_path="/usr/local/bin/"
scriptname="accesspopup"
conf_path="/etc/"
conf_file="accesspopup.conf"
web_path="/usr/local/bin/ap_web"
webfile_app="/usr/local/bin/ap_web/app.py"

#Use the installed configuration so menu actions and updates keep the device
#that AccessPopup actually runs with. An explicit WIFI_DEVICE wins.
if [ -f "${conf_path}${conf_file}" ]; then
	conf_wdev="$(sed -n "s/^[[:space:]]*wdev0=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" "${conf_path}${conf_file}" 2>/dev/null | head -n1)"
	[ -n "$conf_wdev" ] && [ -z "${WIFI_DEVICE:-}" ] && wdev0="$conf_wdev"
	conf_ap="$(sed -n "s/^[[:space:]]*ap_profile_name=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*/\1/p" "${conf_path}${conf_file}" 2>/dev/null | head -n1)"
	[ -n "$conf_ap" ] && ap_profile_name="$conf_ap"
fi

active_ap="n"
active=""
nw_profile=()

#service
sysd_path="/etc/systemd/system/"
service=AccessPopup.service
timer=AccessPopup.timer
webapp=ap_web_app.service
sudoers_file="/etc/sudoers.d/apu"

#Captive portal system settings
dnsmasq_shared_dir="/etc/NetworkManager/dnsmasq-shared.d"
dnsmasq_shared_conf="${dnsmasq_shared_dir}/captive-portal.conf"
polkit_nm_rules="/usr/share/polkit-1/rules.d/org.freedesktop.NetworkManager.rules"

#nginx
web_port="8080"
nginx_conf="/etc/nginx/nginx.conf"
nginx_avail="/etc/nginx/sites-available"
nginx_enabled="/etc/nginx/sites-enabled"
nginx_site="${nginx_avail}/accesspopup"
nginx_site_link="${nginx_enabled}/accesspopup"
nginx_include="/etc/nginx/conf.d/accesspopup-sites.conf"
nginx_dispatch="/etc/NetworkManager/dispatcher.d/90-accesspopup-nginx"

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
		pause_key
	elif [ "${osver[2]}" -lt 11 ];then #older OS
		echo "The version of PiOS is too old for the $scriptname script"
		echo "Version 11 'Bullseye' with Network Manager enabled in raspi-config is the minimum requirement"
		echo "A version for your OS is available at RaspberryConnect.com using dhcpcd instead."
		echo "www.raspberryconnect.com/projects/65-raspberrypi-hotspot-accesspoints/183-raspberry-pi-automatic-hotspot-and-static-hotspot-installer"
		pause_key "Press any key to continue"
		exit 1
	fi
fi

readlink /sbin/init | grep systemd >/dev/null 2>&1
if [ "$?" -gt 0 ] ;then
	echo "systemd is not available."
	echo "This script uses SystemD services. Unable to continue."
	pause_key
	exit 1
fi


systemctl is-active --quiet NetworkManager.service
if [ $? -ne 0 ];then
	echo "NetworkManager is not available."
	echo "This script requires NetworkManager but it is not active."
	echo "Unable to continue"
	pause_key
	exit 1
fi

#Returns 0 when $1 is a wireless network interface on this system
is_wifi_device()
{
	local dev="${1:-$wdev0}"
	[ -n "$dev" ] && [ -d "/sys/class/net/${dev}/wireless" ]
}

#Describes whether a wireless interface is an external USB adapter
wifi_device_kind()
{
	local path
	path="$(readlink -f "/sys/class/net/${1}/device" 2>/dev/null)"
	if printf '%s' "$path" | grep -q '/usb'; then
		printf 'external USB\n'
	else
		printf 'built-in\n'
	fi
}

#Lists the wireless interfaces on this system, one per line
wifi_device_list()
{
	local dev
	for dev in /sys/class/net/*; do
		[ -e "$dev" ] || continue
		dev="$(basename "$dev")"
		is_wifi_device "$dev" && printf '%s\n' "$dev"
	done
}

#Replaces key='value' in a shell-style config file, or appends it
set_config_value()
{
	local file="$1" key="$2" value="$3"
	[ -f "$file" ] || return 1
	if grep -q "^[[:space:]]*${key}=" "$file"; then
		sed -i "s|^[[:space:]]*${key}=.*|${key}='${value}'|" "$file"
	else
		printf "\n%s='%s'\n" "$key" "$value" >> "$file"
	fi
}

#Sets Environment="KEY=value" in the [Service] section of a systemd unit.
#Returns 0 when the file changed and 1 when it was already correct.
set_service_env()
{
	local unit="$1" key="$2" value="$3" line
	[ -f "$unit" ] || return 1
	line="Environment=\"${key}=${value}\""
	if grep -q "^Environment=\"\{0,1\}${key}=" "$unit"; then
		[ "$(grep -m1 "^Environment=\"\{0,1\}${key}=" "$unit")" = "$line" ] && return 1
		sed -i "s|^Environment=\"\{0,1\}${key}=.*|${line}|" "$unit" || return 1
	else
		sed -i "/^\[Service\]/a ${line}" "$unit" || return 1
	fi
	return 0
}

#Makes the web app follow the configured wireless device and AP profile
update_web_service_device()
{
	local unit="${sysd_path}${webapp}" changed=0
	[ -f "$unit" ] || return 0
	set_service_env "$unit" WIFI_INTERFACE "$wdev0" && changed=1
	set_service_env "$unit" AP_CONNECTION "$ap_profile_name" && changed=1
	if [ "$changed" -eq 1 ]; then
		systemctl daemon-reload >/dev/null 2>&1
		if systemctl is-active --quiet "$webapp"; then
			systemctl restart "$webapp" >/dev/null 2>&1
		fi
	fi
	return 0
}

#Writes the selected device to /etc/accesspopup.conf and refreshes the
#services that depend on it
persist_wifi_device()
{
	set_config_value "${conf_path}${conf_file}" wdev0 "$wdev0"
	update_web_service_device
	if [ -f "$dnsmasq_shared_conf" ]; then
		add_dnsmasq_shared >/dev/null
	fi
	#Keep the saved AP profile on the same adapter
	if nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$ap_profile_name"; then
		nmcli connection modify "$ap_profile_name" connection.interface-name "$wdev0" >/dev/null 2>&1 || true
	fi
}

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
if ! systemctl list-unit-files --all | grep -q "$webapp" ;then
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
Environment="WIFI_INTERFACE=${wdev0}"
Environment="AP_CONNECTION=${ap_profile_name}"
Environment=WIFI_CONNECT_TIMEOUT=25
Environment=PORTAL_HOST=0.0.0.0
Environment=PORTAL_PORT=${web_port}
ExecStart=/usr/local/bin/ap_web/venv/bin/python /usr/local/bin/ap_web/app.py
Restart=on-failure
RestartSec=5

# nmcli needs root privileges for connection provisioning.
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
fi
#Keep an existing unit in step with /etc/accesspopup.conf
update_web_service_device
}

#Returns the Access Point IPv4 address from accesspopup.conf
ap_ip_address()
{
	local ip=""
	if [ -f "${conf_path}${conf_file}" ]; then
		ip="$(grep -E '^[[:space:]]*ap_ip=' "${conf_path}${conf_file}" 2>/dev/null | head -n1 | cut -d= -f2-)"
		ip="${ip//[[:space:]]/}"
		ip="${ip//\'/}"
		ip="${ip//\"/}"
		ip="${ip%%#*}"
		ip="${ip%%/*}"
	fi
	if [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
		ip="192.168.50.1"
	fi
	printf '%s\n' "$ip"
}

install_nginx()
{
	if command -v nginx >/dev/null 2>&1; then
		return 0
	fi
	local pm="$(packageman)"
	case "$pm" in
		apt)
			apt install nginx < /dev/tty
			;;
		dnf)
			dnf install nginx < /dev/tty
			;;
		pacman)
			pacman -S nginx < /dev/tty
			;;
		*)
			echo "Unable to determine the package manager. nginx must be installed manually."
			return 1
			;;
	esac
}

#Makes sure nginx includes /etc/nginx/sites-enabled on distributions that do not do so by default
ensure_nginx_sites_include()
{
	local f found=0
	for f in "$nginx_conf" /etc/nginx/conf.d/*.conf; do
		[ "$f" = "$nginx_include" ] && continue
		[ -f "$f" ] || continue
		if grep -Eq '^[[:space:]]*include[[:space:]]+.*sites-enabled' "$f"; then
			found=1
			break
		fi
	done
	if [ "$found" -eq 1 ]; then
		#Another nginx file already includes sites-enabled, so avoid a duplicate include
		rm -f "$nginx_include"
		return 0
	fi
	mkdir -p "$(dirname "$nginx_include")" || return 1
	printf '%s\n' 'include /etc/nginx/sites-enabled/*;' > "$nginx_include" || return 1
	return 0
}

add_nginx_site()
{
	local ip backup=""
	ip="$(ap_ip_address)"
	mkdir -p "$nginx_avail" "$nginx_enabled" || return 1
	if [ -f "$nginx_site" ]; then
		backup="$(mktemp)" || return 1
		cp -p "$nginx_site" "$backup" || { rm -f "$backup"; return 1; }
	fi
	cat > "$nginx_site" <<EOF
server {
	listen ${ip}:80;
	server_name _;

	location / {
		proxy_pass http://127.0.0.1:${web_port};
		proxy_http_version 1.1;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
	}
}
EOF
	if ! ln -sfn "$nginx_site" "$nginx_site_link" || ! ensure_nginx_sites_include; then
		echo "Unable to enable the nginx site for AccessPopup."
		if [ -n "$backup" ]; then
			cp -p "$backup" "$nginx_site"
		else
			rm -f "$nginx_site_link" "$nginx_site"
		fi
		rm -f "$backup"
		return 1
	fi
	if ! nginx -t >/dev/null 2>&1; then
		echo "The nginx configuration test failed."
		nginx -t
		if [ -n "$backup" ]; then
			cp -p "$backup" "$nginx_site"
		else
			rm -f "$nginx_site_link" "$nginx_site"
		fi
		rm -f "$backup"
		return 1
	fi
	if ! nginx -T 2>/dev/null | grep -Eq "configuration file (${nginx_site_link}|${nginx_site}):"; then
		echo "Warning: nginx did not load the AccessPopup site. Check the nginx configuration."
	fi
	rm -f "$backup"
	systemctl enable nginx >/dev/null 2>&1
	if systemctl is-active --quiet nginx; then
		systemctl reload nginx >/dev/null 2>&1 || echo "nginx is running but could not be reloaded. It will be reloaded when ${ip} is available."
	else
		if ! systemctl start nginx >/dev/null 2>&1; then
			echo "nginx could not be started. It will be retried when ${ip} is available."
		fi
	fi
	return 0
}

#NetworkManager runs this when an interface comes up, so nginx starts once the AP address exists
add_nginx_dispatcher()
{
	mkdir -p "$(dirname "$nginx_dispatch")" || return 1
	cat > "$nginx_dispatch" <<'EOF'
#!/bin/sh
# Reload nginx when the AccessPopup access point address is configured.
# Installed by the AccessPopup installer.

case "$2" in
	up|dhcp4-change) ;;
	*) exit 0 ;;
esac

AP_IP="$(sed -n "s/^[[:space:]]*ap_ip=['\"]\{0,1\}\([0-9.]*\).*/\1/p" /etc/accesspopup.conf 2>/dev/null | head -n1)"
[ -n "$AP_IP" ] || exit 0
ip -4 addr show dev "$1" 2>/dev/null | grep -Fq "inet $AP_IP/" || exit 0

if systemctl is-active --quiet nginx; then
	systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
else
	systemctl start nginx >/dev/null 2>&1
fi
exit 0
EOF
	chmod 755 "$nginx_dispatch"
}

configure_nginx()
{
	if ! command -v nginx >/dev/null 2>&1; then
		echo "nginx is not installed, skipping the port 80 site configuration."
		return 1
	fi
	if ! add_nginx_site; then
		echo "Unable to configure the nginx site for AccessPopup."
		return 1
	fi
	if ! add_nginx_dispatcher; then
		echo "Unable to install the NetworkManager dispatcher for nginx."
		return 1
	fi
	return 0
}

remove_nginx_site()
{
	rm -f "$nginx_site_link" "$nginx_site" "$nginx_dispatch"
	if [ -d "$nginx_enabled" ] && [ -z "$(ls -A "$nginx_enabled" 2>/dev/null)" ]; then
		rm -f "$nginx_include"
	fi
	if systemctl is-active --quiet nginx; then
		systemctl reload nginx >/dev/null 2>&1
	fi
}

#Answers every DNS request with the Access Point address, so a captive portal
#can be shown for any domain requested by a connected device
add_dnsmasq_shared()
{
	local ip
	ip="$(ap_ip_address)"
	if ! mkdir -p "$dnsmasq_shared_dir"; then
		echo "Unable to create $dnsmasq_shared_dir. Captive portal DNS will not work."
		return 1
	fi
	if ! cat > "$dnsmasq_shared_conf" <<EOF
interface=${wdev0}
listen-address=${ip}
address=/#/${ip}
EOF
	then
		echo "Unable to create $dnsmasq_shared_conf. Captive portal DNS will not work."
		return 1
	fi
	echo "Created the shared dnsmasq configuration for the captive portal."
	return 0
}

#Lets the apu user manage NetworkManager without a password prompt
add_polkit_rule()
{
	local rule='polkit.addRule(function(action, subject) { if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 && subject.user == "apu") { return polkit.Result.YES; } });'

	if [ ! -d "$(dirname "$polkit_nm_rules")" ]; then
		echo "The polkit rules directory was not found. Skipping the NetworkManager rule."
		return 1
	fi
	if [ -f "$polkit_nm_rules" ] && grep -Fq 'subject.user == "apu"' "$polkit_nm_rules"; then
		echo "The NetworkManager polkit rule for apu is already present."
		return 0
	fi
	#Start the rule on a new line when the existing file does not end with one
	if [ -s "$polkit_nm_rules" ] && [ -n "$(tail -c 1 "$polkit_nm_rules")" ]; then
		printf '\n' >> "$polkit_nm_rules" || {
			echo "Unable to update $polkit_nm_rules."
			return 1
		}
	fi
	if ! printf '%s\n' "$rule" >> "$polkit_nm_rules"; then
		echo "Unable to update $polkit_nm_rules."
		return 1
	fi
	echo "Added the NetworkManager polkit rule for the apu user."
	return 0
}

#Adds quiet to the kernel command line to reduce the boot text on the screen
add_cmdline_quiet()
{
	local f="" cand
	for cand in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
		if [ -f "$cand" ]; then
			f="$cand"
			break
		fi
	done
	if [ -z "$f" ]; then
		echo "cmdline.txt was not found. Skipping the quiet boot option."
		return 1
	fi
	if grep -Eq '(^|[[:space:]])quiet([[:space:]]|$)' "$f"; then
		echo "quiet is already set in $f."
		return 0
	fi
	#cmdline.txt must stay a single line, so add quiet to the end of that line
	local line
	line="$(tr -d '\r\n' < "$f")" || {
		echo "Unable to read $f."
		return 1
	}
	#Strip any trailing whitespace before adding quiet
	if ! printf '%s quiet\n' "${line%"${line##*[![:space:]]}"}" > "$f"; then
		echo "Unable to add quiet to $f."
		return 1
	fi
	if ! grep -Eq '(^|[[:space:]])quiet([[:space:]]|$)' "$f"; then
		echo "Unable to add quiet to $f."
		return 1
	fi
	echo "Added quiet to $f. It takes effect on the next boot."
	return 0
}

#Applies the system settings that AccessPopup relies on
configure_system_settings()
{
	add_dnsmasq_shared
	add_polkit_rule
	add_cmdline_quiet
	return 0
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
		for f in installconfig.sh accesspopup accesspopup.conf nw_setup_offline.sh ap_web/app.py ap_web/requirements.txt; do
			[ -f "$rel_tmp/src/$f" ] || bad="The release is missing $f."
		done
	fi
	if [ -n "$bad" ]; then
		echo "$bad"
		rm -rf "$rel_tmp"; rel_tmp=""
		return 1
	fi
}

#Returns the release tag recorded for the installed AccessPopup
installed_release()
{
	local f="${script_path}.release"
	[ -f "$f" ] && head -n1 "$f"
}

#Records the release tag for the installed AccessPopup
record_installed_release()
{
	local tag=""
	if [ -f "${cpath}.release" ]; then
		tag="$(head -n1 "${cpath}.release")"
	fi
	if [ -z "$tag" ] && [ "$standalone" = "y" ]; then
		tag="${rel_tag:-}"
	fi
	if [ -n "$tag" ]; then
		printf '%s\n' "$tag" > "${script_path}.release"
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
	local pm="$(packageman)" src="" cur i rc=0
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
			dpkg -s "$i" >/dev/null 2>&1 || apt install "$i" < /dev/tty || {
				echo "Unable to install dependency $i"
				echo "This may be because there is no internet access or the package is unavailable"
				return 1
			}
		done
	fi
	if ! install_nginx; then
		echo "nginx could not be installed. The web app will still be available on port ${web_port}."
	fi

	if [ "$standalone" = "y" ]; then
		#The release has already been downloaded by run_standalone
		src="${cpath}ap_web"
	elif release_info; then
		cur="$(cat "${cpath}.release" 2>/dev/null)"
		if [ "$cur" = "$rel_tag" ] && [ -f "${cpath}ap_web/app.py" ]; then
			echo "The local web app files are already the latest release ($rel_tag)"
			src="${cpath}ap_web"
		elif release_download; then
			src="$rel_tmp/src/ap_web"
		fi
	fi
	if [ -z "$src" ]; then
		echo "Using the local web app files in ${cpath}ap_web"
		src="${cpath}ap_web"
	fi
	if [ -f "$src/app.py" ] && deploy_web "$src" && add_permissions; then
		add_web_app_service
		systemctl daemon-reload
		systemctl enable --now "$webapp"
		if ! configure_nginx; then
			echo "The nginx port 80 forwarding could not be configured."
			echo "The web app is still available on port ${web_port}."
		fi
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
		echo "In a web browser use http://localhost:${web_port} on this device or"
		echo -e "from another device use the http://ip_address:${web_port} or the http://hostname:${web_port}"
		echo -e "From devices connected to the Access Point use http://$(ap_ip_address)" $DEF
		if [ -f "$nginx_site" ]; then
			echo "Port 80 on the Access Point is forwarded to port ${web_port}."
		fi
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
	if ! install_nginx || ! configure_nginx; then
		echo "The nginx port 80 forwarding could not be configured."
	fi
fi
}

#Function what is the current active wifi
active_wifi()
{
	active="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$wdev0" '$2==d {print $1; exit}')"
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
				apt install "$i" < /dev/tty
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
				dnf install "$i" < /dev/tty
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
				pacman -S "$i" < /dev/tty
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

	cp "./$scriptname" "$script_path"
	cp "./$conf_file" "${conf_path}${conf_file}"
	#Always persist the device selected during this install, including wlan0
	set_config_value "${conf_path}${conf_file}" wdev0 "$wdev0" || true
	if [ "$wdev0" != "wlan0" ]; then
		echo "Using wifi device $wdev0 in ${conf_path}${conf_file}"
	fi
	chmod +x "${script_path}${scriptname}"
	configure_system_settings
	#Install the web app before the network script runs, as it may take the device offline
	install_web
	add_service
	add_timer_service
	systemctl start $timer
	"${script_path}${scriptname}"
	chmod +x ./nw_setup_offline.sh
	record_installed_release
	echo -e "\nAccessPopup has been installed"
	if [ "${auto_action:-0}" -ne 1 ]; then
		read -p "Press any key to continue"
	fi
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
		pro="$(nmcli -t -f NAME con show 2>/dev/null | grep -Fx "$ap_profile_name")"
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

			if command -v nginx >/dev/null 2>&1 && [ -f "$nginx_site" ]; then
				echo "Updating the nginx site for the new Access Point address"
				configure_nginx
			fi

			if [ -f "$dnsmasq_shared_conf" ]; then
				echo "Updating the shared dnsmasq configuration for the new Access Point address"
				add_dnsmasq_shared
			fi

			pro="$(nmcli -t -f NAME con show 2>/dev/null | grep -Fx "$ap_profile_name")"
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

	if ! is_wifi_device "$wdev0"; then
		echo "The configured WiFi device $wdev0 is not available."
		echo "Use Additional Menu > Change WiFi Device to select the adapter,"
		echo "or connect the USB WiFi adapter and try again."
		read -p "press a key to continue"
		menu
	fi

	until [ $lp -eq 1 ] #wait for wifi if busy, usb wifi is slower.
	do
		IFS=$'\n:$\t' localwifi=($( (iw dev "$wdev0" scan ap-force | grep -E "SSID:") 2>&1 ))
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
	#Some USB adapters do not support "iw scan ap-force". Fall back to NetworkManager.
	if ! printf '%s\n' "${localwifi[@]}" | grep -q "SSID"; then
		localwifi=($(nmcli -t -f SSID device wifi list ifname "$wdev0" 2>/dev/null | sed '/^[[:space:]]*$/d'))
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
				nmcli connection modify "$x" connection.interface-name "$wdev0" >/dev/null 2>&1
				echo "Attempting to connect to $x"
				nmcli device wifi connect "$x" ifname "$wdev0" >/dev/null 2>&1
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
			nmcli device wifi connect "$1" password "$chgpw" ifname "$wdev0" >/dev/null 2>&1
			stat=$?
			if [ $stat -eq 0 ] ; then
				echo "Profile Created"
				echo "$1"
				nmcli connection modify "$1" connection.interface-name "$wdev0" >/dev/null 2>&1
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
				nohup ./nw_setup_offline.sh -s "$new_nw" -p "$new_pw" -i "$wdev0" >/dev/null 2>&1 &
				menu
			fi
		fi

	else
		menu
	fi

}

devices()
{
	local force="${1:-0}"
	local -a devs=() kinds=()
	local dev choice i default_index=1

	while IFS= read -r dev; do
		[ -n "$dev" ] || continue
		devs+=("$dev")
		kinds+=("$(wifi_device_kind "$dev")")
	done < <(wifi_device_list)

	if [ ${#devs[@]} -eq 0 ]; then #no wifi device found
		echo ""
		echo "No Wifi device found."
		echo "The default of wlan0 will be used. AccessPopup will not work correctly if this is incorrect."
		echo "Manually update /etc/accesspopup.conf with the correct wifi device name when it is available"
		echo "or use Additional Menu > Change WiFi Device once the adapter is connected."
		echo
		read -p "press any key to continue"
		return 0
	fi

	#Keep the configured device while it is present, unless the user asked to change it
	if [ "$force" -ne 1 ] && is_wifi_device "$wdev0"; then
		return 0
	fi
	if [ "$force" -ne 1 ] && [ ${#devs[@]} -eq 1 ]; then
		wdev0="${devs[0]}"
		echo "Using WiFi device $wdev0 (${kinds[0]})"
		return 0
	fi

	#Non-interactive install: prefer the external USB adapter
	if [ "$force" -ne 1 ] && ! { [ -t 0 ] || [ -c /dev/tty ]; }; then
		for i in "${!devs[@]}"; do
			if [ "${kinds[$i]}" = "external USB" ]; then
				wdev0="${devs[$i]}"
				return 0
			fi
		done
		wdev0="${devs[0]}"
		return 0
	fi

	echo ""
	echo "Available WiFi devices:"
	for i in "${!devs[@]}"; do
		if [ "${devs[$i]}" = "$wdev0" ]; then
			default_index=$((i + 1))
			printf ' %s = %s (%s) [configured]\n' "$((i + 1))" "${devs[$i]}" "${kinds[$i]}"
		else
			printf ' %s = %s (%s)\n' "$((i + 1))" "${devs[$i]}" "${kinds[$i]}"
		fi
	done
	if ! is_wifi_device "$wdev0"; then
		for i in "${!devs[@]}"; do
			if [ "${kinds[$i]}" = "external USB" ]; then
				default_index=$((i + 1))
				break
			fi
		done
	fi

	while true; do
		read -p "Select the WiFi device to use [$default_index]: " choice
		choice="${choice:-$default_index}"
		if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#devs[@]} ]; then
			wdev0="${devs[$((choice - 1))]}"
			break
		fi
		echo "Enter a number from 1 to ${#devs[@]}."
	done
	echo "WiFi device set to $wdev0 (${kinds[$((choice - 1))]})"
	return 0
}

change_wifi_device()
{
	echo -e $YEL$BOL"Change the WiFi Device"$DEF
	if [ -z "$(wifi_device_list)" ]; then
		echo "No Wifi device found."
		echo "Connect the adapter and try again."
		read -p "press any key to continue"
		return 1
	fi
	echo "The current device is $wdev0"
	devices 1
	if [ -f "${conf_path}${conf_file}" ]; then
		persist_wifi_device
		echo "AccessPopup and the web app will use $wdev0 from the next network check."
	else
		echo "AccessPopup is not installed. $wdev0 will be used when it is installed."
	fi
	read -p "press any key to continue"
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

	if [ "$standalone" = "y" ]; then
		update_release_standalone
		return
	fi

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
	while IFS= builtin read -r -d '' f; do
		mkdir -p "$(dirname "${cpath}${f}")" && cp -p "$rel_tmp/src/$f" "${cpath}${f}.new" && mv -f "${cpath}${f}.new" "${cpath}${f}" || { rc=1; break; }
	done < <(cd "$rel_tmp/src" && find . -type f -print0)

	if [ $rc -eq 0 ] && [ -d "$web_path" ]; then
		echo "Updating the web app in $web_path"
		deploy_web "$rel_tmp/src/ap_web" || rc=1
		if [ $rc -eq 0 ]; then
			if install_nginx && configure_nginx; then
				echo "The nginx port 80 forwarding has been updated."
			else
				echo "The nginx port 80 forwarding could not be updated."
			fi
		fi
	elif [ $rc -eq 0 ]; then
		echo "The web app is not installed, only the project files were updated."
	fi
	if [ $rc -eq 0 ]; then
		if [ -f "${sysd_path}${webapp}" ]; then
			add_web_app_service
		fi
		configure_system_settings
	fi
	rm -rf "$rel_tmp"

	if [ $rc -ne 0 ]; then
		echo "The update failed part way through. Please check the files and try again."
		read -p "Press any key to continue"
		return 1
	fi

	# make the installer executable
	chmod +x "${cpath}installconfig.sh"
	printf '%s\n' "$rel_tag" > "${cpath}.release"
	echo -e $YEL"Updated to release $rel_tag"$DEF
	read -p "Press any key to restart the installer"
	exec bash "${cpath}installconfig.sh"
}

#Updates the installed files from the release already downloaded to $release_src_dir
update_installed_release()
{
	local src="${release_src_dir:-}" cur rc=0

	if [ ! -f "$src/accesspopup" ]; then
		echo "The downloaded release is not available."
		return 1
	fi
	cur="$(installed_release)"
	echo "Updating AccessPopup from ${cur:-unknown} to $rel_tag"
	echo "Updating ${script_path}${scriptname}"
	if ! install -m 755 "$src/accesspopup" "${script_path}${scriptname}.new" \
		|| ! mv -f "${script_path}${scriptname}.new" "${script_path}${scriptname}"; then
		rm -f "${script_path}${scriptname}.new"
		echo "Unable to update ${script_path}${scriptname}."
		read -p "Press any key to continue"
		return 1
	fi

	if [ -d "$web_path" ]; then
		echo "Updating the web app in $web_path"
		deploy_web "$src/ap_web" || rc=1
		if [ $rc -eq 0 ]; then
			if install_nginx && configure_nginx; then
				echo "The nginx port 80 forwarding has been updated."
			else
				echo "The nginx port 80 forwarding could not be updated."
			fi
		fi
	else
		echo "The web app is not installed, only the accesspopup script was updated."
	fi
	if [ $rc -ne 0 ]; then
		echo "The update failed part way through. The release marker was not changed."
		read -p "Press any key to continue"
		return 1
	fi

	add_service
	add_timer_service
	if [ -f "${sysd_path}${webapp}" ]; then
		add_web_app_service
	fi
	systemctl start "$timer" >/dev/null 2>&1
	systemctl daemon-reload >/dev/null 2>&1
	configure_system_settings
	printf '%s\n' "$rel_tag" > "${script_path}.release"
	echo -e $YEL"Updated to release $rel_tag"$DEF
	if [ "${auto_action:-0}" -ne 1 ]; then
		read -p "Press any key to continue"
	fi
	return 0
}

#Offers the full installer menu or exits after an automatic install or update
menu_or_exit()
{
	local choice
	auto_action=0
	echo ""
	read -p "Press Enter to exit, or type m and press Enter to open the full menu: " choice
	if [[ "$choice" =~ ^[Mm]$ ]]; then
		menu
	fi
}

#Updates the installed files from the release downloaded when the installer started
update_release_standalone()
{
	local cur ans

	cur="$(installed_release)"
	echo "Installed release:  ${cur:-unknown}"
	echo "Downloaded release: $rel_tag"
	if [ -n "$cur" ] && [ "$cur" = "$rel_tag" ]; then
		echo "Already up to date."
		read -p "Press any key to continue"
		return 0
	fi
	read -p "Update to $rel_tag now? [Y/n] " ans
	if [[ "$ans" =~ ^[Nn] ]]; then
		return 0
	fi
	update_installed_release
}

#Downloads the latest release and runs an install or update when the script was piped from curl
run_standalone()
{
	local cur ans rc=0

	if [ "$(id -u)" -ne 0 ]; then
		echo "The standalone installer must be run as root."
		echo "Use: curl -fsSL https://raw.githubusercontent.com/CodeWilliamson/AccessPopup/main/installconfig.sh | sudo bash"
		return 1
	fi

	echo -e $YEL"AccessPopup installer"$DEF
	echo "The latest published release will be checked on GitHub."
	release_info || { read -p "Press any key to continue"; return 1; }
	release_download || { read -p "Press any key to continue"; return 1; }

	#Use the downloaded release for the install, update and the full menu
	cpath="$rel_tmp/src/"
	release_src_dir="$rel_tmp/src"
	release_tmp_root="$rel_tmp"
	trap 'rm -rf "$release_tmp_root"' EXIT
	cd "$cpath" || { echo "Unable to enter the downloaded release."; return 1; }

	cur="$(installed_release)"
	if [ -f "${script_path}${scriptname}" ]; then
		echo "Installed release: ${cur:-unknown}"
		echo "Latest release:    $rel_tag"
		if [ -n "$cur" ] && [ "$cur" = "$rel_tag" ]; then
			echo "AccessPopup is already up to date."
			menu_or_exit
			return 0
		fi
		read -p "Update to $rel_tag now? [Y/n] " ans
		if [[ "$ans" =~ ^[Nn] ]]; then
			echo "Nothing has been changed."
			menu_or_exit
			return 0
		fi
		auto_action=1
		update_installed_release || rc=1
	else
		echo "AccessPopup is not installed."
		echo "Latest release: $rel_tag"
		read -p "Install AccessPopup $rel_tag now? [Y/n] " ans
		if [[ "$ans" =~ ^[Nn] ]]; then
			echo "Nothing has been changed."
			menu_or_exit
			return 0
		fi
		devices
		auto_action=1
		install_general || rc=1
	fi
	if [ $rc -eq 0 ]; then
		menu_or_exit
	fi
	return $rc
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
		nmcli con delete "$ap_profile_name" >/dev/null 2>&1
		nmcli con reload
		rm "${script_path}${scriptname}"
		rm "${conf_path}${conf_file}"
	fi
	rm -f "${script_path}.release"
	echo "Uninstalled AccessPopup Files"
	uninstall_web
}

uninstall_web()
{
	#Remove nginx site and NetworkManager dispatcher
	remove_nginx_site
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
	elif [ "$opt" = "DEV" ] ;then
		change_wifi_device
	fi
	clear
	menu
}

menu()
{
#selection menu
clear
until [ "$select" = "10" ]; do #set number to qty of menu options
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
	echo " 1 = Install AccessPopup"
	echo " 2 = Update AccessPopup"
	echo " 3 = Change the AccessPopups SSID or Password"
	echo " 4 = Change the AccessPopups IP Address"
	echo " 5 = Live Switch between: Known WIFI Network <> Access Point"
	echo " 6 = Setup a New WiFi Network or change the password to an existing Wifi Network"
	echo " 7 = Change Hostname"
	echo " 8 = Run $scriptname now. It will decide between a suitable WiFi network or AP."
	echo " 9 = Additional Menu"
	echo " 10 = Exit"
	echo ""
	echo "The Wifi status will be checked every 2 minutes. Switching will happen when a"
	echo "valid wifi network comes in and out of range."
	echo "use option 5 or the command: sudo $scriptname -a"
	echo "to activate a permanent access point, until the next reboot"
	echo "or when just sudo $scriptname is used."
	echo -e -n "\nSelect an Option:"
	read select
	case $select in
	1) clear ; go "INS" ;; #Install AccessPopup
	2) clear ; go "UPD" ;; #Update to latest release
	3) clear ; go "SSI" ;; #Set the AP SSID and Password
	4) clear ; go "IPA" ;; #Set the Access Points IP Address
	5) clear ; go "SWI" ;; #Live Switch: NW <> AP
	6) clear ; go "NWK" ;; #Connect to New WiFi Network
	7) clear ; go "HST" ;; #Change Hostname
	8) clear ; go "RUN" ;; #Run the AccessPopup script now
	9) clear ; go "MU2" ;; #Additional Menu
	10) clear ; exit ;;
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
	echo " 2 = Change the Webport (default 8080)"
	echo " 3 = When Wifi is Disabled: Automatically re-activate Y/N"
	echo " 4 = Uninstall $scriptname"
	echo " 5 = Configure the Web app (product name and logo)"
	echo " 6 = Change the WiFi Device (for example wlan1 USB adapter)"
	echo " 7 = Back to the Main menu"
	echo -e -n "\nSelect an Option:"
	read select
	case $select in
	1) clear ; go "WEB" ;; #Web Interface enable disable
	2) clear ; go "WPO" ;; #Web Port number
	3) clear ; go "DIS" ;; #Wifi reactivation options
	4) clear ; go "UNI" ;; #Uninstall AccessPopup
	5) clear ; go "CFG" ;; #Configure web app branding
	6) clear ; go "DEV" ;; #Change the WiFi device
	7) clear ; menu ;;
	*) Clear ; echo -e "Please select again\n";;
	esac
done
}

if [ "$standalone" = "y" ]; then
	run_standalone
	exit $?
fi
devices
menu
