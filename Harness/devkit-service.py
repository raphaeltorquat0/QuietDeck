#!/usr/bin/env python3
# Imita o steamos-devkit-service no que o cliente vê: rotas, validação e respostas de /register.
# A aprovação no Steam não é simulável; `/run/deck-sim/devkit-deny` responde como um pedido negado.
import json, os, pwd
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def reply(self, code, body):
        self.send_response(code); self.send_header("Content-type", "text/plain"); self.end_headers(); self.wfile.write(body.encode())

    def do_GET(self):
        if self.path == "/login-name": return self.reply(200, "deck")
        if self.path == "/?command=ping": return self.reply(200, "pong\n")
        if self.path == "/properties.json": return self.reply(200, json.dumps({"txtvers": 1, "login": "deck", "settings": "{}", "devkit1": ["devkit-1"]}))
        self.reply(404, "Unknown request\n")

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        fields = body.split(" ")
        if not body.startswith("ssh-rsa ") or len(fields) != 4: return self.reply(403, json.dumps({"error": "Failed to write the ssh key"}))
        if os.path.exists("/run/deck-sim/devkit-deny"): return self.reply(403, json.dumps({"error": "Pairing denied"}))
        p = pwd.getpwnam("deck")
        os.makedirs(p.pw_dir + "/.ssh", exist_ok=True)
        with open(p.pw_dir + "/.ssh/authorized_keys", "a") as f: f.write(" ".join(fields[:3]) + "\n")
        os.chown(p.pw_dir + "/.ssh/authorized_keys", p.pw_uid, p.pw_gid); os.chmod(p.pw_dir + "/.ssh/authorized_keys", 0o600)
        self.reply(200, "Registered\n")

    def log_message(self, *a): pass

HTTPServer(("", 32000), H).serve_forever()
