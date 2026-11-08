# HammerTime Wi-Fi Provisioning Portal

Small Flask captive-portal UI for Raspberry Pi Wi-Fi provisioning. NetworkManager (`nmcli`) remains the authority for Wi-Fi configuration.

## Behaviour

- Scans nearby Wi-Fi networks using `nmcli`.
- User selects an SSID and enters its password.
- A candidate NetworkManager profile is created with autoconnect disabled.
- The candidate is activated and the portal waits for an IP address.
- On success, the candidate is renamed to the SSID and autoconnect is enabled.
- On failure, the candidate profile is deleted and the configured AP connection is reactivated.
- The UI never stores the Wi-Fi password itself.

## Install

```bash
sudo apt install -y network-manager python3-venv
sudo mkdir -p /opt/hammertime-wifi-portal
sudo cp -r . /opt/hammertime-wifi-portal/
cd /opt/hammertime-wifi-portal
sudo python3 -m venv venv
sudo ./venv/bin/pip install -r requirements.txt
sudo cp hammertime-wifi-portal.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hammertime-wifi-portal.service
```

The portal listens on port 8080 by default. Your AP/captive-portal mechanism (for example accesspopup) should redirect HTTP clients to this service.

## Configuration

The service file defaults to:

- `WIFI_INTERFACE=wlan0` (use `wlan1` or your adapter's name for a USB dongle)
- `AP_CONNECTION=AccessPopup`
- `WIFI_CONNECT_TIMEOUT=25`
- `PORTAL_PORT=8080`

`WIFI_INTERFACE` and `AP_CONNECTION` are driven by `wdev0` and `ap_profile_name` in `/etc/accesspopup.conf`. The environment values are used as a fallback when that file is unavailable. The AccessPopup installer keeps the service and the config file in step, including when you change the Wi-Fi device from the installer menu.

Change `AP_CONNECTION` to the exact NetworkManager connection name used by the Access Point if you have renamed it.

## External USB Wi-Fi adapters

Use the interface name reported by `nmcli device status` (for example `wlan1` or `wlx001122334455`). Set it in `/etc/accesspopup.conf` as `wdev0`, or use the installer's **Additional Menu > Change WiFi Device**. The portal, AccessPopup runtime checks, AP profile and captive-portal DNS all use that device.

## Important integration note

The application assumes NetworkManager owns the configured Wi-Fi device (`WIFI_INTERFACE`, or `wdev0` from `/etc/accesspopup.conf`) and that the AP already exists as a NetworkManager connection profile. The Flask app does not create or configure the AP itself. This keeps AP lifecycle separate from the provisioning UI and fits the existing HammerTime/accesspopup design.

If the AP is managed by a separate script instead of NetworkManager, replace `_deactivate_ap()` and `_reactivate_ap()` in `wifi.py` with calls to that script.
