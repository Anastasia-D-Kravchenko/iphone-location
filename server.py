#!/usr/bin/env python3
"""Local web app that sets a connected iPhone's / Apple Watch's location through Xcode's devicectl.

python3 server.py [port] [--lan]
  --lan  also listen on the Wi-Fi network so the iPhone app can reach it (needs the token).
"""
import hmac
import json
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

args = [a for a in sys.argv[1:] if not a.startswith("--")]
LAN = "--lan" in sys.argv
PORT = int(args[0]) if args else 8765
HOST = "0.0.0.0" if LAN else "127.0.0.1"
HERE = Path(__file__).resolve().parent
DEVICE_ID = re.compile(r"^[0-9A-Fa-f-]{20,40}$")
PLATFORMS = {"iOS": "iphone", "watchOS": "watch"}

TOKEN_FILE = HERE / ".token"
if not TOKEN_FILE.exists():
    TOKEN_FILE.write_text(secrets.token_urlsafe(24))
    TOKEN_FILE.chmod(0o600)
TOKEN = TOKEN_FILE.read_text().strip()

# Active fake locations: device id -> {"lat", "lon", "until"} (until = unix time, or None for no limit).
# Kept on disk so a server restart still restores the real location on time.
HOLDS_FILE = HERE / ".holds.json"
holds_lock = threading.Lock()
try:
    holds = json.loads(HOLDS_FILE.read_text())
except (OSError, json.JSONDecodeError):
    holds = {}


def save_holds():
    HOLDS_FILE.write_text(json.dumps(holds))


def expiry_loop():
    """Puts devices back to their real location when their hold time runs out."""
    while True:
        time.sleep(5)
        now = time.time()
        with holds_lock:
            due = [d for d, h in holds.items() if h.get("until") and h["until"] <= now and h.get("retry_at", 0) <= now]
        for device in due:
            ok, out = run(["device", "simulate", "location", "clear", "--device", device])
            with holds_lock:
                if ok:
                    holds.pop(device, None)
                    print(f"hold ended: {device} back to real location", file=sys.stderr)
                elif device in holds:
                    holds[device]["retry_at"] = time.time() + 30
                    print(f"hold end failed for {device}: {explain(out)}", file=sys.stderr)
                save_holds()


def run(args, timeout=90):
    try:
        p = subprocess.run(["xcrun", "devicectl", *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "devicectl timed out"
    out = (p.stdout + p.stderr).strip()
    return p.returncode == 0, out


def list_devices():
    try:
        p = subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", "-"],
            capture_output=True, text=True, timeout=40,
        )
        data = json.loads(p.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return []
    devices = []
    for d in data.get("result", {}).get("devices", []):
        hw = d.get("hardwareProperties", {})
        kind = PLATFORMS.get(hw.get("platform"))
        if not kind or hw.get("reality") == "simulated":
            continue
        devices.append({
            "id": hw.get("udid") or d.get("identifier"),
            "name": d.get("deviceProperties", {}).get("name", kind),
            "kind": kind,
            "paired": d.get("connectionProperties", {}).get("pairingState") == "paired",
            "movable": True,
        })
    devices.sort(key=lambda d: d["kind"] != "iphone")
    return devices + fixed_devices()


def fixed_devices():
    """The Mac and AirPods, shown in the list but never movable."""
    out = []
    try:
        name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True, timeout=5).stdout.strip()
        out.append({"id": "mac", "name": name or "Mac", "kind": "mac", "paired": True, "movable": False,
                    "note": "macOS has no way to fake its location"})
    except subprocess.TimeoutExpired:
        pass
    try:
        p = subprocess.run(["system_profiler", "SPBluetoothDataType", "-json"], capture_output=True, text=True, timeout=20)
        bt = json.loads(p.stdout)["SPBluetoothDataType"][0]
    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, IndexError):
        return out
    seen = set()
    for group in ("device_connected", "device_not_connected"):
        for item in bt.get(group, []):
            for name in item:
                if "AirPods" in name and name not in seen:
                    seen.add(name)
                    out.append({"id": f"airpods-{len(seen)}", "name": name, "kind": "airpods", "paired": True,
                                "movable": False, "note": "No GPS: Find My shows them where their iPhone is"})
    return out


def explain(out):
    if "Developer Mode is turned off" in out:
        return "Developer Mode is off on this device: Settings > Privacy & Security > Developer Mode."
    if "must be paired" in out or "unpaired" in out:
        return "Not paired with this Mac. For a Watch: plug the iPhone in, open Xcode > Window > Devices and Simulators."
    if "rejected the Bluetooth" in out or "could not be established" in out:
        return "Can't reach this device. Unlock it, keep it close to the Mac and on the same Wi-Fi."
    if "usage assertion" in out or "disconnected immediately" in out:
        return "The Mac can only reach this device over the cable or the same Wi-Fi, not over mobile data or Tailscale."
    if "locked" in out.lower():
        return "Unlock the device and try again."
    lines = [l for l in out.splitlines() if l.strip()]
    return lines[-1] if lines else "Unknown error"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def is_local(self):
        return self.client_address[0] in ("127.0.0.1", "::1", "::ffff:127.0.0.1")

    def authorized(self):
        # The browser page on this Mac needs no token; anything from the network does.
        if self.is_local():
            return True
        return hmac.compare_digest(self.headers.get("X-Token", ""), TOKEN)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            if not self.is_local():
                return self.send_json(403, {"error": "open the page on the Mac itself"})
            body = (HERE / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/devices":
            if not self.authorized():
                return self.send_json(401, {"error": "wrong token"})
            self.send_json(200, {"devices": list_devices()})
        elif self.path == "/api/status":
            if not self.authorized():
                return self.send_json(401, {"error": "wrong token"})
            with holds_lock:
                current = {d: {k: h[k] for k in ("lat", "lon", "until")} for d, h in holds.items()}
            self.send_json(200, {"holds": current, "now": time.time()})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        # Only accept browser requests from this page, not from other websites.
        origin = self.headers.get("Origin")
        if origin and origin not in (f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"):
            return self.send_json(403, {"ok": False, "error": "forbidden origin"})
        if not self.authorized():
            return self.send_json(401, {"ok": False, "error": "wrong token"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self.send_json(400, {"ok": False, "error": "bad request"})

        device = str(req.get("device", ""))
        if not DEVICE_ID.match(device):
            return self.send_json(400, {"ok": False, "error": "no device selected"})

        if self.path == "/api/set":
            try:
                lat, lon = float(req["lat"]), float(req["lon"])
            except (KeyError, TypeError, ValueError):
                return self.send_json(400, {"ok": False, "error": "bad coordinates"})
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                return self.send_json(400, {"ok": False, "error": "coordinates out of range"})
            minutes = minutes_from(req)
            ok, out = run(["device", "simulate", "location", "coordinate", "--device", device,
                           "--latitude", f"{lat:.6f}", "--longitude", f"{lon:.6f}"])
            if ok:
                with holds_lock:
                    holds[device] = {"lat": lat, "lon": lon, "until": time.time() + minutes * 60 if minutes else None}
                    save_holds()
        elif self.path == "/api/extend":
            minutes = minutes_from(req)
            with holds_lock:
                hold = holds.get(device)
                if not hold:
                    return self.send_json(200, {"ok": False, "error": "This device has no fake location now"})
                # No minutes means "no limit"; otherwise add time to whatever is left.
                hold["until"] = max(time.time(), hold.get("until") or time.time()) + minutes * 60 if minutes else None
                hold.pop("retry_at", None)
                save_holds()
            ok, out = True, ""
        elif self.path == "/api/clear":
            ok, out = run(["device", "simulate", "location", "clear", "--device", device])
            if ok:
                with holds_lock:
                    holds.pop(device, None)
                    save_holds()
        else:
            return self.send_json(404, {"ok": False, "error": "not found"})

        with holds_lock:
            until = holds.get(device, {}).get("until")
        self.send_json(200, {"ok": ok, "error": None if ok else explain(out), "until": until, "log": out[-2000:]})


def minutes_from(req):
    """Hold time in minutes from the request; 0 / missing = no time limit."""
    try:
        return max(0.0, min(float(req.get("minutes") or 0), 24 * 60))
    except (TypeError, ValueError):
        return 0.0


if __name__ == "__main__":
    threading.Thread(target=expiry_loop, daemon=True).start()
    print(f"Location server on http://{HOST}:{PORT}  (page: http://127.0.0.1:{PORT}, Ctrl+C to stop)")
    if LAN:
        print("LAN mode: the iPhone app connects with the token from .token")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
