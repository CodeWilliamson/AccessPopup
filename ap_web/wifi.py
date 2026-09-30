#!/usr/bin/env python3
import re
import subprocess
import time
from typing import Dict, List, Optional


class WiFiError(Exception):
    pass


class WiFiManager:
    """NetworkManager-backed Wi-Fi provisioning.

    A candidate connection profile is created before testing. If activation and
    IP configuration succeed, the profile is retained. Otherwise it is deleted
    and the configured AP profile is reactivated.
    """

    CANDIDATE_NAME = "HammerTime WiFi Candidate"

    def __init__(self, interface: str, ap_connection: str, connect_timeout: int = 25):
        self.interface = interface
        self.ap_connection = ap_connection
        self.connect_timeout = connect_timeout

    def _run(self, *args, timeout=15, check=True):
        try:
            result = subprocess.run(
                ["nmcli", *args],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                check=False,
            )
        except FileNotFoundError as exc:
            raise WiFiError("NetworkManager (nmcli) is not installed.") from exc
        except subprocess.TimeoutExpired as exc:
            raise WiFiError("NetworkManager command timed out.") from exc

        if check and result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip() or "NetworkManager command failed."
            raise WiFiError(message)
        return result

    @staticmethod
    def _decode_nmcli(value: str) -> str:
        # nmcli --terse escapes ':' as \: and '\\' as '\\\\'.
        out = []
        escaped = False
        for char in value:
            if escaped:
                out.append(char)
                escaped = False
            elif char == "\\":
                escaped = True
            else:
                out.append(char)
        if escaped:
            out.append("\\")
        return "".join(out)

    @staticmethod
    def _split_terse(line: str) -> List[str]:
        # Split on unescaped ':' and decode each field.
        fields, current, escaped = [], [], False
        for char in line:
            if escaped:
                current.append(char)
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == ":":
                fields.append("".join(current))
                current = []
            else:
                current.append(char)
        fields.append("".join(current))
        return fields

    def list_profiles(self) -> List[Dict]:
        result = self._run("-t", "-f", "UUID,NAME,TYPE,AUTOCONNECT-PRIORITY,ACTIVE", "connection", "show")
        profiles = []
        for line in result.stdout.splitlines():
            parts = self._split_terse(line)
            if len(parts) != 5:
                continue
            uuid, name, conn_type, priority, active = parts
            if conn_type != "802-11-wireless" or name in (self.ap_connection, self.CANDIDATE_NAME):
                continue
            if self._is_access_point(uuid):
                continue
            try:
                priority_value = int(priority)
            except ValueError:
                priority_value = 0
            profiles.append({"uuid": uuid, "name": name, "priority": priority_value, "active": active == "yes"})
        return sorted(profiles, key=lambda p: (-p["priority"], p["name"].lower()))

    def _is_access_point(self, uuid: str) -> bool:
        result = self._run("-g", "802-11-wireless.mode", "connection", "show", "uuid", uuid, check=False)
        return result.stdout.strip() == "ap"

    def _get_profile(self, uuid: str) -> Dict:
        for profile in self.list_profiles():
            if profile["uuid"] == uuid:
                return profile
        raise WiFiError("Saved network not found.")

    def connect_profile(self, uuid: str) -> Dict:
        profile = self._get_profile(uuid)
        self._deactivate_ap()
        try:
            self._run(
                "connection", "up", "uuid", uuid,
                "ifname", self.interface,
                timeout=self.connect_timeout,
            )
            ip = self._wait_for_ip()
            if not ip:
                raise WiFiError("The network was found, but the Pi did not receive an IP address.")
            return {
                "success": True,
                "ssid": profile["name"],
                "ip": ip,
                "message": "Wi-Fi connected successfully. The access point can now close.",
            }
        except Exception as exc:
            # Keep the saved profile; only restore the AP.
            self._run("connection", "down", "uuid", uuid, check=False)
            self._reactivate_ap()
            if isinstance(exc, WiFiError):
                raise
            raise WiFiError(str(exc)) from exc

    def update_profile(self, uuid: str, password: Optional[str], priority: int):
        self._get_profile(uuid)
        args = ["connection", "modify", "uuid", uuid, "connection.autoconnect-priority", str(priority)]
        if password:
            args += ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password]
        self._run(*args)

    def delete_profile(self, uuid: str):
        self._get_profile(uuid)
        self._run("connection", "delete", "uuid", uuid)

    def scan(self, force: bool = False) -> List[Dict]:
        args = [
            "-t", "-f", "SSID,SIGNAL,SECURITY,IN-USE",
            "device", "wifi", "list",
            "ifname", self.interface,
        ]
        if force:
            self._run("device", "wifi", "rescan", "ifname", self.interface, timeout=20)

        result = self._run(*args)
        networks = {}

        for line in result.stdout.splitlines():
            parts = line.split(":", 3)
            if len(parts) != 4:
                continue
            ssid_raw, signal, security_raw, in_use = parts
            ssid = self._decode_nmcli(ssid_raw)
            security = self._decode_nmcli(security_raw)
            if not ssid:
                continue  # Hidden networks are not useful in the normal picker.

            try:
                signal_value = int(signal)
            except ValueError:
                signal_value = 0

            # De-duplicate SSIDs, keeping the strongest AP.
            existing = networks.get(ssid)
            item = {
                "ssid": ssid,
                "signal": signal_value,
                "security": security or "Open",
                "in_use": in_use == "*",
            }
            if existing is None or signal_value > existing["signal"]:
                networks[ssid] = item

        return sorted(networks.values(), key=lambda n: (-n["signal"], n["ssid"].lower()))

    def status(self) -> Dict:
        result = self._run(
            "-t", "-f", "GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS",
            "device", "show", self.interface,
            check=False,
        )
        state = ""
        connection = ""
        ip = ""
        for line in result.stdout.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            value = self._decode_nmcli(value)
            if key == "GENERAL.STATE":
                state = value
            elif key == "GENERAL.CONNECTION":
                connection = value
            # nmcli reports addresses as IP4.ADDRESS[1], IP4.ADDRESS[2], ...
            elif key.startswith("IP4.ADDRESS") and value and not ip:
                ip = value

        return {"state": state, "connection": connection, "ip": ip}

    def _create_candidate(self, ssid: str, password: str, name: str):
        # Remove any stale candidate left by a crashed portal process.
        self._delete_connection(name)

        args = [
            "connection", "add",
            "type", "wifi",
            "ifname", self.interface,
            "con-name", name,
            "ssid", ssid,
        ]
        self._run(*args)

        if password:
            self._run(
                "connection", "modify", name,
                "wifi-sec.key-mgmt", "wpa-psk",
                "wifi-sec.psk", password,
            )
        else:
            self._run(
                "connection", "modify", name,
                "wifi-sec.key-mgmt", "",
            )

        # Candidate should never automatically reconnect while it is being tested.
        self._run("connection", "modify", name, "connection.autoconnect", "no")

    def _delete_connection(self, name: str):
        self._run("connection", "delete", name, check=False)

    def _delete_profiles_named(self, name: str):
        # Delete by UUID so every same-named profile is removed, not just the first match.
        result = self._run("-t", "-f", "UUID,NAME", "connection", "show", check=False)
        for line in result.stdout.splitlines():
            if ":" not in line:
                continue
            uuid, raw_name = line.split(":", 1)
            if self._decode_nmcli(raw_name) == name:
                self._run("connection", "delete", "uuid", uuid, check=False)

    def _activate(self, name: str):
        return self._run(
            "connection", "up", name,
            "ifname", self.interface,
            timeout=self.connect_timeout,
        )

    def _deactivate_ap(self):
        if self.ap_connection:
            self._run("connection", "down", self.ap_connection, check=False, timeout=15)

    def _reactivate_ap(self):
        if not self.ap_connection:
            return
        # Give NetworkManager a moment to release wlan0 after the failed client attempt.
        time.sleep(1)
        self._run("connection", "up", self.ap_connection, "ifname", self.interface, check=False, timeout=20)

    def _wait_for_ip(self) -> Optional[str]:
        deadline = time.monotonic() + self.connect_timeout
        while time.monotonic() < deadline:
            result = self._run(
                "-t", "-f", "GENERAL.STATE,IP4.ADDRESS",
                "device", "show", self.interface,
                check=False,
            )
            state = ""
            ip = ""
            for line in result.stdout.splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                value = self._decode_nmcli(value)
                if key == "GENERAL.STATE":
                    state = value
                # nmcli reports addresses as IP4.ADDRESS[1], IP4.ADDRESS[2], ...
                elif key.startswith("IP4.ADDRESS") and value and not ip:
                    ip = value
            if ip and ("connected" in state.lower() or state.startswith("100")):
                return ip.split("/")[0]
            time.sleep(1)
        return None

    def connect_and_commit(self, ssid: str, password: str) -> Dict:
        # Restrict the generated profile name to a stable, harmless identifier.
        candidate = self.CANDIDATE_NAME
        saved_name = ssid

        self._deactivate_ap()
        try:
            self._create_candidate(ssid, password, candidate)
            self._activate(candidate)
            ip = self._wait_for_ip()
            if not ip:
                raise WiFiError("The network was found, but the Pi did not receive an IP address.")

            # Rename the successful profile to the SSID and enable normal autoconnect.
            # The profile is already retained by NetworkManager; we now make it the
            # normal persistent connection.
            if saved_name not in (candidate, self.ap_connection):
                self._delete_profiles_named(saved_name)
            self._run("connection", "modify", candidate, "connection.id", saved_name)
            self._run("connection", "modify", saved_name, "connection.autoconnect", "yes")

            return {
                "success": True,
                "ssid": ssid,
                "ip": ip,
                "message": "Wi-Fi connected successfully. The access point can now close.",
            }
        except Exception as exc:
            self._delete_connection(candidate)
            self._reactivate_ap()
            if isinstance(exc, WiFiError):
                raise
            raise WiFiError(str(exc)) from exc
