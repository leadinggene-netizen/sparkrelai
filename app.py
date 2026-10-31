#!/usr/bin/env python3
"""
TradingView -> MT5 Bridge Portal (MVP)
No third-party dependencies. Python 3.10+ standard library only.

Run:
    python3 app.py
    # then open http://127.0.0.1:8000

How it works:
  1. A user signs up, picks a plan, and creates a connection.
  2. The connection gets a unique webhook URL and a license key.
  3. The user pastes the webhook URL into a TradingView alert.
  4. The MT5 EA (TradingViewBridge.mq5) polls the portal for pending
     signals and executes them locally in MT5. No broker password is
     ever sent to, or stored by, the portal.
  5. The EA reports fills / errors back, and the user watches them
     in their workspace signal log.

This is an MVP. Before charging real users, add HTTPS (see README),
email verification, real payment webhooks, backups, and rate limiting.
"""
import hashlib
import html
import json
import os
import re
import secrets
import sqlite3
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, "portal.db")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8000"))

PLANS = {
    "starter": {"name": "Starter", "connections": 1, "price": "$0/mo (MVP demo)"},
    "pro": {"name": "Pro", "connections": 3, "price": "$29/mo (MVP demo)"},
    "scale": {"name": "Scale", "connections": 5, "price": "$59/mo (MVP demo)"},
}
ACTIONS = {"buy", "sell", "close", "close_long", "close_short"}

# ---------------------------------------------------------------- DB
def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = db()
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        plan TEXT NOT NULL DEFAULT 'starter',
        is_admin INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS sessions (
        token TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS connections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        license_key TEXT UNIQUE NOT NULL,
        webhook_token TEXT UNIQUE NOT NULL,
        symbol_map TEXT NOT NULL DEFAULT '{}',
        default_volume REAL NOT NULL DEFAULT 0.01,
        account_login TEXT DEFAULT '',
        broker TEXT DEFAULT '',
        last_heartbeat TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS signals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        connection_id INTEGER NOT NULL,
        raw TEXT NOT NULL,
        action TEXT NOT NULL,
        symbol TEXT NOT NULL,
        volume REAL NOT NULL DEFAULT 0.01,
        sl REAL NOT NULL DEFAULT 0,
        tp REAL NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending',
        ticket TEXT DEFAULT '',
        note TEXT DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    """)
    conn.commit()
    conn.close()

def hash_password(password):
    salt = secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 200_000)
    return f"pbkdf2:{salt}:{dk.hex()}"

def check_password(password, stored):
    try:
        _, salt, expected = stored.split(":")
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 200_000)
        return secrets.compare_digest(dk.hex(), expected)
    except Exception:
        return False

# ---------------------------------------------------------------- HTML
def esc(value):
    return html.escape(str(value if value is not None else ""))

def page(title, body, user=None):
    nav = ""
    if user:
        nav = f"""<nav><a href="/dashboard">Workspace</a> <a href="/connections/new">New connection</a> <a href="/download/ea">Download EA</a> {'<a href="/admin">Admin</a>' if user['is_admin'] else ''} <a href="/logout">Log out ({esc(user['email'])})</a></nav>"""
    else:
        nav = """<nav><a href="/login">Log in</a> <a href="/signup">Sign up</a></nav>"""
    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>
body{{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;color:#111;line-height:1.5}}
nav a{{margin-right:1rem}} code{{background:#f1f1f1;padding:.15rem .4rem;border-radius:4px;word-break:break-all}}
table{{border-collapse:collapse;width:100%}} td,th{{border:1px solid #ddd;padding:.5rem;text-align:left}}
input,select,textarea{{padding:.5rem;margin:.25rem 0;width:100%;box-sizing:border-box}}
button{{padding:.6rem 1rem;cursor:pointer}} .card{{border:1px solid #ddd;border-radius:8px;padding:1rem;margin:1rem 0}}
.ok{{color:#067647}} .bad{{color:#b42318}} .muted{{color:#555}}
</style></head><body>{nav}<h1>{esc(title)}</h1>{body}</body></html>"""

def field_errors():
    return ""

# ---------------------------------------------------------------- helpers
def current_user(handler):
    cookies = handler.headers.get("Cookie", "")
    match = re.search(r"session=([A-Za-z0-9_-]+)", cookies)
    if not match:
        return None
    conn = db()
    row = conn.execute(
        "SELECT u.* FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token=?",
        (match.group(1),)).fetchone()
    conn.close()
    return row

def set_session(handler, user_id):
    token = secrets.token_urlsafe(32)
    conn = db()
    conn.execute("INSERT INTO sessions(token, user_id) VALUES(?,?)", (token, user_id))
    conn.commit()
    conn.close()
    handler.send_header("Set-Cookie", f"session={token}; HttpOnly; Path=/; SameSite=Lax")
    return token

def parse_signal_body(raw):
    """Accept JSON, or PineConnector-style text: key,buy,XAUUSD,vol=0.1,sl=...,tp=..."""
    raw = raw.strip()
    if not raw:
        return None, "empty signal"
    if raw.startswith("{"):
        try:
            data = json.loads(raw)
        except Exception as exc:
            return None, f"invalid JSON: {exc}"
        action = str(data.get("action", "")).lower()
        symbol = str(data.get("symbol", "")).upper()
        try:
            volume = float(data.get("volume", data.get("vol", 0.01)) or 0.01)
            sl = float(data.get("sl", 0) or 0)
            tp = float(data.get("tp", 0) or 0)
        except Exception:
            return None, "volume/sl/tp must be numbers"
        if action not in ACTIONS or not symbol:
            return None, "need action (buy/sell/close/close_long/close_short) and symbol"
        return {"action": action, "symbol": symbol, "volume": volume, "sl": sl, "tp": tp}, None
    parts = [p.strip() for p in raw.split(",")]
    # parts[0] may be a license key in text alerts; the webhook token already
    # identifies the connection, so ignore a leading non-action token.
    if parts and parts[0].lower() not in ACTIONS:
        parts = parts[1:]
    if len(parts) < 2 or parts[0].lower() not in ACTIONS:
        return None, "text signal must look like: buy,XAUUSD,vol=0.1"
    action, symbol = parts[0].lower(), parts[1].upper()
    volume, sl, tp = 0.01, 0.0, 0.0
    for part in parts[2:]:
        if "=" in part:
            key, val = part.split("=", 1)
            try:
                if key.strip().lower() in ("vol", "volume"):
                    volume = float(val)
                elif key.strip().lower() == "sl":
                    sl = float(val)
                elif key.strip().lower() == "tp":
                    tp = float(val)
            except ValueError:
                return None, f"bad number in '{part}'"
    return {"action": action, "symbol": symbol, "volume": volume, "sl": sl, "tp": tp}, None

# ---------------------------------------------------------------- handler
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), args[0] % args[1:]))

    def send_html(self, code, body, extra_headers=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_text(self, code, text):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length).decode(errors="replace") if length else ""

    def form(self):
        return dict(urllib.parse.parse_qsl(self.read_body()))

    def require_user(self):
        user = current_user(self)
        if not user:
            self.redirect("/login")
        return user

    # ------------------------------------------------------------ GET
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path, query = parsed.path, dict(urllib.parse.parse_qsl(parsed.query))
        user = current_user(self)
        base = f"http://{self.headers.get('Host', 'localhost')}"

        if path == "/":
            if user:
                return self.redirect("/dashboard")
            body = """<p>Turn TradingView alerts into MT5 trades.</p>
            <div class="card"><h2>How it works</h2><ol>
            <li>Create a connection in your workspace.</li>
            <li>Paste its webhook URL into a TradingView alert.</li>
            <li>Attach the EA in MT5. It polls for signals and executes them.</li>
            <li>Watch fills and errors in your signal log.</li></ol></div>
            <p><a href="/signup">Create an account</a> or <a href="/login">log in</a>.</p>
            <p class="muted">MVP demo: plans and billing are placeholders. Always test on a demo MT5 account first.</p>"""
            return self.send_html(200, page("TradingView to MT5 Bridge", body, user))

        if path == "/signup":
            return self.send_html(200, page("Sign up", """
            <form method="post" action="/signup"><label>Email <input name="email" type="email" required></label>
            <label>Password <input name="password" type="password" required minlength="8"></label>
            <label>Plan <select name="plan"><option value="starter">Starter — 1 connection</option>
            <option value="pro">Pro — 3 connections</option><option value="scale">Scale — 5 connections</option></select></label>
            <button>Sign up</button></form>""", user))
        if path == "/login":
            return self.send_html(200, page("Log in", """
            <form method="post" action="/login"><label>Email <input name="email" type="email" required></label>
            <label>Password <input name="password" type="password" required></label>
            <button>Log in</button></form>""", user))
        if path == "/logout":
            return self.send_html(200, page("Logged out", "<p>You are logged out. <a href='/login'>Log in again</a>.</p>", None))

        if path == "/dashboard":
            user = self.require_user()
            if not user:
                return
            conn = db()
            conns = conn.execute("SELECT * FROM connections WHERE user_id=? ORDER BY id DESC", (user["id"],)).fetchall()
            sigs = conn.execute(
                "SELECT s.*, c.name FROM signals s JOIN connections c ON c.id=s.connection_id "
                "WHERE c.user_id=? ORDER BY s.id DESC LIMIT 25", (user["id"],)).fetchall()
            conn.close()
            plan = PLANS.get(user["plan"], PLANS["starter"])
            rows = "".join(
                f"<tr><td><a href='/connections/{c['id']}'>{esc(c['name'])}</a></td>"
                f"<td>{esc(c['broker'] or '—')} {esc(c['account_login'] or '')}</td>"
                f"<td>{'<span class=ok>Online</span>' if c['last_heartbeat'] else '<span class=bad>Never connected</span>'}</td>"
                f"<td>{esc(c['last_heartbeat'] or '—')}</td></tr>" for c in conns)
            srows = "".join(
                f"<tr><td>{s['id']}</td><td>{esc(s['name'])}</td><td>{esc(s['action'])}</td>"
                f"<td>{esc(s['symbol'])}</td><td>{s['volume']}</td><td>{esc(s['status'])}</td>"
                f"<td>{esc(s['note'] or '')}</td><td>{esc(s['created_at'])}</td></tr>" for s in sigs)
            body = f"""<p>Plan: <b>{esc(plan['name'])}</b> — {plan['connections']} connection(s). {esc(plan['price'])}</p>
            <h2>Connections ({len(conns)})</h2><table><tr><th>Name</th><th>MT5 account</th><th>Status</th><th>Last heartbeat</th></tr>{rows or '<tr><td colspan=4>No connections yet.</td></tr>'}</table>
            <p><a href="/connections/new">+ New connection</a></p>
            <h2>Recent signals</h2><table><tr><th>#</th><th>Connection</th><th>Action</th><th>Symbol</th><th>Volume</th><th>Status</th><th>Note</th><th>When</th></tr>{srows or '<tr><td colspan=8>No signals yet.</td></tr>'}</table>"""
            return self.send_html(200, page("Workspace", body, user))

        if path == "/connections/new":
            user = self.require_user()
            if not user:
                return
            return self.send_html(200, page("New connection", """
            <form method="post" action="/connections/new"><label>Name <input name="name" required placeholder="e.g. Gold strategy"></label>
            <label>Default volume <input name="default_volume" value="0.01"></label>
            <label>Symbol map (one per line, TradingView=MT5, e.g. XAUUSD=XAUUSD.m) <textarea name="symbol_map" rows="4"></textarea></label>
            <button>Create connection</button></form>""", user))

        m = re.match(r"^/connections/(\d+)$", path)
        if m:
            user = self.require_user()
            if not user:
                return
            conn = db()
            c = conn.execute("SELECT * FROM connections WHERE id=? AND user_id=?", (m.group(1), user["id"])).fetchone()
            if not c:
                conn.close()
                return self.send_html(404, page("Not found", "<p>Connection not found.</p>", user))
            sigs = conn.execute("SELECT * FROM signals WHERE connection_id=? ORDER BY id DESC LIMIT 50", (c["id"],)).fetchall()
            conn.close()
            webhook = f"{base}/webhook/{c['webhook_token']}"
            srows = "".join(
                f"<tr><td>{s['id']}</td><td>{esc(s['action'])}</td><td>{esc(s['symbol'])}</td>"
                f"<td>{s['volume']}</td><td>{esc(s['status'])}</td><td>{esc(s['ticket'] or '')}</td>"
                f"<td>{esc(s['note'] or '')}</td><td>{esc(s['created_at'])}</td></tr>" for s in sigs)
            body = f"""<div class="card"><h2>Connection info</h2>
            <p>Webhook URL (paste into TradingView):<br><code>{esc(webhook)}</code></p>
            <p>License key (paste into the EA):<br><code>{esc(c['license_key'])}</code></p>
            <p>Default volume: {c['default_volume']} &nbsp; Symbol map: <code>{esc(c['symbol_map'])}</code></p>
            <p>MT5 account: {esc(c['account_login'] or '—')} &nbsp; Broker: {esc(c['broker'] or '—')} &nbsp; Last heartbeat: {esc(c['last_heartbeat'] or 'never')}</p>
            <p><a href="/download/ea">Download TradingViewBridge.mq5</a> — compile it in MetaEditor to get the .ex5 file.</p></div>
            <h2>TradingView alert examples</h2>
            <p>JSON message:</p><pre><code>{{"action": "buy", "symbol": "XAUUSD", "volume": 0.1, "sl": 0, "tp": 0}}</code></pre>
            <p>Or plain text:</p><pre><code>buy,XAUUSD,vol=0.1</code></pre>
            <h2>Signal log</h2><table><tr><th>#</th><th>Action</th><th>Symbol</th><th>Volume</th><th>Status</th><th>Ticket</th><th>Note</th><th>When</th></tr>{srows or '<tr><td colspan=8>No signals yet.</td></tr>'}</table>"""
            return self.send_html(200, page(c["name"], body, user))

        if path == "/admin":
            user = self.require_user()
            if not user or not user["is_admin"]:
                return self.send_html(403, page("Admin", "<p>Admin only.</p>", user))
            conn = db()
            users = conn.execute("SELECT id, email, plan, is_admin, created_at FROM users ORDER BY id").fetchall()
            counts = conn.execute("SELECT user_id, COUNT(*) n FROM connections GROUP BY user_id").fetchall()
            conn.close()
            cmap = {r["user_id"]: r["n"] for r in counts}
            rows = "".join(f"<tr><td>{u['id']}</td><td>{esc(u['email'])}</td><td>{esc(u['plan'])}</td><td>{cmap.get(u['id'], 0)}</td><td>{'yes' if u['is_admin'] else ''}</td><td>{esc(u['created_at'])}</td></tr>" for u in users)
            return self.send_html(200, page("Admin — users", f"<table><tr><th>ID</th><th>Email</th><th>Plan</th><th>Connections</th><th>Admin</th><th>Created</th></tr>{rows}</table><p class='muted'>MVP admin is read-only. Change a plan in the database or extend this page with a plan-change form.</p>", user))

        if path == "/download/ea":
            ea_path = os.path.join(BASE_DIR, "TradingViewBridge.mq5")
            if not os.path.exists(ea_path):
                return self.send_html(404, page("EA not found", "<p>TradingViewBridge.mq5 is missing from the server folder.</p>", user))
            data = open(ea_path, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition", "attachment; filename=TradingViewBridge.mq5")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        # ---- EA / machine API (no login; license key is the credential)
        if path == "/api/ea/poll":
            license_key = query.get("license", "")
            conn = db()
            c = conn.execute("SELECT * FROM connections WHERE license_key=?", (license_key,)).fetchone()
            if not c:
                conn.close()
                return self.send_json(401, {"error": "bad license key"})
            sigs = conn.execute("SELECT * FROM signals WHERE connection_id=? AND status='pending' ORDER BY id LIMIT 20", (c["id"],)).fetchall()
            conn.close()
            if query.get("format") == "text":
                lines = []
                for s in sigs:
                    lines.append(f"{s['id']}|{s['action']}|{s['symbol']}|{s['volume']}|{s['sl']}|{s['tp']}")
                return self.send_text(200, "\n".join(lines))
            return self.send_json(200, {"signals": [dict(s) for s in sigs]})

        # EA ack / heartbeat also work as GETs, so the MQL5 EA can use
        # simple WebRequest calls without building a POST body.
        if path in ("/api/ea/ack", "/api/ea/heartbeat"):
            conn = db()
            c = conn.execute("SELECT * FROM connections WHERE license_key=?", (query.get("license", ""),)).fetchone()
            if not c:
                conn.close()
                return self.send_json(401, {"error": "bad license key"})
            if path == "/api/ea/ack":
                status = query.get("status", "executed")
                if status not in ("executed", "failed", "skipped"):
                    status = "executed"
                conn.execute("UPDATE signals SET status=?, ticket=?, note=?, updated_at=datetime('now') WHERE id=? AND connection_id=?",
                             (status, query.get("ticket", "")[:50], query.get("note", "")[:500], query.get("signal", ""), c["id"]))
            else:
                conn.execute("UPDATE connections SET last_heartbeat=datetime('now'), account_login=?, broker=? WHERE id=?",
                             (query.get("account", "")[:50], query.get("broker", "")[:100], c["id"]))
            conn.commit()
            conn.close()
            return self.send_json(200, {"ok": True})

        return self.send_html(404, page("Not found", "<p>Page not found. <a href='/'>Home</a></p>", user))

    # ------------------------------------------------------------ POST
    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path, query = parsed.path, dict(urllib.parse.parse_qsl(parsed.query))
        user = current_user(self)

        if path == "/signup":
            f = self.form()
            email, password, plan = f.get("email", "").strip().lower(), f.get("password", ""), f.get("plan", "starter")
            if plan not in PLANS:
                plan = "starter"
            if len(password) < 8 or "@" not in email:
                return self.send_html(400, page("Sign up", "<p class='bad'>Use a valid email and a password of at least 8 characters.</p>", user))
            conn = db()
            is_first = conn.execute("SELECT COUNT(*) n FROM users").fetchone()["n"] == 0
            try:
                cur = conn.execute("INSERT INTO users(email, password_hash, plan, is_admin) VALUES(?,?,?,?)",
                                   (email, hash_password(password), plan, 1 if is_first else 0))
                conn.commit()
                user_id = cur.lastrowid
            except sqlite3.IntegrityError:
                conn.close()
                return self.send_html(400, page("Sign up", "<p class='bad'>That email is already registered.</p>", user))
            conn.close()
            # set session cookie, then redirect
            self.send_response(302)
            set_session(self, user_id)
            self.send_header("Location", "/dashboard")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path == "/login":
            f = self.form()
            conn = db()
            row = conn.execute("SELECT * FROM users WHERE email=?", (f.get("email", "").strip().lower(),)).fetchone()
            conn.close()
            if not row or not check_password(f.get("password", ""), row["password_hash"]):
                return self.send_html(401, page("Log in", "<p class='bad'>Wrong email or password.</p>", user))
            self.send_response(302)
            set_session(self, row["id"])
            self.send_header("Location", "/dashboard")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path == "/connections/new":
            user = self.require_user()
            if not user:
                return
            f = self.form()
            symbol_map = {}
            for line in f.get("symbol_map", "").splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    if k.strip() and v.strip():
                        symbol_map[k.strip().upper()] = v.strip()
            try:
                volume = float(f.get("default_volume", "0.01") or 0.01)
            except ValueError:
                volume = 0.01
            conn = db()
            count = conn.execute("SELECT COUNT(*) n FROM connections WHERE user_id=?", (user["id"],)).fetchone()["n"]
            limit = PLANS.get(user["plan"], PLANS["starter"])["connections"]
            if count >= limit:
                conn.close()
                return self.send_html(403, page("Plan limit", f"<p class='bad'>Your plan allows {limit} connection(s). Upgrade to add more.</p>", user))
            cur = conn.execute(
                "INSERT INTO connections(user_id, name, license_key, webhook_token, symbol_map, default_volume) VALUES(?,?,?,?,?,?)",
                (user["id"], f.get("name", "Connection")[:100], secrets.token_hex(16), secrets.token_hex(16),
                 json.dumps(symbol_map), volume))
            conn.commit()
            conn_id = cur.lastrowid
            conn.close()
            return self.redirect(f"/connections/{conn_id}")

        m = re.match(r"^/webhook/([A-Za-z0-9]+)$", path)
        if m:
            raw = self.read_body()
            conn = db()
            c = conn.execute("SELECT * FROM connections WHERE webhook_token=?", (m.group(1),)).fetchone()
            if not c:
                conn.close()
                return self.send_json(404, {"error": "unknown webhook"})
            signal, err = parse_signal_body(raw)
            if err:
                conn.close()
                return self.send_json(400, {"error": err})
            if not signal["volume"]:
                signal["volume"] = c["default_volume"]
            cur = conn.execute(
                "INSERT INTO signals(connection_id, raw, action, symbol, volume, sl, tp) VALUES(?,?,?,?,?,?,?)",
                (c["id"], raw[:2000], signal["action"], signal["symbol"], signal["volume"], signal["sl"], signal["tp"]))
            conn.commit()
            sig_id = cur.lastrowid
            conn.close()
            return self.send_json(200, {"ok": True, "signal_id": sig_id, "status": "pending"})

        if path == "/api/ea/ack":
            f = self.form()
            # also accept JSON body if the EA posts JSON
            if not f:
                try:
                    f = json.loads(self.read_body() or "{}")
                except Exception:
                    f = {}
            conn = db()
            c = conn.execute("SELECT * FROM connections WHERE license_key=?", (str(f.get("license", "")),)).fetchone()
            if not c:
                conn.close()
                return self.send_json(401, {"error": "bad license key"})
            status = str(f.get("status", "executed"))
            if status not in ("executed", "failed", "skipped"):
                status = "executed"
            conn.execute("UPDATE signals SET status=?, ticket=?, note=?, updated_at=datetime('now') WHERE id=? AND connection_id=?",
                         (status, str(f.get("ticket", ""))[:50], str(f.get("note", ""))[:500], f.get("signal", ""), c["id"]))
            conn.commit()
            conn.close()
            return self.send_json(200, {"ok": True})

        if path == "/api/ea/heartbeat":
            f = self.form()
            if not f:
                try:
                    f = json.loads(self.read_body() or "{}")
                except Exception:
                    f = {}
            conn = db()
            c = conn.execute("SELECT * FROM connections WHERE license_key=?", (str(f.get("license", "")),)).fetchone()
            if not c:
                conn.close()
                return self.send_json(401, {"error": "bad license key"})
            conn.execute("UPDATE connections SET last_heartbeat=datetime('now'), account_login=?, broker=? WHERE id=?",
                         (str(f.get("account", ""))[:50], str(f.get("broker", ""))[:100], c["id"]))
            conn.commit()
            conn.close()
            return self.send_json(200, {"ok": True})

        return self.send_html(404, page("Not found", "<p>Page not found.</p>", user))

if __name__ == "__main__":
    init_db()
    print(f"TradingView -> MT5 portal running at http://{HOST}:{PORT}")
    print("First account to sign up becomes admin.")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
