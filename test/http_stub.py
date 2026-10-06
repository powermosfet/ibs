"""Controllable product API used by the NixOS integration check."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

state = {}
requests = []
memos = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with lock:
            if self.path == "/memo":
                memos.append(data)
                control = dict(state.get("pms", {}))
            else:
                state.update(data)
                control = {}
        self.reply(control.get("status", 200), "{}")

    def do_GET(self):
        if self.path == "/memos":
            with lock:
                body = json.dumps(memos)
            self.reply(200, body)
            return
        if self.path == "/requests":
            with lock:
                body = json.dumps(requests)
            self.reply(200, body)
            return
        barcode = unquote(urlsplit(self.path).path.removeprefix("/products/"))
        with lock:
            requests.append(barcode)
            control = dict(state.get(barcode, {}))
        time.sleep(control.get("delay", 0))
        self.reply(control.get("status", 200), control.get("body", json.dumps({"barcode": barcode, "name": "Milk"})))


ThreadingHTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
