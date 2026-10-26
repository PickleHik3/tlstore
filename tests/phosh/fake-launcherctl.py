#!/usr/bin/env python3
"""fake-launcherctl.py - a stand-in for the launcher's LauncherCtl HTTP server, for the phosh tests.

Serves the routes docs/PHOSH.md "Bridges" uses (API doc: LauncherCtl_API.md of the launcher):
  GET  /v1/battery /v1/network /v1/rotation      POST /v1/rotation {"lock": bool}
  POST /v1/notify (a message with an id, or {"close": id})
  POST /v1/vibrate /v1/torch /v1/settings/open
  GET  /v1/watch    SSE: ": keepalive", then one event per topic (battery, network, rotation),
                    then one per change; ": keepalive" every 15 s (--keepalive to change it).
Every call is recorded in --log (a JSON array, rewritten on each call). A call is marked
"unexpected" when it has a bad or missing bearer token, an unknown route or a bad body.

A second, control port (127.0.0.1, written to $HOME/.launcherctl/control) is for the test:
  GET  /calls            the recorded calls        POST /reset            clear the log
  POST /state/<topic>    {json}: replace battery|network|rotation state (no event)
  POST /push/<topic>     {json}: replace the state and send the event on every open stream
  GET  /state            all three topics          GET  /watchers         number of open streams

Usage: fake-launcherctl.py --home DIR --log FILE [--token T] [--keepalive SECONDS]
Writes DIR/.launcherctl/endpoint (http://127.0.0.1:PORT), token and control, prints "ready" on
stdout once both ports listen. Python 3 standard library only.
"""
import argparse
import json
import os
import queue
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOPICS = ("battery", "network", "rotation")
MAX_WATCHERS = 4

STATE = {
    "battery": {"health": "GOOD", "percentage": 87, "plugged": "UNPLUGGED",
                "status": "DISCHARGING", "temperature": 29.5, "current": -312000},
    "network": {"ok": True,
                "wifi": {"enabled": True, "connected": True, "ssid": "Home", "signal_level": 3},
                "cellular": {"present": True, "signal_level": 4, "network_type": "LTE",
                             "data_enabled": True},
                "reasons": {}},
    "rotation": {"ok": True, "orientation": "portrait", "rotation": 0, "lock": False},
}
lock = threading.RLock()
calls = []
watchers = []          # queues, one per open /v1/watch stream
args = None


def write_log():
    tmp = args.log + ".tmp"
    with open(tmp, "w") as f:
        json.dump(calls, f, indent=1)
    os.replace(tmp, args.log)


def record(method, path, body, status, unexpected, note=""):
    entry = {"n": 0, "time": round(time.time(), 3), "method": method, "path": path,
             "body": body, "status": status, "unexpected": unexpected}
    if note:
        entry["note"] = note
    with lock:
        entry["n"] = len(calls) + 1
        calls.append(entry)
        write_log()


def broadcast(topic):
    with lock:
        data = json.dumps(STATE[topic], separators=(",", ":"))
        frame = "event: %s\ndata: %s\n\n" % (topic, data)
        for q in list(watchers):
            q.put(frame)


class Base(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Api(Base):
    def authorized(self):
        auth = self.headers.get("Authorization", "")
        return auth == "Bearer " + args.token or self.headers.get("X-Api-Key", "") == args.token

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if not raw:
            return {}, True
        try:
            body = json.loads(raw)
            return body, isinstance(body, dict)
        except ValueError:
            return {}, False

    def reject(self, method, path, body, status, note):
        record(method, path, body, status, True, note)
        self.send_json(status, {"ok": False, "error": "bad_request" if status == 400 else note})

    def handle_any(self, method):
        path = self.path.split("?")[0]
        body, body_ok = self.read_body() if method == "POST" else ({}, True)
        if path == "/":
            return self.send_json(200, {"ok": True})
        if not self.authorized():
            record(method, path, body, 401, True, "bad or missing token")
            return self.send_json(401, {"ok": False, "error": "unauthorized"})
        if not body_ok:
            return self.reject(method, path, None, 400, "body is not a JSON object")
        if method == "GET" and path == "/v1/watch":
            return self.watch(path)
        if method == "GET" and path in ("/v1/battery", "/v1/network", "/v1/rotation"):
            record(method, path, None, 200, False)
            with lock:
                return self.send_json(200, STATE[path[4:]])
        if method == "POST" and path == "/v1/rotation":
            if not isinstance(body.get("lock"), bool):
                return self.reject(method, path, body, 400, "lock must be a boolean")
            with lock:
                STATE["rotation"] = dict(STATE["rotation"], lock=body["lock"])
            record(method, path, body, 200, False)
            broadcast("rotation")
            return self.send_json(200, {"ok": True, "lock": body["lock"]})
        if method == "POST" and path == "/v1/notify":
            if "close" in body:
                record(method, path, body, 200, False)
                return self.send_json(200, {"ok": True, "pane": "", "id": body["close"],
                                            "closed": True})
            if not (body.get("body") or body.get("title")):
                return self.reject(method, path, body, 400, "body or title required")
            record(method, path, body, 200, False)
            return self.send_json(200, {"ok": True, "pane": "", "id": body.get("id", ""),
                                        "shown": True})
        if method == "POST" and path == "/v1/vibrate":
            ms = body.get("duration_ms", 1000)
            if not isinstance(ms, int) or ms <= 0:
                return self.reject(method, path, body, 400, "duration_ms must be positive")
            record(method, path, body, 200, False)
            return self.send_json(200, {"ok": True, "duration_ms": min(ms, 10000),
                                        "force": bool(body.get("force", False))})
        if method == "POST" and path == "/v1/torch":
            if not isinstance(body.get("on"), bool):
                return self.reject(method, path, body, 400, "on must be a boolean")
            record(method, path, body, 200, False)
            return self.send_json(200, {"ok": True, "on": body["on"], "camera": "0"})
        if method == "POST" and path == "/v1/settings/open":
            if body.get("page") not in ("wifi", "mobile", "battery"):
                return self.reject(method, path, body, 400, "page must be wifi, mobile or battery")
            record(method, path, body, 200, False)
            return self.send_json(200, {"ok": True, "page": body["page"]})
        record(method, path, body, 404, True, "unknown route")
        return self.send_json(404, {"ok": False, "error": "not_found"})

    def watch(self, path):
        q = queue.Queue()
        with lock:
            full = len(watchers) >= MAX_WATCHERS
            if not full:
                watchers.append(q)
        if full:
            record("GET", path, None, 429, True, "too_many_watchers")
            return self.send_json(429, {"ok": False, "error": "too_many_watchers"})
        record("GET", path, None, 200, False)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b": keepalive\n\n")
            for topic in TOPICS:
                with lock:
                    data = json.dumps(STATE[topic], separators=(",", ":"))
                self.wfile.write(("event: %s\ndata: %s\n\n" % (topic, data)).encode())
            self.wfile.flush()
            while True:
                try:
                    frame = q.get(timeout=args.keepalive)
                except queue.Empty:
                    frame = ": keepalive\n\n"
                self.wfile.write(frame.encode())
                self.wfile.flush()
        except OSError:
            pass
        finally:
            with lock:
                if q in watchers:
                    watchers.remove(q)
            self.close_connection = True

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


class Control(Base):
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n)) if n else {}

    def do_GET(self):
        with lock:
            if self.path == "/calls":
                return self.send_json(200, list(calls))
            if self.path == "/state":
                return self.send_json(200, dict(STATE))
            if self.path == "/watchers":
                return self.send_json(200, {"watchers": len(watchers)})
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        if parts == ["reset"]:
            with lock:
                calls.clear()
                write_log()
            return self.send_json(200, {"ok": True})
        if len(parts) == 2 and parts[0] in ("state", "push") and parts[1] in TOPICS:
            try:
                new = self.body()
            except ValueError:
                return self.send_json(400, {"error": "bad_json"})
            with lock:
                STATE[parts[1]] = new
            if parts[0] == "push":
                broadcast(parts[1])
            return self.send_json(200, {"ok": True})
        self.send_json(404, {"error": "not_found"})


def main():
    global args
    p = argparse.ArgumentParser()
    p.add_argument("--home", required=True, help="HOME whose .launcherctl/ gets endpoint and token")
    p.add_argument("--log", required=True, help="JSON file every call is recorded in")
    p.add_argument("--token", default="fake-token-0123456789abcdef")
    p.add_argument("--keepalive", type=float, default=15.0)
    args = p.parse_args()

    api = ThreadingHTTPServer(("127.0.0.1", 0), Api)
    ctl = ThreadingHTTPServer(("127.0.0.1", 0), Control)
    api.daemon_threads = ctl.daemon_threads = True
    d = os.path.join(args.home, ".launcherctl")
    os.makedirs(d, mode=0o700, exist_ok=True)
    for name, text in (("endpoint", "http://127.0.0.1:%d\n" % api.server_port),
                       ("token", args.token + "\n"),
                       ("control", "http://127.0.0.1:%d\n" % ctl.server_port)):
        path = os.path.join(d, name)
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, 0o600)
    with lock:
        write_log()
    threading.Thread(target=ctl.serve_forever, daemon=True).start()
    print("ready", flush=True)
    try:
        api.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
