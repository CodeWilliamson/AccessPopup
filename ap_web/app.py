#!/usr/bin/env python3
import os
import re
import subprocess
import threading
import time
from flask import Flask, jsonify, render_template, request

from wifi import WiFiManager, WiFiError

app = Flask(__name__)
app.config["LOGO_FILENAME"] = "pi-logo.svg"
app.config["PRODUCT_NAME"] = "Raspberry Pi"
# Override via environment, e.g. FLASK_LOGO_FILENAME=my-logo.png
# Override via environment, e.g. FLASK_PRODUCT_NAME="My Product"
app.config.from_prefixed_env()

WIFI_INTERFACE = os.getenv("WIFI_INTERFACE", "wlan0")
AP_CONNECTION = os.getenv("AP_CONNECTION", "HammerTime AP")
CONNECT_TIMEOUT = int(os.getenv("WIFI_CONNECT_TIMEOUT", "25"))

wifi = WiFiManager(
    interface=WIFI_INTERFACE,
    ap_connection=AP_CONNECTION,
    connect_timeout=CONNECT_TIMEOUT,
)

_connect_lock = threading.Lock()
_connecting = False


def _set_connecting(value: bool):
    global _connecting
    _connecting = value


@app.get("/")
def index():
    return render_template("index.html", 
                           logo_filename=app.config["LOGO_FILENAME"], 
                           product_name=app.config["PRODUCT_NAME"])


@app.get("/api/networks")
def networks():
    try:
        return jsonify({"networks": wifi.scan()})
    except WiFiError as exc:
        return jsonify({"error": str(exc), "networks": []}), 500


@app.get("/api/status")
def status():
    return jsonify({
        "connecting": _connecting,
        **wifi.status(),
    })


@app.post("/api/connect")
def connect():
    global _connecting

    if not _connect_lock.acquire(blocking=False):
        return jsonify({"success": False, "error": "A connection attempt is already in progress."}), 409

    data = request.get_json(silent=True) or {}
    ssid = str(data.get("ssid", "")).strip()
    password = str(data.get("password", ""))

    if not ssid:
        _connect_lock.release()
        return jsonify({"success": False, "error": "Please select a Wi-Fi network."}), 400
    if not password.strip():
        _connect_lock.release()
        return jsonify({"success": False, "error": "Please enter a Wi-Fi password."}), 400

    try:
        _set_connecting(True)
        result = wifi.connect_and_commit(ssid, password)
        return jsonify(result)
    except WiFiError as exc:
        return jsonify({"success": False, "error": str(exc)}), 422
    finally:
        _set_connecting(False)
        _connect_lock.release()


@app.post("/api/rescan")
def rescan():
    try:
        return jsonify({"networks": wifi.scan(force=True)})
    except WiFiError as exc:
        return jsonify({"error": str(exc), "networks": []}), 500


UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def _invalid_uuid(uuid: str):
    if not UUID_RE.match(uuid):
        return jsonify({"success": False, "error": "Invalid network identifier."}), 400
    return None


@app.get("/api/profiles")
def profiles():
    try:
        return jsonify({"profiles": wifi.list_profiles()})
    except WiFiError as exc:
        return jsonify({"error": str(exc), "profiles": []}), 500


@app.post("/api/profiles/<uuid>/connect")
def connect_profile(uuid):
    if (error := _invalid_uuid(uuid)):
        return error
    if not _connect_lock.acquire(blocking=False):
        return jsonify({"success": False, "error": "A connection attempt is already in progress."}), 409

    try:
        _set_connecting(True)
        return jsonify(wifi.connect_profile(uuid))
    except WiFiError as exc:
        return jsonify({"success": False, "error": str(exc)}), 422
    finally:
        _set_connecting(False)
        _connect_lock.release()


@app.post("/api/profiles/<uuid>")
def update_profile(uuid):
    if (error := _invalid_uuid(uuid)):
        return error
    if _connect_lock.locked():
        return jsonify({"success": False, "error": "A connection attempt is in progress."}), 409

    data = request.get_json(silent=True) or {}
    password = str(data.get("password") or "")
    try:
        priority = int(data.get("priority", 0))
    except (TypeError, ValueError):
        priority = None
    if priority is None or not -999 <= priority <= 999:
        return jsonify({"success": False, "error": "Priority must be a whole number from -999 to 999."}), 400
    if password and not 8 <= len(password) <= 63:
        return jsonify({"success": False, "error": "Password must be 8 to 63 characters."}), 400

    try:
        wifi.update_profile(uuid, password or None, priority)
        return jsonify({"success": True})
    except WiFiError as exc:
        return jsonify({"success": False, "error": str(exc)}), 422


@app.delete("/api/profiles/<uuid>")
def delete_profile(uuid):
    if (error := _invalid_uuid(uuid)):
        return error
    if _connect_lock.locked():
        return jsonify({"success": False, "error": "A connection attempt is in progress."}), 409

    try:
        wifi.delete_profile(uuid)
        return jsonify({"success": True})
    except WiFiError as exc:
        return jsonify({"success": False, "error": str(exc)}), 422


@app.errorhandler(404)
def not_found(_):
    # Useful when accesspopup/captive-portal detection requests a platform-specific URL.
    return render_template("index.html", ap_name=AP_CONNECTION, logo_filename=app.config["LOGO_FILENAME"]), 200


if __name__ == "__main__":
    host = os.getenv("PORTAL_HOST", "0.0.0.0")
    port = int(os.getenv("PORTAL_PORT", "8080"))
    app.run(host=host, port=port, threaded=True)
