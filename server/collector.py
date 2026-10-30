"""Receives daily statistics reports from Slashlight (docs/telemetry.md). Python standard library only.

POST /v1/report   one report (JSON); 204 on success
GET  /health      200 "ok"

The collector never stores IP addresses. It keeps a per-IP request counter in memory for rate limiting only.
"""

import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCHEMA = 1
MAX_BODY = 16 * 1024
RATE_LIMIT = 60  # requests per IP per hour
DATA_DIR = os.environ.get("DATA_DIR", "data")
SECRET = os.environ.get("SECRET", "")
TRUST_PROXY = os.environ.get("TRUST_PROXY") == "1"

UUID = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
ID = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
SHORT = re.compile(r"^[A-Za-z0-9._+-]{0,32}$")
INPUTS = {"key", "click", "number", "shortcut", "hold"}


def connect(path=None):
    db = sqlite3.connect(path or os.path.join(DATA_DIR, "stats.db"), check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS reports (
            install TEXT NOT NULL,        -- HMAC of the install ID, never the ID itself
            day TEXT NOT NULL,            -- yyyy-mm-dd, the user's local day
            received TEXT NOT NULL,
            payload TEXT NOT NULL,        -- the report without the install ID
            PRIMARY KEY (install, day)
        );
        CREATE TABLE IF NOT EXISTS installs (
            install TEXT PRIMARY KEY,
            first_day TEXT NOT NULL,
            last_day TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS daily (
            day TEXT PRIMARY KEY,
            stats TEXT NOT NULL           -- aggregated metrics for that day, kept forever
        );
        """
    )
    return db


class Invalid(Exception):
    pass


def _int(value, name, low=0, high=1_000_000):
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise Invalid(f"{name} must be an integer in {low}…{high}")
    return value


def _str(value, name, pattern=SHORT, optional=False):
    if value is None and optional:
        return None
    if not isinstance(value, str) or not pattern.match(value):
        raise Invalid(f"{name} is not valid")
    return value


def validate(report, today=None):
    """Returns a cleaned copy of the report (unknown fields dropped) or raises Invalid."""
    if not isinstance(report, dict):
        raise Invalid("report must be an object")
    if report.get("schema") != SCHEMA:
        raise Invalid("unsupported schema")
    install = _str(report.get("install"), "install", UUID)
    day = _str(report.get("day"), "day", re.compile(r"^\d{4}-\d{2}-\d{2}$"))
    try:
        d = date.fromisoformat(day)
    except ValueError:
        raise Invalid("day is not a date")
    today = today or datetime.now(timezone.utc).date()
    # Local days run up to 14 hours ahead of UTC; reports cover finished days within the last 8.
    if not today - timedelta(days=9) <= d <= today + timedelta(days=1):
        raise Invalid("day is out of range")

    app, system, settings, usage = (report.get(k) or {} for k in ("app", "system", "settings", "usage"))
    for name, part in (("app", app), ("system", system), ("settings", settings), ("usage", usage)):
        if not isinstance(part, dict):
            raise Invalid(f"{name} must be an object")

    def counts(obj, name, keys=None):
        if not isinstance(obj, dict) or len(obj) > 40:
            raise Invalid(f"{name} must be a small object")
        out = {}
        for k, v in obj.items():
            if (keys is not None and k not in keys) or (keys is None and not ID.match(k)):
                raise Invalid(f"{name} has an invalid key")
            out[k] = _int(v, f"{name}.{k}")
        return out

    clean = {
        "schema": SCHEMA,
        "day": day,
        "app": {
            "version": _str(app.get("version"), "app.version"),
            "build": _int(app.get("build", 0), "app.build"),
            "channel": _str(app.get("channel"), "app.channel", re.compile(r"^(stable|beta|test)$")),
        },
        "system": {
            "macos": _str(system.get("macos"), "system.macos", re.compile(r"^\d{1,2}\.\d{1,2}$")),
            "arch": _str(system.get("arch"), "system.arch", re.compile(r"^(arm64|x86_64)$")),
            "region": _str(system.get("region"), "system.region", re.compile(r"^[A-Z]{2}$|^\d{3}$"), optional=True),
            "language": _str(system.get("language"), "system.language", re.compile(r"^[a-z]{2,3}$"), optional=True),
        },
        "settings": {
            "hotkey": _str(settings.get("hotkey"), "settings.hotkey", re.compile(r"^[a-z0-9+,.;'`\[\]/\\=-]{1,32}$")),
            "appearance": _str(settings.get("appearance"), "settings.appearance", re.compile(r"^(system|light|dark)$")),
            "disabled": [_str(x, "settings.disabled", ID) for x in (settings.get("disabled") or [])][:40],
            "externalExtensions": _int(settings.get("externalExtensions", 0), "settings.externalExtensions", high=1000),
        },
        "usage": {
            "opens": _int(usage.get("opens", 0), "usage.opens"),
            "actions": _int(usage.get("actions", 0), "usage.actions"),
            "byExtension": counts(usage.get("byExtension") or {}, "usage.byExtension"),
            "inputs": counts(usage.get("inputs") or {}, "usage.inputs", INPUTS),
            "firstResult": _int(usage.get("firstResult", 0), "usage.firstResult"),
            "ranked": _int(usage.get("ranked", 0), "usage.ranked"),
            "latencyP50": _int(usage["latencyP50"], "usage.latencyP50", high=600_000) if usage.get("latencyP50") is not None else None,
            "queryLengthP50": _int(usage["queryLengthP50"], "usage.queryLengthP50", high=1000) if usage.get("queryLengthP50") is not None else None,
        },
    }
    if clean["usage"]["firstResult"] > clean["usage"]["ranked"]:
        raise Invalid("firstResult cannot exceed ranked")
    return install, clean


def install_hash(install, secret=None):
    key = (secret if secret is not None else SECRET).encode()
    return hmac.new(key, install.upper().encode(), hashlib.sha256).hexdigest()


def store(db, install, report, lock=threading.Lock()):
    h = install_hash(install)
    day = report["day"]
    with lock, db:
        db.execute(
            "INSERT INTO reports (install, day, received, payload) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(install, day) DO UPDATE SET payload = excluded.payload, received = excluded.received",
            (h, day, datetime.now(timezone.utc).isoformat(timespec="seconds"), json.dumps(report, separators=(",", ":"))),
        )
        db.execute(
            "INSERT INTO installs (install, first_day, last_day) VALUES (?, ?, ?) "
            "ON CONFLICT(install) DO UPDATE SET first_day = min(first_day, excluded.first_day), "
            "last_day = max(last_day, excluded.last_day)",
            (h, day, day),
        )


class RateLimiter:
    def __init__(self, limit=RATE_LIMIT, window=3600):
        self.limit, self.window, self.hits, self.lock = limit, window, {}, threading.Lock()

    def allow(self, ip):
        now = time.monotonic()
        with self.lock:
            recent = [t for t in self.hits.get(ip, []) if now - t < self.window]
            if len(recent) >= self.limit:
                self.hits[ip] = recent
                return False
            recent.append(now)
            self.hits[ip] = recent
            if len(self.hits) > 100_000:  # forget everyone rather than grow without bound
                self.hits.clear()
            return True


def make_handler(db, limiter):
    class Handler(BaseHTTPRequestHandler):
        server_version = "slashlight-collector"
        sys_version = ""

        def log_message(self, *args):  # no access log: it would contain IP addresses
            pass

        def _reply(self, status, body=b""):
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            if body:
                self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self._reply(200, b"ok") if self.path == "/health" else self._reply(404)

        def do_POST(self):
            if self.path != "/v1/report":
                return self._reply(404)
            ip = self.headers.get("X-Forwarded-For", "").split(",")[0].strip() if TRUST_PROXY else self.client_address[0]
            if not limiter.allow(ip):
                return self._reply(429)
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                return self._reply(413)
            try:
                install, report = validate(json.loads(self.rfile.read(length)))
            except (ValueError, Invalid) as e:
                return self._reply(400, str(e).encode())
            store(db, install, report)
            self._reply(204)

    return Handler


def main():
    if not SECRET:
        raise SystemExit("Set SECRET (any long random string); it keys the install-ID hashes.")
    os.makedirs(DATA_DIR, exist_ok=True)
    db = connect()
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(db, RateLimiter()))
    print(f"collector listening on :{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
