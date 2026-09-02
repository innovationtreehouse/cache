#!/usr/bin/env python3
"""Stand-in for the facility cache host.

3142  apt-cacher-ng-style proxy: forwards absolute-URI proxy requests, the
      legacy "/https://host/path" form, and the "/host/path" implicit-backend
      form to the real upstream.
3141  devpi-style: /root/pypi/+simple/<x> forwards to https://pypi.org/simple/<x>
4873  verdaccio-style: forwards to https://registry.npmjs.org
5000/5001  registry stubs: /v2/ -> {}
"""

import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORTS = {
    3141: "devpi",
    3142: "apt-cacher-ng",
    4873: "verdaccio",
    5000: "registry-hub",
    5001: "registry-ghcr",
}


def upstream_for(port, path):
    if port == 3142:
        if path.startswith("http://") or path.startswith("https://"):
            return path  # absolute-URI proxy request
        if path.startswith("/https://") or path.startswith("/http://"):
            return path[1:]  # legacy scheme-in-path form
        # apt-cacher-ng implicit-backend form: /<host>/<path> → https upstream
        if "." in path[1:].split("/", 1)[0]:
            return "https:/" + path
        return None
    if port == 3141 and path.startswith("/root/pypi/+simple/"):
        return "https://pypi.org/simple/" + path[len("/root/pypi/+simple/") :]
    if port == 4873:
        return "https://registry.npmjs.org" + path
    return None


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stdout.write(
            "%s %s %s\n" % (self.server.server_port, self.command, self.path)
        )
        sys.stdout.flush()

    def _serve(self, send_body=True):
        port = self.server.server_port
        svc = PORTS[port]
        url = upstream_for(port, self.path)
        if url is not None:
            try:
                req = urllib.request.Request(url, method=self.command)
                for h in ("Range", "If-Modified-Since", "Accept", "User-Agent"):
                    v = self.headers.get(h)
                    if v:
                        req.add_header(h, v)
                with urllib.request.urlopen(req, timeout=60) as resp:
                    body = resp.read()
                    self.send_response(resp.status)
                    ct = resp.headers.get("Content-Type", "application/octet-stream")
                    self.send_header("Content-Type", ct)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("X-Facility-Cache-Service", svc)
                    self.end_headers()
                    if send_body:
                        self.wfile.write(body)
                    return
            except urllib.error.HTTPError as e:
                body = e.read()
                self.send_response(e.code)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("X-Facility-Cache-Service", svc)
                self.end_headers()
                if send_body:
                    self.wfile.write(body)
                return
            except Exception as e:  # noqa: BLE001
                body = ("upstream error: %s\n" % e).encode()
                self.send_response(502)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if send_body:
                    self.wfile.write(body)
                return
        body = b"{}" if svc.startswith("registry") else b"ok\n"
        ct = "application/json" if svc.startswith("registry") else "text/plain"
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Facility-Cache-Service", svc)
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def do_GET(self):
        self._serve(True)

    def do_HEAD(self):
        self._serve(False)


for port in PORTS:
    s = ThreadingHTTPServer(("0.0.0.0", port), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    print("listening", port, PORTS[port], flush=True)
threading.Event().wait()
