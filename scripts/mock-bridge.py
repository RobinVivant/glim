#!/usr/bin/env python3
"""A pretend Hue bridge for developing Glim without touching real lights.

Speaks the parts of the local CLIP v2 API the app uses, over HTTPS with a
self-signed certificate named after its bridge id, like a real bridge:

    GET  /api/0/config                  who am I
    POST /api                           pairing (refuses twice, as if the link button was not pressed yet)
    GET  /clip/v2/resource              every resource
    GET  /clip/v2/resource/<type>/<id>  one resource
    PUT  /clip/v2/resource/<type>/<id>  light, grouped_light, scene recall
    GET  /eventstream/clip/v2           server-sent events for every change

Usage: scripts/mock-bridge.py [port]      (default 8443)
In the simulator, launch Glim with GLIM_BRIDGE_HOST=127.0.0.1:8443.
"""

import json
import queue
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BRIDGE_ID = "001788FFFE000001"
APP_KEY = "mock-application-key"

resources = {}
lock = threading.Lock()
listeners = []
pair_attempts = 0


def add(resource):
    resources[resource["id"]] = resource
    return resource["id"]


def make_light(name, color, brightness=60.0, on=False, mirek=366):
    device_id, light_id, zigbee_id = f"dev-{len(resources)}", f"light-{len(resources)}", f"zb-{len(resources)}"
    add({"id": device_id, "type": "device", "metadata": {"name": name},
         "services": [{"rid": light_id, "rtype": "light"}, {"rid": zigbee_id, "rtype": "zigbee_connectivity"}]})
    add({"id": zigbee_id, "type": "zigbee_connectivity", "owner": {"rid": device_id, "rtype": "device"},
         "status": "connected"})
    light = {"id": light_id, "type": "light", "owner": {"rid": device_id, "rtype": "device"},
             "metadata": {"name": name}, "on": {"on": on}, "dimming": {"brightness": brightness},
             "color_temperature": {"mirek": mirek, "mirek_valid": True,
                                   "mirek_schema": {"mirek_minimum": 153, "mirek_maximum": 500}}}
    if color:
        light["color"] = {"xy": {"x": 0.4573, "y": 0.41}}
    add(light)
    return device_id, light_id


def make_group(kind, name, members, scenes):
    group_id, grouped_id = f"{kind}-{len(resources)}", f"gl-{len(resources)}"
    child_type = "device" if kind == "room" else "light"
    children = [{"rid": device if kind == "room" else light, "rtype": child_type} for device, light in members]
    add({"id": group_id, "type": kind, "metadata": {"name": name}, "children": children,
         "services": [{"rid": grouped_id, "rtype": "grouped_light"}]})
    add({"id": grouped_id, "type": "grouped_light", "owner": {"rid": group_id, "rtype": kind},
         "on": {"on": False}, "dimming": {"brightness": 0.0}})
    for scene_name, brightness, look in scenes:
        action = {"on": {"on": True}, "dimming": {"brightness": brightness}}
        action.update({"color_temperature": {"mirek": look}} if isinstance(look, int) else {"color": {"xy": look}})
        add({"id": f"scene-{len(resources)}", "type": "scene", "metadata": {"name": scene_name},
             "group": {"rid": group_id, "rtype": kind}, "status": {"active": "inactive"},
             "actions": [{"target": {"rid": light, "rtype": "light"}, "action": action} for _, light in members]})
    refresh_group(grouped_id)
    return group_id


def build_home():
    red, blue, green = {"x": 0.64, "y": 0.33}, {"x": 0.17, "y": 0.12}, {"x": 0.25, "y": 0.6}
    standard = [("Bright", 100.0, 233), ("Concentrate", 100.0, 182), ("Relax", 56.0, 447), ("Nightlight", 5.0, 500)]
    living = [make_light("Sofa lamp", True, 70.0, True, 400), make_light("Floor lamp", True, 55.0, True, 400),
              make_light("TV strip", True, 40.0, False)]
    kitchen = [make_light("Counter", False, 100.0, False, 250), make_light("Ceiling", False, 100.0, False, 250)]
    bedroom = [make_light("Bedside left", True, 20.0, True, 480), make_light("Bedside right", True, 20.0, True, 480)]
    office = [make_light("Desk lamp", True, 85.0, False, 220)]
    make_group("room", "Living room", living, standard + [("Movie", 25.0, blue), ("Sunset", 60.0, red)])
    make_group("room", "Kitchen", kitchen, standard[:3])
    make_group("room", "Bedroom", bedroom, standard[2:] + [("Aurora", 45.0, green)])
    make_group("room", "Office", office, standard[:2])
    make_group("zone", "Downstairs", living + kitchen, [("Evening", 50.0, 400)])
    add({"id": "home", "type": "bridge_home", "children": [], "services": [{"rid": "gl-home", "rtype": "grouped_light"}]})
    add({"id": "gl-home", "type": "grouped_light", "owner": {"rid": "home", "rtype": "bridge_home"},
         "on": {"on": True}, "dimming": {"brightness": 50.0}})
    refresh_group("gl-home")


def lights_of(grouped_id):
    owner = resources[resources[grouped_id]["owner"]["rid"]]
    if owner["type"] == "bridge_home":
        return [r for r in resources.values() if r["type"] == "light"]
    found = []
    for child in owner["children"]:
        if child["rtype"] == "light":
            found.append(resources[child["rid"]])
        else:
            found += [resources[s["rid"]] for s in resources[child["rid"]]["services"] if s["rtype"] == "light"]
    return found


def refresh_group(grouped_id):
    """Recomputes a grouped light from its members; returns the changed fields, if any."""
    lit = [light for light in lights_of(grouped_id) if light["on"]["on"]]
    state = {"on": {"on": bool(lit)}}
    if lit:
        state["dimming"] = {"brightness": round(sum(l["dimming"]["brightness"] for l in lit) / len(lit), 2)}
    grouped = resources[grouped_id]
    changed = {key: value for key, value in state.items() if grouped.get(key) != value}
    grouped.update(changed)
    return changed


def merge(target, patch):
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(target.get(key), dict):
            merge(target[key], value)
        else:
            target[key] = value


def apply_to_light(light, body):
    patch = {key: body[key] for key in ("on", "dimming", "color", "color_temperature") if key in body}
    if "color" in patch and "color" not in light:
        del patch["color"]
    if "color" in patch:
        patch["color_temperature"] = {"mirek": None, "mirek_valid": False}
    elif "color_temperature" in patch:
        patch["color_temperature"] = {**patch["color_temperature"], "mirek_valid": True}
    merge(light, patch)
    return {"id": light["id"], "type": "light", "owner": light["owner"], **patch}


def handle_put(kind, resource_id, body):
    """Applies a write and returns the update events it causes."""
    changes = []
    target = resources.get(resource_id)
    if target is None or target["type"] != kind:
        return None
    if kind == "light":
        changes.append(apply_to_light(target, body))
    elif kind == "grouped_light":
        for light in lights_of(resource_id):
            changes.append(apply_to_light(light, body))
    elif kind == "scene" and "recall" in body:
        for other in resources.values():
            if other["type"] == "scene" and other["group"] == target["group"]:
                active = "static" if other["id"] == resource_id else "inactive"
                if other["status"]["active"] != active:
                    other["status"]["active"] = active
                    changes.append({"id": other["id"], "type": "scene", "status": {"active": active}})
        for action in target["actions"]:
            changes.append(apply_to_light(resources[action["target"]["rid"]], action["action"]))
    for grouped in [r for r in resources.values() if r["type"] == "grouped_light"]:
        changed = refresh_group(grouped["id"])
        if changed:
            changes.append({"id": grouped["id"], "type": "grouped_light", "owner": grouped["owner"], **changed})
    return changes


def broadcast(changes):
    if not changes:
        return
    event = [{"creationtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "id": str(uuid.uuid4()),
              "type": "update", "data": changes}]
    for listener in list(listeners):
        listener.put(event)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("hue-application-key") == APP_KEY:
            return True
        self.reply(403, {"errors": [{"description": "unauthorized"}], "data": []})
        return False

    def do_GET(self):
        if self.path == "/api/0/config":
            return self.reply(200, {"name": "Mock Bridge", "bridgeid": BRIDGE_ID, "modelid": "BSB002"})
        if not self.authorized():
            return
        if self.path == "/eventstream/clip/v2":
            return self.stream()
        parts = self.path.strip("/").split("/")
        with lock:
            if self.path == "/clip/v2/resource":
                return self.reply(200, {"errors": [], "data": list(resources.values())})
            if len(parts) == 5 and parts[4] in resources:
                return self.reply(200, {"errors": [], "data": [resources[parts[4]]]})
        self.reply(404, {"errors": [{"description": "not found"}], "data": []})

    def do_POST(self):
        global pair_attempts
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/api":
            return self.reply(404, [])
        pair_attempts += 1
        if pair_attempts <= 2:
            return self.reply(200, [{"error": {"type": 101, "address": "", "description": "link button not pressed"}}])
        self.reply(200, [{"success": {"username": APP_KEY, "clientkey": "00"}}])

    def do_PUT(self):
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        parts = self.path.strip("/").split("/")
        if len(parts) != 5:
            return self.reply(404, {"errors": [{"description": "not found"}], "data": []})
        with lock:
            changes = handle_put(parts[3], parts[4], body)
        if changes is None:
            return self.reply(404, {"errors": [{"description": "not found"}], "data": []})
        self.reply(200, {"errors": [], "data": [{"rid": parts[4], "rtype": parts[3]}]})
        broadcast(changes)

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        mine = queue.Queue()
        listeners.append(mine)
        try:
            self.wfile.write(b": hi\n\n")
            self.wfile.flush()
            count = 0
            while True:
                try:
                    event = mine.get(timeout=20)
                    count += 1
                    self.wfile.write(f"id: {int(time.time())}:{count}\ndata: {json.dumps(event)}\n\n".encode())
                except queue.Empty:
                    self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError):
            pass
        finally:
            listeners.remove(mine)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
    build_home()
    workdir = Path(tempfile.mkdtemp(prefix="mock-bridge-"))
    cert, key = workdir / "cert.pem", workdir / "key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
         "-keyout", str(key), "-out", str(cert), "-days", "30", "-subj", f"/C=NL/O=Philips Hue/CN={BRIDGE_ID}"],
        check=True, capture_output=True)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"mock bridge {BRIDGE_ID} on https://127.0.0.1:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
