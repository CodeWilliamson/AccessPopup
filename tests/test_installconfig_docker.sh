#!/usr/bin/env bash
# End-to-end test of installconfig.sh inside a systemd Debian container.
#
# What it does:
#   1. Builds a Debian image (default debian:latest) with systemd,
#      NetworkManager, dnsmasq-base, nginx, polkit and the Python tooling the
#      installer expects.
#   2. Boots it under systemd (privileged, delegated cgroups).
#   3. Copies this checkout in and runs the installer non-interactively
#      (menu option 1), then checks the installed files, services and the
#      shared dnsmasq config, polkit rule and cmdline.txt quiet option.
#   4. Runs menu option 4 to change the AP IP and checks the configs follow.
#   5. Reinstalls from scratch to confirm the settings stay idempotent.
#   6. Runs focused edge-case checks: an existing quiet word, a polkit file
#      without a trailing newline, a custom device/IP, and repeated appends.
#
# Requirements:
#   - Docker with permission to run --privileged containers.
#   - Container internet access: apt on deb.debian.org:80 and pip on
#     pypi.org:443. The script checks this before doing anything expensive.
#   - A Debian 12+ base image (polkitd package name).
#
# There is no wireless device in the container, so the AccessPopup runtime
# script is expected to report "no Wifi device" and stop its timer. The test
# therefore checks the timer is enabled, not active, and does not require
# nginx to bind to the (not yet assigned) AP address.
#
# Usage:
#   tests/test_installconfig_docker.sh
#
# Environment:
#   BASE_IMAGE=debian:latest      Base image (debian:bookworm matches Pi OS 12)
#   TEST_IMAGE=accesspopup-install-test:local
#   USE_GITHUB_RELEASE=1          Let the installer download the published
#                                 release instead of using this checkout's ap_web
#   NO_CACHE=1                    Build the image without the Docker cache
#   REMOVE_IMAGE_ON_SUCCESS=1     Delete the built image after a passing run

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

base_image="${BASE_IMAGE:-debian:latest}"
image="${TEST_IMAGE:-accesspopup-install-test:local}"
container="${TEST_CONTAINER:-accesspopup-install-test-$(date +%s)-$$}"
use_github_release="${USE_GITHUB_RELEASE:-0}"
no_cache="${NO_CACHE:-0}"
remove_image_on_success="${REMOVE_IMAGE_ON_SUCCESS:-0}"

ap_conf="/etc/accesspopup.conf"
dnsmasq_conf="/etc/NetworkManager/dnsmasq-shared.d/captive-portal.conf"
polkit_file="/usr/share/polkit-1/rules.d/org.freedesktop.NetworkManager.rules"
cmdline_file="/boot/firmware/cmdline.txt"
polkit_rule='polkit.addRule(function(action, subject) { if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 && subject.user == "apu") { return polkit.Result.YES; } });'

tmp_dir="$(mktemp -d)" || { echo "Unable to create a temporary directory." >&2; exit 1; }
failures=0
container_created=0

log()  { printf '\n==> %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }
die()  { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

summary() {
	printf '\n'
	if [ "$failures" -eq 0 ]; then
		printf 'All checks passed.\n'
	else
		printf '%s check(s) failed.\n' "$failures"
	fi
}

on_exit() {
	local rc=$?
	trap - EXIT INT TERM

	if [ "$rc" -ne 0 ] || [ "$failures" -ne 0 ]; then
		if [ "$container_created" -eq 1 ] && docker inspect "$container" >/dev/null 2>&1; then
			printf '\nContainer kept for inspection: %s\n' "$container" >&2
			printf '  docker exec -it %s bash\n' "$container" >&2
			printf '  docker logs %s\n' "$container" >&2
			printf '  docker rm -f %s\n' "$container" >&2
		fi
		printf 'Logs kept in %s\n' "$tmp_dir" >&2
	else
		docker rm -f "$container" >/dev/null 2>&1 || true
		if [ "$remove_image_on_success" = 1 ]; then
			docker rmi "$image" >/dev/null 2>&1 || true
		fi
		rm -rf "$tmp_dir"
	fi
	exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

preflight() {
	command -v docker >/dev/null 2>&1 || die "docker is not installed."
	docker info >/dev/null 2>&1 || die "Cannot reach the Docker daemon."

	local f
	for f in installconfig.sh accesspopup accesspopup.conf ap_web/app.py ap_web/requirements.txt; do
		[ -f "$repo_root/$f" ] || die "Missing $repo_root/$f. Run this from an AccessPopup checkout."
	done

	log "Checking container internet access"
	if ! docker run --rm "$base_image" timeout 20 bash -c \
		'exec 3<>/dev/tcp/deb.debian.org/80 && exec 3<>/dev/tcp/pypi.org/443' >/dev/null 2>&1; then
		die "Containers on this Docker host cannot reach deb.debian.org:80 and pypi.org:443.
This test installs packages with apt and pip, so container egress is required.
On Docker Desktop, check Settings > Resources > Proxies, or reconnect Docker
with the VPN split-tunnelled/allowlisted. On Linux, check the daemon's network."
	fi
	pass "containers can reach apt and PyPI"
}

write_dockerfile() {
	cat > "$tmp_dir/Dockerfile" <<EOF
FROM ${base_image}
ENV DEBIAN_FRONTEND=noninteractive container=docker

# Keep service postinstalls from trying to start daemons during the build.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \\
 && chmod +x /usr/sbin/policy-rc.d

RUN apt-get update \\
 && apt-get -o Acquire::Retries=3 install -y --no-install-recommends \\
      systemd systemd-sysv udev dbus network-manager dnsmasq-base nginx iw \\
      python3 python3-venv python3-pip polkitd sudo curl ca-certificates \\
      iproute2 procps \\
 && rm -rf /var/lib/apt/lists/*

# Leave Docker's eth0 alone so the container keeps its internet access.
RUN mkdir -p /etc/NetworkManager/conf.d \\
 && printf '[keyfile]\nunmanaged-devices=interface-name:eth0\n' \\
      > /etc/NetworkManager/conf.d/99-test-unmanaged.conf

# Stand-in for the Raspberry Pi boot partition used by the quiet option.
RUN mkdir -p /boot/firmware \\
 && printf 'console=serial0,115200 console=tty1 root=PARTUUID=deadbeef-01 rootwait\n' \\
      > /boot/firmware/cmdline.txt

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
}

build_image() {
	write_dockerfile
	log "Building $image from $base_image"
	if [ "$no_cache" = 1 ]; then
		if ! docker build --no-cache -t "$image" "$tmp_dir" >"$tmp_dir/build.log" 2>&1; then
			tail -n 50 "$tmp_dir/build.log" >&2
			die "Docker image build failed. Full log: $tmp_dir/build.log"
		fi
	else
		if ! docker build -t "$image" "$tmp_dir" >"$tmp_dir/build.log" 2>&1; then
			tail -n 50 "$tmp_dir/build.log" >&2
			die "Docker image build failed. Full log: $tmp_dir/build.log"
		fi
	fi
	pass "image built"
}

start_container() {
	log "Starting the systemd container"
	container_created=1
	if ! docker run -d --name "$container" \
		--hostname accesspopup-test \
		--privileged \
		--cgroupns=host \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		--tmpfs /run \
		--tmpfs /run/lock \
		--tmpfs /tmp \
		"$image" /sbin/init >/dev/null; then
		die "Unable to start the container. This test needs permission to run --privileged containers."
	fi
}

wait_for_systemd() {
	local i state
	for ((i = 1; i <= 90; i++)); do
		state="$(docker exec "$container" systemctl is-system-running 2>/dev/null || true)"
		case "$state" in
			running|degraded)
				pass "systemd booted ($state)"
				return 0
				;;
		esac
		sleep 1
	done
	docker logs --tail 60 "$container" >&2 || true
	die "systemd did not finish booting inside the container."
}

wait_for_networkmanager() {
	local i
	docker exec "$container" systemctl start NetworkManager >/dev/null 2>&1 || true
	for ((i = 1; i <= 60; i++)); do
		if docker exec "$container" systemctl is-active --quiet NetworkManager \
			&& docker exec "$container" nmcli general status >/dev/null 2>&1; then
			pass "NetworkManager is active"
			return 0
		fi
		sleep 1
	done
	docker exec "$container" systemctl status NetworkManager --no-pager >&2 || true
	die "NetworkManager did not start inside the container."
}

copy_checkout() {
	log "Copying the checkout into the container"
	docker exec "$container" mkdir -p /opt/accesspopup \
		|| die "Unable to create /opt/accesspopup in the container."

	if ! COPYFILE_DISABLE=1 tar -C "$repo_root" \
		--exclude='.git' \
		--exclude='.github' \
		--exclude='venv' \
		--exclude='.venv' \
		--exclude='.DS_Store' \
		--exclude='__pycache__' \
		--exclude='*.pyc' \
		-cf - . | docker exec -i "$container" tar -C /opt/accesspopup -xf -; then
		die "Unable to copy the checkout into the container."
	fi

	docker exec "$container" chmod 755 \
		/opt/accesspopup/installconfig.sh \
		/opt/accesspopup/accesspopup \
		/opt/accesspopup/nw_setup_offline.sh \
		|| die "Unable to make the installer files executable."

	if [ "$use_github_release" != 1 ]; then
		# Use this checkout's ap_web rather than downloading the published
		# release. The installer falls back to the local files when the
		# GitHub API is unreachable.
		docker exec "$container" sh -c \
			'printf "\n127.0.0.1 api.github.com\n" >> /etc/hosts' \
			|| die "Unable to update the container hosts file."
		log "GitHub release lookup disabled; the checkout's ap_web will be used"
	fi
}

run_menu() {
	local label=$1 inputs=$2 limit=$3 log_file=$4 rc

	log "Running the installer: $label"
	printf '%s' "$inputs" | docker exec -i -e TERM=xterm "$container" \
		timeout "$limit" bash -c 'cd /opt/accesspopup && ./installconfig.sh' \
		>"$log_file" 2>&1
	rc=$?

	if [ "$rc" -eq 124 ]; then
		tail -n 60 "$log_file" >&2
		die "The installer timed out during: $label (wrong prompt answers?)"
	elif [ "$rc" -ne 0 ]; then
		tail -n 60 "$log_file" >&2
		die "The installer exited with status $rc during: $label"
	fi
	pass "installer command finished: $label"
}

run_install_menu() {
	local label=$1 log_file=$2
	# A leading blank answers devices() ("no WiFi device"), then 1 = install,
	# the product name, logo path, branding key press, install_web key press
	# and install_complete key press, then 10 = exit.
	run_menu "$label" $'\n1\n\n\n\n\n\n10\n' 900 "$log_file"

	if ! grep -q 'AccessPopup has been installed' "$log_file"; then
		tail -n 80 "$log_file" >&2
		die "The installer did not report a completed install during: $label"
	fi
	grep -E 'AccessPopup has been installed|Created the shared dnsmasq|Added the NetworkManager polkit|Added quiet|Unable to|could not' \
		"$log_file" | sed 's/^/    /' || true
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_shell() {
	local desc=$1 cmd=$2
	if docker exec "$container" bash -c "$cmd" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc"
	fi
}

assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then
		pass "$desc"
		return 0
	fi
	fail "$desc"
	printf '  expected:\n%s\n  actual:\n%s\n' "$expected" "$actual" | sed 's/^/    /'
}

assert_file_eq() {
	local desc=$1 file=$2 expected=$3 actual
	actual="$(docker exec "$container" cat "$file" 2>/dev/null || true)"
	assert_eq "$desc" "$expected" "$actual"
}

assert_contains() {
	local desc=$1 file=$2 needle=$3
	if docker exec "$container" grep -Fq -- "$needle" "$file" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc"
	fi
}

assert_line_count() {
	local desc=$1 file=$2 needle=$3 expected=$4 actual
	actual="$(docker exec "$container" grep -Fc -- "$needle" "$file" 2>/dev/null || true)"
	[ -n "$actual" ] || actual=0
	assert_eq "$desc" "$expected" "$actual"
}

assert_word_count() {
	local desc=$1 file=$2 word=$3 expected=$4 actual
	actual="$(docker exec "$container" sh -c \
		'grep -Eow "$1" "$2" 2>/dev/null | wc -l' _ "$word" "$file" | tr -d '[:space:]')"
	assert_eq "$desc" "$expected" "$actual"
}

assert_last_line() {
	local desc=$1 file=$2 expected=$3 actual
	actual="$(docker exec "$container" tail -n 1 "$file" 2>/dev/null || true)"
	assert_eq "$desc" "$expected" "$actual"
}

wait_for_webapp() {
	local i
	for ((i = 1; i <= 40; i++)); do
		if docker exec "$container" systemctl is-active --quiet ap_web_app.service; then
			pass "web app service is active"
			return 0
		fi
		sleep 1
	done
	fail "web app service is active"
	docker exec "$container" journalctl -u ap_web_app --no-pager -n 60 >&2 || true
	return 0
}

wait_for_http() {
	local i
	for ((i = 1; i <= 20; i++)); do
		if docker exec "$container" curl -fsS --max-time 5 -o /dev/null \
			http://127.0.0.1:8080/ >/dev/null 2>&1; then
			pass "web app answers on port 8080"
			return 0
		fi
		sleep 1
	done
	fail "web app answers on port 8080"
	return 0
}

check_install_artifacts() {
	assert_shell "accesspopup is installed and executable" '[ -x /usr/local/bin/accesspopup ]'
	assert_shell "accesspopup.conf is installed" '[ -f /etc/accesspopup.conf ]'
	assert_shell "AccessPopup.service is installed" '[ -f /etc/systemd/system/AccessPopup.service ]'
	assert_shell "AccessPopup.timer is installed" '[ -f /etc/systemd/system/AccessPopup.timer ]'
	assert_shell "ap_web_app.service is installed" '[ -f /etc/systemd/system/ap_web_app.service ]'
	assert_shell "apu user exists" 'id -u apu >/dev/null 2>&1'
	assert_shell "sudoers file is mode 440" '[ "$(stat -c %a /etc/sudoers.d/apu)" = 440 ]'
	assert_contains "sudoers allows nmcli" /etc/sudoers.d/apu /usr/bin/nmcli
	assert_shell "web app files are deployed" '[ -x /usr/local/bin/ap_web/app.py ]'
	assert_shell "web app virtualenv exists" '[ -x /usr/local/bin/ap_web/venv/bin/python ]'
	assert_shell "nginx site is linked" '[ -L /etc/nginx/sites-enabled/accesspopup ]'
	assert_shell "nginx dispatcher is installed" '[ -x /etc/NetworkManager/dispatcher.d/90-accesspopup-nginx ]'
	assert_shell "AccessPopup.timer is enabled" 'systemctl is-enabled --quiet AccessPopup.timer'
	assert_shell "web app service is enabled" 'systemctl is-enabled --quiet ap_web_app.service'
}

check_portal_settings() {
	local ip=$1
	assert_file_eq "dnsmasq shared config uses $ip" "$dnsmasq_conf" \
		"$(printf 'interface=wlan0\nlisten-address=%s\naddress=/#/%s' "$ip" "$ip")"
	assert_shell "dnsmasq accepts the shared config" "/usr/sbin/dnsmasq --test -C $dnsmasq_conf"
	assert_contains "nginx site listens on $ip" /etc/nginx/sites-available/accesspopup "listen ${ip}:80;"
	assert_shell "nginx configuration test passes" 'nginx -t'
}

check_polkit() {
	assert_line_count "polkit rule is appended once" "$polkit_file" 'subject.user == "apu"' 1
	assert_last_line "polkit rule is the last line" "$polkit_file" "$polkit_rule"
	assert_contains "polkit rule targets NetworkManager" "$polkit_file" \
		'action.id.indexOf("org.freedesktop.NetworkManager.")'
}

check_cmdline() {
	assert_shell "cmdline.txt is a single line" '[ "$(wc -l < /boot/firmware/cmdline.txt)" -eq 1 ]'
	assert_word_count "cmdline.txt contains quiet once" "$cmdline_file" quiet 1
	assert_shell "cmdline.txt ends with quiet" 'grep -Eq " quiet$" /boot/firmware/cmdline.txt'
	assert_shell "cmdline.txt keeps existing arguments" 'grep -Fq rootwait /boot/firmware/cmdline.txt'
}

# ---------------------------------------------------------------------------
# Edge cases, run inside the container against the real functions
# ---------------------------------------------------------------------------

write_edge_cases() {
	cat > "$tmp_dir/edge-cases.sh" <<'EDGE'
#!/bin/bash
# Focused checks for the three new settings. The functions are read from the
# installer without executing it, then driven with test paths.
set -uo pipefail

src=/opt/accesspopup/installconfig.sh
fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
eq() {
	if [ "$2" = "$3" ]; then
		pass "$1"
	else
		fail "$1"
		printf '  expected: %q\n  actual:   %q\n' "$2" "$3"
	fi
}

for fn in ap_ip_address add_dnsmasq_shared add_polkit_rule add_cmdline_quiet; do
	eval "$(sed -n "/^${fn}()/,/^}/p" "$src")"
done

tmp="$(mktemp -d)" || exit 1
boot=/boot/firmware/cmdline.txt
cp "$boot" "$tmp/cmdline.orig"
trap 'cp "$tmp/cmdline.orig" "$boot"; rm -rf "$tmp"' EXIT

# --- dnsmasq: custom device and AP IP, and safe to rewrite
conf_path="$tmp/etc/"
conf_file=accesspopup.conf
mkdir -p "$conf_path"
printf "ap_ip='10.0.60.1/24'\n" > "$conf_path$conf_file"
wdev0=wlan7
dnsmasq_shared_dir="$tmp/dnsmasq-shared.d"
dnsmasq_shared_conf="$dnsmasq_shared_dir/captive-portal.conf"
add_dnsmasq_shared >/dev/null
eq "dnsmasq honours a custom device and AP IP" \
	"$(printf 'interface=wlan7\nlisten-address=10.0.60.1\naddress=/#/10.0.60.1')" \
	"$(cat "$dnsmasq_shared_conf")"
before="$(cat "$dnsmasq_shared_conf")"
add_dnsmasq_shared >/dev/null
eq "dnsmasq rewrite is stable" "$before" "$(cat "$dnsmasq_shared_conf")"

# --- polkit: appends after a file with no trailing newline, exactly once
polkit_nm_rules="$tmp/polkit/NetworkManager.rules"
mkdir -p "$(dirname "$polkit_nm_rules")"
printf 'polkit.addRule(function(action, subject) {\n});' > "$polkit_nm_rules"
add_polkit_rule >/dev/null
add_polkit_rule >/dev/null
eq "polkit appends on a new line" \
	"$(printf 'polkit.addRule(function(action, subject) {\n});\npolkit.addRule(function(action, subject) { if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 && subject.user == "apu") { return polkit.Result.YES; } });')" \
	"$(cat "$polkit_nm_rules")"
eq "polkit rule is not duplicated" "1" "$(grep -Fc 'subject.user == "apu"' "$polkit_nm_rules")"

# --- cmdline: trailing spaces trimmed, quiet added once, single line kept
printf 'console=tty1 root=/dev/mmcblk0p2 rootwait   ' > "$boot"
add_cmdline_quiet >/dev/null
eq "cmdline quiet is added" \
	"console=tty1 root=/dev/mmcblk0p2 rootwait quiet" "$(cat "$boot")"
eq "cmdline stays a single line" "1" "$(wc -l < "$boot" | tr -d '[:space:]')"
add_cmdline_quiet >/dev/null
eq "cmdline quiet is not duplicated" "1" "$(grep -Eow quiet "$boot" | wc -l | tr -d '[:space:]')"

exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
EDGE
}

run_edge_cases() {
	write_edge_cases
	log "Running edge-case checks"
	docker cp "$tmp_dir/edge-cases.sh" "$container:/opt/edge-cases.sh" \
		|| die "Unable to copy the edge-case script into the container."
	if docker exec "$container" bash /opt/edge-cases.sh; then
		pass "edge-case suite"
	else
		fail "edge-case suite"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	preflight
	build_image
	start_container
	wait_for_systemd
	wait_for_networkmanager
	copy_checkout

	assert_shell "nmcli can talk to NetworkManager" 'nmcli general status >/dev/null'

	run_install_menu "fresh install" "$tmp_dir/install-1.log"
	check_install_artifacts
	check_portal_settings 192.168.50.1
	check_polkit
	check_cmdline
	wait_for_webapp
	wait_for_http

	# Menu 4: choose 192.168., then hosts 60 and 1 -> 192.168.60.1
	# (the leading blank answers the startup devices() prompt)
	run_menu "IP change" $'\n4\n1\n60\n1\n\n10\n' 180 "$tmp_dir/ip-change.log"
	assert_contains "ap_ip follows the IP change" "$ap_conf" "ap_ip='192.168.60.1/24'"
	assert_contains "ap_gate follows the IP change" "$ap_conf" "ap_gate='192.168.60.254'"
	check_portal_settings 192.168.60.1
	check_polkit
	check_cmdline

	# A reinstall resets /etc/accesspopup.conf from the checkout and must not
	# duplicate the polkit rule or the quiet argument.
	log "Forcing a reinstall to check idempotency"
	docker exec "$container" rm -f /usr/local/bin/accesspopup \
		|| die "Unable to remove the installed accesspopup script."
	run_install_menu "reinstall" "$tmp_dir/install-2.log"
	check_install_artifacts
	check_portal_settings 192.168.50.1
	check_polkit
	check_cmdline
	wait_for_webapp
	wait_for_http

	run_edge_cases

	summary
	if [ "$failures" -ne 0 ]; then
		exit 1
	fi
}

main "$@"
