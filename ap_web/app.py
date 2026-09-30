#!/usr/bin/env python3
import os
import re
import subprocess
import threading
import time
from flask import Flask, jsonify, render_template, request

from wifi import WiFiManager, WiFiError

app = Flask(__name__)

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
    return render_template("index.html", ap_name=AP_CONNECTION)


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


@app.errorhandler(404)
def not_found(_):
    # Useful when accesspopup/captive-portal detection requests a platform-specific URL.
    return render_template("index.html", ap_name=AP_CONNECTION), 200


if __name__ == "__main__":
    host = os.getenv("PORTAL_HOST", "0.0.0.0")
    port = int(os.getenv("PORTAL_PORT", "8080"))
    app.run(host=host, port=port, threaded=True)
