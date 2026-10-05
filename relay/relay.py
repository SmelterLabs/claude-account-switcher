"""claude-account-switcher relay.

A loopback relay for Claude Code sessions. The companion plugin points a session at
http://127.0.0.1:48620/acct/<name>; this relay replaces the Authorization header with <name>'s
long-lived token from tokens.json (beside this file) and forwards the request to api.anthropic.com,
streaming the response back. It binds 127.0.0.1 only and never logs a token.

Files beside this script:
  tokens.json   {"<name>": {"token": "...", "createdAt": "...", "expiresAt": "..."}, ...}
                (a bare string value is accepted too)
  relay.alive   heartbeat rewritten every 10 s: port, pid, time, account names
  relay.log     one line per request: account, method, path, status, bytes, seconds
Health: GET /health -> {"ok": true, "accounts": [names]}
"""
import http.client
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
TOKENS = os.path.join(HERE, "tokens.json")
LOG = os.path.join(HERE, "relay.log")
ALIVE = os.path.join(HERE, "relay.alive")
PORT = 48620
UPSTREAM = "api.anthropic.com"
HOP = {"host", "authorization", "x-api-key", "connection", "keep-alive", "transfer-encoding", "content-length", "proxy-authorization", "te", "trailer", "upgrade"}


def log(msg: str) -> None:
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def read_store() -> dict:
    try:
        with open(TOKENS, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def load_tokens() -> dict:
    """Return {name: token}. Accepts object entries ({"token": ...}) or bare strings."""
    out = {}
    for name, entry in read_store().items():
        tok = entry.get("token") if isinstance(entry, dict) else entry
        if isinstance(tok, str) and tok:
            out[name] = tok
    return out


def load_expiry() -> dict:
    """Return {name: expiresAt ISO string} for entries that record one (never the token)."""
    return {n: e["expiresAt"] for n, e in read_store().items() if isinstance(e, dict) and e.get("expiresAt")}


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # silence default stderr logging
        pass

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self) -> None:
        if self.path == "/health":
            self._json(200, {"ok": True, "accounts": sorted(load_tokens().keys())})
            return
        parts = self.path.split("/", 3)  # ['', 'acct', '<name>', '<rest>']
        if len(parts) < 4 or parts[1] != "acct":
            self._json(404, {"error": "expected /acct/<name>/..."})
            return
        name, rest = parts[2], "/" + parts[3]
        token = load_tokens().get(name)
        if not token:
            log(f"no token for account '{name}'")
            self._json(401, {"type": "error", "error": {"type": "authentication_error", "message": f"account-switcher relay: no token stored for account '{name}'"}})
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Authorization"] = f"Bearer {token}"
        if body is not None:
            headers["Content-Length"] = str(len(body))
        headers["Connection"] = "close"
        t0 = time.time()
        try:
            up = http.client.HTTPSConnection(UPSTREAM, timeout=600)
            up.request(self.command, rest, body=body, headers=headers)
            resp = up.getresponse()
        except Exception as e:  # upstream unreachable
            log(f"{name} {self.command} {rest} upstream error {type(e).__name__}")
            self._json(502, {"type": "error", "error": {"type": "api_error", "message": f"account-switcher relay: upstream error {type(e).__name__}"}})
            return
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() in ("transfer-encoding", "content-length", "connection"):
                continue
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        sent = 0
        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            up.close()
        log(f"{name} {self.command} {rest} -> {resp.status} {sent}B {time.time() - t0:.1f}s")
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _handle


def heartbeat(port: int) -> None:
    """Rewrite relay.alive every 10 s so the plugin can see the relay is up without an HTTP call."""

    def loop():
        while True:
            try:
                with open(ALIVE, "w", encoding="utf-8") as f:
                    f.write(json.dumps({"port": port, "pid": os.getpid(), "at": time.time(), "accounts": sorted(load_tokens().keys()), "expires": load_expiry()}))
            except OSError:
                pass
            time.sleep(10)

    threading.Thread(target=loop, daemon=True).start()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else PORT
    log(f"relay starting on 127.0.0.1:{port}")
    heartbeat(port)
    try:
        ThreadingHTTPServer(("127.0.0.1", port), Relay).serve_forever()
    except OSError as e:  # port already held by a running relay: exit quietly
        log(f"relay exit: {e}")
        sys.exit(0)
