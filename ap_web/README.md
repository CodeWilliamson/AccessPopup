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

- `WIFI_INTERFACE=wlan0`
- `AP_CONNECTION=HammerTime AP`
- `WIFI_CONNECT_TIMEOUT=25`
- `PORTAL_PORT=8080`

Change `AP_CONNECTION` to the exact NetworkManager connection name used by the HammerTime AP.

## Important integration note

The application assumes NetworkManager owns `wlan0` and that the AP already exists as a NetworkManager connection profile. The Flask app does not create or configure the AP itself. This keeps AP lifecycle separate from the provisioning UI and fits the existing HammerTime/accesspopup design.

If the AP is managed by a separate script instead of NetworkManager, replace `_deactivate_ap()` and `_reactivate_ap()` in `wifi.py` with calls to that script.
