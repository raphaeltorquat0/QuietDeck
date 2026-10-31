#!/usr/bin/env python3
"""Serviço da Estante: mantém o índice do acervo e serve os arquivos na rede local, sem o Mac ligado.
Só lê a pasta do acervo. Sem QUIET_SHELF_TOKEN ele não sobe."""
import base64, hashlib, hmac, json, os, threading, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

ROOT = os.path.realpath(os.environ.get("QUIET_SHELF_ROOT", "/acervo"))
TOKEN = os.environ["QUIET_SHELF_TOKEN"]
DATA = os.environ.get("QUIET_SHELF_DATA", "/data/index.json")
EVERY = int(os.environ.get("QUIET_SHELF_RESCAN_MINUTES", "60")) * 60
# Em pasta de sistema o início do arquivo não serve para nada, e guardá-lo incharia o índice.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "folders.txt")) as f:
    KNOWN = set(f.read().split("\n"))

index, lock = {}, threading.Lock()


def scan():
    global index
    with lock:
        old = dict(index)
    new = {}
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.startswith("."):
                continue
            p = os.path.join(base, name)
            try:
                st = os.stat(p)
                r = old.get(p)
                if not (r and r["size"] == st.st_size and r["mtime"] == int(st.st_mtime)):
                    r = hash_file(p, st, base, name)
            except OSError as e:
                # Link quebrado ou sem permissão não pode impedir o resto do acervo de aparecer.
                print("ignorado:", p, e, flush=True)
                continue
            new[p] = r
            # A primeira varredura leva horas em acervos grandes: o app já vê o que ficou pronto.
            with lock:
                index[p] = r
    with lock:
        index = new
    tmp = DATA + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new, f)
    os.replace(tmp, DATA)


def hash_file(p, st, base, name):
    sha, crc = hashlib.sha1(), 0
    with open(p, "rb") as f:
        head = f.read(0x11000)
        chunk = head
        while chunk:
            sha.update(chunk)
            crc = zlib.crc32(chunk, crc)
            chunk = f.read(1 << 20)
    r = {"path": p, "size": st.st_size, "mtime": int(st.st_mtime), "crc": "%08x" % (crc & 0xffffffff), "sha1": sha.hexdigest()}
    if os.path.basename(base).lower() not in KNOWN:
        r["head"] = base64.b64encode(head).decode()
    if name.lower().rsplit(".", 1)[-1] in ("cue", "gdi"):
        r["text"] = head.decode("utf-8", "replace")
    return r


def loop():
    while True:
        try:
            scan()
        except OSError as e:
            print("varredura falhou:", e, flush=True)
        time.sleep(EVERY)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def authorized(self):
        return hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + TOKEN)

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, b"ok\n")
        if not self.authorized():
            return self.reply(401, b"")
        if self.path == "/index":
            with lock:
                body = json.dumps(list(index.values())).encode()
            return self.reply(200, body)
        if self.path.startswith("/files/"):
            return self.send_path("/" + unquote(self.path[len("/files/"):]).lstrip("/"))
        self.reply(404, b"")

    def send_path(self, path):
        real = os.path.realpath(path)
        # O caminho vem da rede: nada fora do acervo sai daqui.
        if not real.startswith(ROOT + os.sep) or not os.path.isfile(real):
            return self.reply(404, b"")
        size = os.path.getsize(real)
        start = 0
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes=") and rng[6:].split("-")[0].isdigit():
            start = int(rng[6:].split("-")[0])
        if start >= size and size:
            return self.reply(416, b"")
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(size - start))
        self.send_header("Accept-Ranges", "bytes")
        if start:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, size - 1, size))
        self.end_headers()
        with open(real, "rb") as f:
            f.seek(start)
            while chunk := f.read(1 << 20):
                self.wfile.write(chunk)

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    if os.path.exists(DATA):
        with open(DATA) as f:
            index = json.load(f)
    threading.Thread(target=loop, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("QUIET_SHELF_PORT", "8766"))), Handler).serve_forever()
