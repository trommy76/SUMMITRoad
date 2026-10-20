#!/usr/bin/env python3
"""SummitRoad home server: stores rides, FTP history and .FIT files per user, and serves a browser dashboard.

Standard library only. Data lives in $SUMMITROAD_DATA (default /data).
  python server.py                      run the server
  python server.py adduser NAME [PASS] [--admin]  create a user or reset their password (prompts if PASS omitted)
  python server.py users                list users
"""
import base64, getpass, hashlib, hmac, json, os, queue, re, secrets, sqlite3, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

def _read_version():
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "VERSION")) as f:
            return f.read().strip() or "dev"
    except OSError:
        return "dev"


VERSION = _read_version()
USER_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
MIN_PW = 10
TRUST_PROXY = os.environ.get("SUMMITROAD_TRUST_PROXY", "0") == "1"   # take the client IP from Cloudflare / proxy headers
FAIL_WINDOW = 600          # seconds
MAX_FAILS_IP = 10          # failed logins per client IP within the window
MAX_FAILS_USER = 30        # failed logins per username within the window (all IPs)
RUN_UID = 10001
DOC_NAMES = ("plan", "settings")   # small synced documents: newest change wins
LOG_KEEP_DAYS = 90         # activity log retention
LOG_MAX_ROWS = 20000
DATA_DIR = os.environ.get("SUMMITROAD_DATA", "/data")
PORT = int(os.environ.get("SUMMITROAD_PORT", "8787"))
MAX_BODY = 64 * 1024 * 1024
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")
DB_PATH = os.path.join(DATA_DIR, "summitroad.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, salt BLOB, hash BLOB, created REAL);
CREATE TABLE IF NOT EXISTS rides (
  user TEXT, id TEXT, date TEXT, data TEXT, deleted INTEGER DEFAULT 0, updated REAL, fit BLOB,
  PRIMARY KEY (user, id));
CREATE TABLE IF NOT EXISTS ftp (user TEXT, id TEXT, date TEXT, ftp REAL, method TEXT, PRIMARY KEY (user, id));
CREATE TABLE IF NOT EXISTS docs (user TEXT, name TEXT, data TEXT, updated REAL, deleted INTEGER DEFAULT 0, PRIMARY KEY (user, name));
CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, user TEXT, ip TEXT, client TEXT, type TEXT, detail TEXT);
CREATE INDEX IF NOT EXISTS events_user ON events (user, id);
"""


def db():
    c = sqlite3.connect(DB_PATH, timeout=30)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    os.makedirs(DATA_DIR, exist_ok=True)
    with db() as c:
        c.executescript(SCHEMA)
        cols = [r["name"] for r in c.execute("PRAGMA table_info(users)")]
        if "admin" not in cols:
            c.execute("ALTER TABLE users ADD COLUMN admin INTEGER DEFAULT 0")


def hash_pw(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)


def set_user(username, password, admin=None):
    """Create a user or reset their password. `admin` None keeps the existing role (new users default to normal)."""
    salt = secrets.token_bytes(16)
    with db() as c:
        c.execute("INSERT INTO users (username, salt, hash, created, admin) VALUES (?,?,?,?,?) "
                  "ON CONFLICT(username) DO UPDATE SET salt=excluded.salt, hash=excluded.hash, "
                  "admin=CASE WHEN ? IS NULL THEN admin ELSE ? END",
                  (username, salt, hash_pw(password, salt), time.time(), 1 if admin else 0,
                   None if admin is None else 1, 1 if admin else 0))
    forget_logins()


def is_admin(username):
    with db() as c:
        row = c.execute("SELECT admin FROM users WHERE username=?", (username,)).fetchone()
    return bool(row and row["admin"])


def forget_logins():
    with _auth_lock:
        _auth_cache.clear()


_auth_cache = {}
_auth_lock = threading.Lock()


def check_login(username, password):
    key = (username, hashlib.sha256(password.encode()).hexdigest())
    with _auth_lock:
        if _auth_cache.get(key, 0) > time.time():
            return True
    with db() as c:
        row = c.execute("SELECT salt, hash FROM users WHERE username=?", (username,)).fetchone()
    # Always do the hash work so unknown users and wrong passwords take the same time.
    salt = row["salt"] if row else b"\0" * 16
    ok = hmac.compare_digest(hash_pw(password, salt), row["hash"] if row else b"\0" * 32) and row is not None
    if ok:
        with _auth_lock:
            _auth_cache[key] = time.time() + 300
    else:
        time.sleep(0.5)
    return ok


_fails = {}
_fails_lock = threading.Lock()


def _recent(key):
    now = time.time()
    lst = [t for t in _fails.get(key, []) if now - t < FAIL_WINDOW]
    if lst:
        _fails[key] = lst
    else:
        _fails.pop(key, None)
    return lst


def throttled(ip, username):
    with _fails_lock:
        return len(_recent(("ip", ip))) >= MAX_FAILS_IP or len(_recent(("user", username))) >= MAX_FAILS_USER


def record_fail(ip, username):
    with _fails_lock:
        for key in (("ip", ip), ("user", username)):
            _recent(key)
            _fails.setdefault(key, []).append(time.time())


def drop_privileges():
    """Started as root so an existing data volume can be handed to the unprivileged user, then run as that user."""
    if os.getuid() != 0:
        return
    for root, _dirs, files in os.walk(DATA_DIR):
        for n in [root] + [os.path.join(root, f) for f in files]:
            try:
                os.chown(n, RUN_UID, RUN_UID)
            except OSError:
                pass
    os.setgroups([])
    os.setgid(RUN_UID)
    os.setuid(RUN_UID)


_events = queue.Queue()
_seen = {}


def first_seen(key, ttl):
    """True the first time `key` is seen within `ttl` seconds (used to avoid logging every request)."""
    now = time.time()
    with _fails_lock:
        if len(_seen) > 5000:
            _seen.clear()
        if now - _seen.get(key, 0) > ttl:
            _seen[key] = now
            return True
    return False


def log_event(user, ip, client, etype, detail=""):
    sys.stderr.write("EVENT %-16s user=%s ip=%s client=%s %s\n" % (etype, user, ip, client, detail))
    _events.put((time.time(), user, ip, client, etype, detail))


def _event_worker():
    n = 0
    while True:
        row = _events.get()
        try:
            with db() as c:
                c.execute("INSERT INTO events (ts, user, ip, client, type, detail) VALUES (?,?,?,?,?,?)", row)
                n += 1
                if n % 200 == 1:
                    c.execute("DELETE FROM events WHERE ts < ?", (time.time() - LOG_KEEP_DAYS * 86400,))
                    c.execute("DELETE FROM events WHERE id <= (SELECT MAX(id) FROM events) - ?", (LOG_MAX_ROWS,))
        except Exception as e:
            sys.stderr.write("event log write failed: %s\n" % e)


def ride_summary(row):
    if row["deleted"]:
        return {"id": row["id"], "deleted": True}
    d = json.loads(row["data"])
    d.pop("samples", None)
    d.pop("feedback", None)
    d["hasFit"] = row["fit"] is not None
    d["deleted"] = False
    return d


CSP = ("default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")


class Handler(BaseHTTPRequestHandler):
    server_version = "SummitRoad"
    timeout = 30          # drop slow or stalled connections

    def client_kind(self):
        return "app" if self.headers.get("X-Requested-With") == "SummitRoad" else "browser"

    def ev(self, user, etype, detail=""):
        log_event(user, self.client_ip(), self.client_kind(), etype, detail)

    def client_ip(self):
        if TRUST_PROXY:
            ip = self.headers.get("CF-Connecting-IP") or (self.headers.get("X-Forwarded-For") or "").split(",")[0].strip()
            if ip:
                return ip
        return self.client_address[0]

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # ---- helpers
    def send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        if ctype.startswith("text/html"):
            self.send_header("Content-Security-Policy", CSP)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def user(self):
        # State-changing requests must carry a custom header. A web page on another site cannot add it without
        # a CORS preflight, which this server never allows, so forged cross-site requests are rejected.
        if self.command in ("POST", "PUT", "DELETE") and self.headers.get("X-Requested-With") != "SummitRoad":
            self.send(403, {"error": "missing X-Requested-With header"})
            return None
        ip = self.client_ip()
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                u, _, p = base64.b64decode(h[6:]).decode().partition(":")
                if throttled(ip, u):
                    if first_seen(("throttle", ip), 300):
                        log_event(u[:40], ip, self.client_kind(), "throttled", "too many failed logins")
                    self.send(429, {"error": "too many failed logins, try again later"}, extra={"Retry-After": "300"})
                    return None
                if check_login(u, p):
                    if first_seen(("login", u, ip, self.client_kind()), 1800):
                        self.ev(u, "login")
                    return u
                record_fail(ip, u)
                sys.stderr.write("AUTH FAIL ip=%s user=%r\n" % (ip, u[:40]))
                log_event(u[:40], ip, self.client_kind(), "login_failed")
            except Exception:
                pass
        self.send(401, {"error": "login required"}, extra={"WWW-Authenticate": 'Basic realm="SummitRoad", charset="UTF-8"'})
        return None

    def body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if n < 0 or n > MAX_BODY:
            return None
        return self.rfile.read(n)

    def route(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        return [p for p in path.split("/") if p]

    # ---- verbs
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parts = self.route()
        u = self.user()
        if not u:
            return
        if not parts:
            return self.send(200, DASHBOARD, "text/html; charset=utf-8")
        if parts[:1] != ["api"]:
            return self.send(404, {"error": "not found"})
        parts = parts[1:]
        with db() as c:
            if parts == ["ping"]:
                return self.send(200, {"ok": True, "user": u, "server": VERSION, "admin": is_admin(u)})
            if parts == ["rides"]:
                if first_seen(("sync", u, self.client_ip(), self.client_kind()), 60):
                    self.ev(u, "sync" if self.client_kind() == "app" else "dashboard_view")
                rows = c.execute("SELECT id, data, deleted, fit FROM rides WHERE user=? ORDER BY date DESC", (u,)).fetchall()
                return self.send(200, [ride_summary(r) for r in rows])
            if len(parts) in (2, 3) and parts[0] == "rides" and UUID_RE.match(parts[1]):
                row = c.execute("SELECT * FROM rides WHERE user=? AND id=?", (u, parts[1].upper())).fetchone()
                if not row:
                    return self.send(404, {"error": "no such ride"})
                if row["deleted"]:
                    return self.send(410, {"error": "deleted"})
                if len(parts) == 2:
                    return self.send(200, row["data"])
                if parts[2] == "fit":
                    if row["fit"] is None:
                        return self.send(404, {"error": "no fit file"})
                    return self.send(200, bytes(row["fit"]), "application/octet-stream",
                                     {"Content-Disposition": 'attachment; filename="%s.fit"' % row["id"]})
            if len(parts) == 2 and parts[0] == "docs" and parts[1] in DOC_NAMES:
                row = c.execute("SELECT data, updated, deleted FROM docs WHERE user=? AND name=?", (u, parts[1])).fetchone()
                if not row:
                    return self.send(404, {"error": "none"})
                return self.send(200, {"updated": row["updated"], "deleted": bool(row["deleted"]),
                                       "data": json.loads(row["data"]) if row["data"] else None})
            if parts == ["log"]:
                q = parse_qs(urlparse(self.path).query)
                try:
                    limit = max(1, min(1000, int(q.get("limit", ["200"])[0])))
                except ValueError:
                    limit = 200
                who = q.get("user", [""])[0] if is_admin(u) else u
                if who:
                    rows = c.execute("SELECT ts, user, ip, client, type, detail FROM events WHERE user=? ORDER BY id DESC LIMIT ?", (who, limit)).fetchall()
                else:
                    rows = c.execute("SELECT ts, user, ip, client, type, detail FROM events ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
                return self.send(200, [dict(r) for r in rows])
            if parts == ["users"]:
                if not is_admin(u):
                    return self.send(403, {"error": "admin only"})
                rows = c.execute(
                    "SELECT u.username, u.admin, (SELECT COUNT(*) FROM rides r WHERE r.user=u.username AND r.deleted=0) AS rides "
                    "FROM users u ORDER BY u.username").fetchall()
                return self.send(200, [{"username": r["username"], "admin": bool(r["admin"]), "rides": r["rides"]} for r in rows])
            if parts == ["ftp"]:
                rows = c.execute("SELECT id, date, ftp, method FROM ftp WHERE user=? ORDER BY date", (u,)).fetchall()
                return self.send(200, [dict(r) for r in rows])
        self.send(404, {"error": "not found"})

    def do_PUT(self):
        parts = self.route()
        u = self.user()
        if not u:
            return
        data = self.body()
        if data is None:
            return self.send(413, {"error": "too large"})
        if len(parts) == 3 and parts[:2] == ["api", "docs"] and parts[2] in DOC_NAMES:
            try:
                obj = json.loads(data)
                updated = float(obj["updated"])
                deleted = bool(obj.get("deleted"))
                payload = json.dumps(obj.get("data"))
            except Exception as e:
                return self.send(400, {"error": "bad document: %s" % e})
            with db() as c:
                row = c.execute("SELECT updated FROM docs WHERE user=? AND name=?", (u, parts[2])).fetchone()
                if row and row["updated"] >= updated:        # the stored copy is newer (or identical): keep it
                    return self.send(200, {"applied": False, "updated": row["updated"]})
                c.execute("INSERT INTO docs (user, name, data, updated, deleted) VALUES (?,?,?,?,?) "
                          "ON CONFLICT(user, name) DO UPDATE SET data=excluded.data, updated=excluded.updated, deleted=excluded.deleted",
                          (u, parts[2], payload, updated, 1 if deleted else 0))
            self.ev(u, "plan_cleared" if (parts[2] == "plan" and deleted) else parts[2] + "_updated")
            return self.send(200, {"applied": True, "updated": updated})
        if len(parts) < 3 or parts[0] != "api" or not UUID_RE.match(parts[2]):
            return self.send(404, {"error": "not found"})
        rid = parts[2].upper()
        with db() as c:
            if parts[1] == "rides" and len(parts) == 3:
                try:
                    obj = json.loads(data)
                    if str(obj["id"]).upper() != rid:
                        raise ValueError("id mismatch")
                    date = str(obj["date"])
                except Exception as e:
                    return self.send(400, {"error": "bad ride json: %s" % e})
                row = c.execute("SELECT deleted FROM rides WHERE user=? AND id=?", (u, rid)).fetchone()
                if row and row["deleted"]:
                    return self.send(410, {"error": "deleted"})
                self.ev(u, "ride_updated" if row else "ride_added",
                        "%s (%s)" % (str(obj.get("workoutName", ""))[:60], date[:10]))
                c.execute("INSERT INTO rides (user, id, date, data, updated) VALUES (?,?,?,?,?) "
                          "ON CONFLICT(user, id) DO UPDATE SET date=excluded.date, data=excluded.data, updated=excluded.updated",
                          (u, rid, date, data.decode(), time.time()))
                return self.send(200, {"ok": True})
            if parts[1] == "rides" and len(parts) == 4 and parts[3] == "fit":
                cur = c.execute("UPDATE rides SET fit=? WHERE user=? AND id=? AND deleted=0", (data, u, rid))
                if cur.rowcount == 0:
                    return self.send(404, {"error": "upload the ride before its fit file"})
                return self.send(200, {"ok": True})
            if parts[1] == "ftp" and len(parts) == 3:
                try:
                    obj = json.loads(data)
                    if not c.execute("SELECT 1 FROM ftp WHERE user=? AND id=?", (u, rid)).fetchone():
                        self.ev(u, "ftp_added", "%s W (%s)" % (int(float(obj["ftp"])), str(obj.get("method", ""))[:30]))
                    c.execute("INSERT INTO ftp (user, id, date, ftp, method) VALUES (?,?,?,?,?) "
                              "ON CONFLICT(user, id) DO UPDATE SET date=excluded.date, ftp=excluded.ftp, method=excluded.method",
                              (u, rid, str(obj["date"]), float(obj["ftp"]), str(obj.get("method", ""))))
                except Exception as e:
                    return self.send(400, {"error": "bad ftp json: %s" % e})
                return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        parts = self.route()
        u = self.user()
        if not u:
            return
        raw = self.body()
        if raw is None:
            return self.send(413, {"error": "too large"})
        try:
            obj = json.loads(raw or b"{}")
        except ValueError:
            return self.send(400, {"error": "bad json"})
        if parts == ["api", "password"]:                       # change your own password
            old, new = str(obj.get("old", "")), str(obj.get("new", ""))
            if not check_login(u, old):
                self.ev(u, "password_change_failed", "wrong current password")
                return self.send(403, {"error": "current password is wrong"})
            if len(new) < MIN_PW:
                return self.send(400, {"error": "new password must be at least %d characters" % MIN_PW})
            set_user(u, new)
            self.ev(u, "password_changed")
            return self.send(200, {"ok": True})
        if parts[:2] == ["api", "users"]:
            if not is_admin(u):
                return self.send(403, {"error": "admin only"})
            if len(parts) == 2:                                # add a user
                name, pw = str(obj.get("username", "")).strip(), str(obj.get("password", ""))
                if not USER_RE.match(name):
                    return self.send(400, {"error": "username: 1-32 letters, numbers, . _ -"})
                if len(pw) < MIN_PW:
                    return self.send(400, {"error": "password must be at least %d characters" % MIN_PW})
                with db() as c:
                    if c.execute("SELECT 1 FROM users WHERE username=?", (name,)).fetchone():
                        return self.send(409, {"error": "that user already exists"})
                set_user(name, pw, bool(obj.get("admin")))
                self.ev(u, "user_added", name + (" (admin)" if obj.get("admin") else ""))
                return self.send(200, {"ok": True})
            if len(parts) == 4 and parts[3] == "password":     # reset someone's password
                name, pw = parts[2], str(obj.get("new", ""))
                if len(pw) < MIN_PW:
                    return self.send(400, {"error": "password must be at least %d characters" % MIN_PW})
                with db() as c:
                    if not c.execute("SELECT 1 FROM users WHERE username=?", (name,)).fetchone():
                        return self.send(404, {"error": "no such user"})
                set_user(name, pw)
                self.ev(u, "password_reset", "for " + name)
                return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})

    def do_DELETE(self):
        parts = self.route()
        u = self.user()
        if not u:
            return
        if len(parts) == 3 and parts[:2] == ["api", "users"]:   # remove a user and all their data
            if not is_admin(u):
                return self.send(403, {"error": "admin only"})
            name = parts[2]
            if name == u:
                return self.send(400, {"error": "you cannot delete yourself"})
            with db() as c:
                c.execute("DELETE FROM rides WHERE user=?", (name,))
                c.execute("DELETE FROM ftp WHERE user=?", (name,))
                c.execute("DELETE FROM docs WHERE user=?", (name,))
                cur = c.execute("DELETE FROM users WHERE username=?", (name,))
            forget_logins()
            if cur.rowcount:
                self.ev(u, "user_deleted", name)
            return self.send(200 if cur.rowcount else 404, {"ok": cur.rowcount > 0})
        if len(parts) == 3 and parts[:2] == ["api", "rides"] and UUID_RE.match(parts[2]):
            rid = parts[2].upper()
            with db() as c:
                self.ev(u, "ride_deleted", rid[:8])
                c.execute("INSERT INTO rides (user, id, date, data, deleted, updated) VALUES (?,?,'', '', 1, ?) "
                          "ON CONFLICT(user, id) DO UPDATE SET deleted=1, data='', fit=NULL, updated=excluded.updated",
                          (u, rid, time.time()))
            return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})


DASHBOARD = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SummitRoad</title>
<style>
:root{--bg:#0e0e10;--card:#1b1b1f;--line:#2c2c33;--fg:#ececf0;--mut:#8b8b96;--accent:#9e52f2;--green:#4cc38a}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px -apple-system,system-ui,sans-serif}
header{display:flex;align-items:baseline;gap:12px;padding:18px 24px;border-bottom:1px solid var(--line)}
.logo{font-size:22px;font-style:italic}.logo b{color:var(--accent);font-weight:800}.logo span{font-weight:300}
main{max-width:1100px;margin:0 auto;padding:20px 24px 60px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:20px}
.tile,.card{background:var(--card);border-radius:10px;padding:14px 16px}
.tile .v{font-size:26px;font-weight:700}.tile .l{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:12px;margin-bottom:20px}
h2{font-size:16px;margin:0 0 10px}table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);white-space:nowrap}
th{color:var(--mut);font-size:12px;text-transform:uppercase}tbody tr{cursor:pointer}tbody tr:hover{background:#25252b}
.score{color:var(--green);font-weight:600}a{color:var(--accent)}svg{width:100%;height:auto;display:block}
.muted{color:var(--mut)}.scroll{overflow-x:auto}#detail{display:none}
input[type=text],input[type=password]{background:#111114;color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:7px 10px;margin:0 6px 6px 0}
.row{display:flex;flex-wrap:wrap;align-items:center}.msg{margin-top:6px;font-size:13px}.ok{color:var(--green)}.err{color:#e5484d}
nav{display:flex;gap:4px;margin-left:12px}nav a{color:var(--mut);text-decoration:none;padding:6px 12px;border-radius:6px}nav a.on{color:var(--fg);background:#2c2c33}
.fb li{margin:4px 0}button{background:#2c2c33;color:var(--fg);border:0;border-radius:6px;padding:6px 12px;cursor:pointer}
</style></head><body>
<header><div class="logo"><b>SUMMIT</b><span>ROAD</span></div><nav><a href="#" id="navDash">Dashboard</a><a href="#settings" id="navSettings">Settings</a></nav><div class="muted" id="who" style="margin-left:auto"></div><div class="muted" id="ver"></div></header>
<main>
<div id="pageDash">
<div class="tiles" id="tiles"></div>
<div class="grid"><div class="card"><h2>FTP history</h2><div id="ftp"></div></div>
<div class="card"><h2>Weekly TSS (last 12 weeks)</h2><div id="weekly"></div></div></div>
<div class="card" id="detail"><div style="display:flex;justify-content:space-between"><h2 id="dtitle"></h2><button onclick="document.getElementById('detail').style.display='none'">Close</button></div>
<div id="dmeta" class="muted"></div><div id="dchart"></div><ul class="fb" id="dfb"></ul><div id="dlinks"></div></div>
<div class="card" style="margin-top:20px"><h2>Rides</h2><div class="scroll"><table><thead><tr>
<th>Date</th><th>Workout</th><th>Time</th><th>Avg W</th><th>NP</th><th>TSS</th><th>HR</th><th>Score</th></tr></thead><tbody id="rows"></tbody></table></div></div>
</div>
<div id="pageSettings" style="display:none"><h1 style="font-size:22px;margin:0 0 16px">Settings</h1>
<div class="card"><h2>Change password</h2>
<div class="row"><input type="password" id="pwold" placeholder="Current password"><input type="password" id="pwnew" placeholder="New password (min 10)"><input type="password" id="pwnew2" placeholder="Repeat new password"><button onclick="changePw()">Change password</button></div>
<div id="pwmsg" class="msg"></div></div>
<div class="card" id="usersCard" style="display:none;margin-top:20px"><h2>Users (admin)</h2>
<div class="scroll"><table><thead><tr><th>User</th><th>Role</th><th>Rides</th><th></th></tr></thead><tbody id="users"></tbody></table></div>
<h2 style="margin-top:16px">Add a user</h2>
<div class="row"><input type="text" id="nuname" placeholder="Username"><input type="password" id="nupw" placeholder="Password (min 10)"><label class="muted" style="margin-right:10px"><input type="checkbox" id="nuadmin"> admin</label><button onclick="addUser()">Add user</button></div>
<div id="umsg" class="msg"></div></div>


<div class="card" style="margin-top:20px"><div style="display:flex;justify-content:space-between;align-items:center"><h2>Activity log</h2>
<div><select id="logUser" style="display:none;background:#111114;color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:6px"></select> <button onclick="loadLog()">Refresh</button></div></div>
<div class="scroll"><table><thead><tr><th>Time</th><th>User</th><th>Event</th><th>From</th><th>Details</th></tr></thead><tbody id="logRows"></tbody></table></div>
<div class="muted" style="margin-top:8px;font-size:12px">Showing the latest 200 events. Kept for 90 days.</div></div>
</div>
</main>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtT=s=>{s=Math.round(s);const h=Math.floor(s/3600),m=Math.floor(s%3600/60);return h?h+':'+String(m).padStart(2,'0')+'h':m+' min'};
const fmtD=d=>new Date(d).toLocaleDateString(undefined,{year:'numeric',month:'short',day:'numeric'});
function line(pts,w,h,color,pad){ // pts: [[x,y]] already scaled to 0..1
  return '<polyline fill="none" stroke="'+color+'" stroke-width="2" points="'+pts.map(p=>(pad+p[0]*(w-2*pad)).toFixed(1)+','+(h-pad-p[1]*(h-2*pad)).toFixed(1)).join(' ')+'"/>'}
async function api(p){const r=await fetch(location.origin+p);if(!r.ok)throw new Error(p+' '+r.status);return r.json()}
async function call(method,p,body){const r=await fetch(location.origin+p,{method,headers:{'Content-Type':'application/json','X-Requested-With':'SummitRoad'},body:body?JSON.stringify(body):undefined});
  let j={};try{j=await r.json()}catch(e){}if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j}
function say(id,text,good){const e=$(id);e.textContent=text;e.className='msg '+(good?'ok':'err')}
async function changePw(){
  const o=$('pwold').value,n=$('pwnew').value;
  if(n!==$('pwnew2').value)return say('pwmsg','The new passwords do not match.');
  try{await call('POST','/api/password',{old:o,new:n});['pwold','pwnew','pwnew2'].forEach(i=>$(i).value='');
    say('pwmsg','Password changed. Your browser may ask you to sign in again, and the SummitRoad app needs the new password (Settings > Home Server > Update Login).',true)}
  catch(e){say('pwmsg',e.message)}}
async function loadUsers(){
  const us=await api('/api/users');$('usersCard').style.display='block';
  $('users').innerHTML=us.map(u=>'<tr style="cursor:default"><td>'+esc(u.username)+'</td><td>'+(u.admin?'admin':'user')+'</td><td>'+u.rides+'</td><td>'
    +'<button data-u="'+esc(u.username)+'" onclick="resetPw(this.dataset.u)">Reset password</button> '
    +(u.username===me?'':'<button data-u="'+esc(u.username)+'" onclick="delUser(this.dataset.u)">Delete</button>')+'</td></tr>').join('')}
async function addUser(){
  try{await call('POST','/api/users',{username:$('nuname').value,password:$('nupw').value,admin:$('nuadmin').checked});
    $('nuname').value=$('nupw').value='';$('nuadmin').checked=false;say('umsg','User added.',true);loadUsers()}
  catch(e){say('umsg',e.message)}}
async function resetPw(name){
  const n=prompt('New password for '+name+' (min 10 characters):');if(!n)return;
  try{await call('POST','/api/users/'+encodeURIComponent(name)+'/password',{new:n});say('umsg','Password reset for '+name+'.',true)}
  catch(e){say('umsg',e.message)}}
async function delUser(name){
  if(!confirm('Delete user '+name+' and ALL of their rides and FTP history? This cannot be undone.'))return;
  try{await call('DELETE','/api/users/'+encodeURIComponent(name));say('umsg','Deleted '+name+'.',true);loadUsers()}
  catch(e){say('umsg',e.message)}}
let me='';
const EV={login:'Signed in',login_failed:'Failed sign-in',throttled:'Blocked (too many failures)',sync:'App synced',dashboard_view:'Viewed dashboard',ride_added:'Ride uploaded',ride_updated:'Ride updated',ride_deleted:'Ride deleted',plan_updated:'Training plan synced',plan_cleared:'Training plan cleared',settings_updated:'Settings synced',ftp_added:'FTP result added',password_changed:'Password changed',password_change_failed:'Password change failed',password_reset:'Password reset',user_added:'User added',user_deleted:'User deleted'};
async function loadLog(){
  const sel=$('logUser');const who=sel.style.display==='none'?'':sel.value;
  const rows=await api('/api/log?limit=200'+(who?'&user='+encodeURIComponent(who):''));
  $('logRows').innerHTML=rows.map(r=>'<tr style="cursor:default"><td>'+new Date(r.ts*1000).toLocaleString()+'</td><td>'+esc(r.user)+'</td><td>'+esc(EV[r.type]||r.type)+'</td><td>'+esc(r.client)+' · '+esc(r.ip)+'</td><td class="muted">'+esc(r.detail)+'</td></tr>').join('')||'<tr><td colspan="5" class="muted">Nothing logged yet.</td></tr>'}
async function initLog(isAdmin){
  if(isAdmin){const us=await api('/api/users');const sel=$('logUser');sel.innerHTML='<option value="">All users</option>'+us.map(u=>'<option>'+esc(u.username)+'</option>').join('');sel.style.display='inline-block';sel.onchange=loadLog}
  loadLog()}
function route(){const st=location.hash==='#settings';
  $('pageDash').style.display=st?'none':'block';$('pageSettings').style.display=st?'block':'none';
  $('navDash').className=st?'':'on';$('navSettings').className=st?'on':'';window.scrollTo(0,0)}
window.addEventListener('hashchange',route);route();
async function load(){
  const [rides,ftp,meInfo]=await Promise.all([api('/api/rides'),api('/api/ftp'),api('/api/ping')]);
  me=meInfo.user;$('ver').textContent='server v'+meInfo.server;$('who').textContent='signed in as '+me+(meInfo.admin?' (admin)':'');if(meInfo.admin)loadUsers();initLog(meInfo.admin);
  const live=rides.filter(r=>!r.deleted);
  const tot=live.reduce((a,r)=>({s:a.s+r.durationSeconds,t:a.t+r.tss,k:a.k+r.kj}),{s:0,t:0,k:0});
  const cur=ftp.length?ftp[ftp.length-1].ftp:null;
  $('tiles').innerHTML=[['Rides',live.length],['Ride time',fmtT(tot.s)],['Total TSS',Math.round(tot.t)],['Energy',Math.round(tot.k)+' kJ'],['Current FTP',cur?Math.round(cur)+' W':'—']]
    .map(([l,v])=>'<div class="tile"><div class="v">'+v+'</div><div class="l">'+l+'</div></div>').join('');
  // FTP chart
  if(ftp.length){const W=520,H=200,P=28,vs=ftp.map(f=>f.ftp),lo=Math.min(...vs)-10,hi=Math.max(...vs)+10,t0=+new Date(ftp[0].date),t1=Math.max(+new Date(ftp[ftp.length-1].date),t0+1);
    const pts=ftp.map(f=>[(+new Date(f.date)-t0)/(t1-t0),(f.ftp-lo)/(hi-lo)]);
    $('ftp').innerHTML='<svg viewBox="0 0 '+W+' '+H+'">'+line(pts,W,H,'#9e52f2',P)+pts.map((p,i)=>'<circle cx="'+(P+p[0]*(W-2*P))+'" cy="'+(H-P-p[1]*(H-2*P))+'" r="4" fill="#9e52f2"><title>'+Math.round(ftp[i].ftp)+' W · '+fmtD(ftp[i].date)+' · '+esc(ftp[i].method)+'</title></circle>').join('')
      +'<text x="4" y="14" fill="#8b8b96" font-size="11">'+Math.round(hi)+' W</text><text x="4" y="'+(H-6)+'" fill="#8b8b96" font-size="11">'+Math.round(lo)+' W</text></svg>'}
  else $('ftp').innerHTML='<div class="muted">No FTP results yet.</div>';
  // weekly TSS
  const now=new Date(),mon=new Date(now);mon.setHours(0,0,0,0);mon.setDate(mon.getDate()-((mon.getDay()+6)%7));
  const wk=[...Array(12)].map((_,i)=>({start:new Date(+mon-(11-i)*7*864e5),tss:0}));
  live.forEach(r=>{const d=new Date(r.date);for(let i=11;i>=0;i--){if(d>=wk[i].start){wk[i].tss+=r.tss;break}}});
  const mx=Math.max(50,...wk.map(w=>w.tss)),W=520,H=200,P=28,bw=(W-2*P)/12;
  $('weekly').innerHTML='<svg viewBox="0 0 '+W+' '+H+'">'+wk.map((w,i)=>{const h=(H-2*P)*w.tss/mx;return '<rect x="'+(P+i*bw+3)+'" y="'+(H-P-h)+'" width="'+(bw-6)+'" height="'+h+'" fill="#9e52f2" rx="2"><title>'+w.start.toLocaleDateString()+': '+Math.round(w.tss)+' TSS</title></rect>'}).join('')
    +'<text x="4" y="14" fill="#8b8b96" font-size="11">'+Math.round(mx)+'</text></svg>';
  // ride table
  $('rows').innerHTML=live.map(r=>'<tr onclick="show(\''+r.id+'\')"><td>'+fmtD(r.date)+'</td><td>'+esc(r.workoutName)+'</td><td>'+fmtT(r.durationSeconds)+'</td><td>'+Math.round(r.avgPower)+'</td><td>'+Math.round(r.np)+'</td><td>'+Math.round(r.tss)+'</td><td>'+(r.avgHR??'—')+'</td><td class="score">'+(r.score?Math.round(r.score.total):'—')+'</td></tr>').join('')||'<tr><td colspan="8" class="muted">No rides yet.</td></tr>';
}
async function show(id){
  const r=await api('/api/rides/'+id),s=r.samples||[];
  $('detail').style.display='block';$('dtitle').textContent=r.workoutName+' · '+fmtD(r.date);
  $('dmeta').textContent=fmtT(r.durationSeconds)+' · avg '+Math.round(r.avgPower)+' W · NP '+Math.round(r.np)+' W · TSS '+Math.round(r.tss)+' · IF '+(r.intensityFactor||0).toFixed(2)+(r.avgHR?' · HR '+r.avgHR+' avg / '+r.maxHR+' max':'')+(r.avgCadence?' · '+r.avgCadence+' rpm':'');
  if(s.length>1){const W=1000,H=260,P=30,n=s.length-1,mp=Math.max(100,...s.map(x=>Math.max(x.power,x.target||0)))*1.1,mh=Math.max(...s.map(x=>x.hr||0),1);
    const sm=s.map((x,i)=>{let a=0,c=0;for(let j=Math.max(0,i-4);j<=i;j++){a+=s[j].power;c++}return a/c});
    const tg=s.map((x,i)=>[i/n,(x.target||0)/mp]),pw=sm.map((v,i)=>[i/n,v/mp]),hr=s.map((x,i)=>[i/n,(x.hr||0)/(mh*1.1)]);
    $('dchart').innerHTML='<svg viewBox="0 0 '+W+' '+H+'">'+line(tg,W,H,'#555566',P)+line(pw,W,H,'#9e52f2',P)+(mh>1?line(hr,W,H,'#e5484d',P):'')+'<text x="4" y="14" fill="#8b8b96" font-size="11">'+Math.round(mp)+' W</text></svg><div class="muted">Power (purple), target (grey), heart rate (red)</div>'}
  else $('dchart').innerHTML='';
  $('dfb').innerHTML=(r.feedback||[]).map(f=>'<li>'+esc(f)+'</li>').join('');
  $('dlinks').innerHTML=r.hasFit===false?'':'<a href="/api/rides/'+id+'/fit">Download .FIT</a>';
  $('detail').scrollIntoView({behavior:'smooth'});
}
load().catch(e=>{$('tiles').innerHTML='<div class="tile">Could not load: '+esc(e.message)+'</div>'});
</script></body></html>"""


def main():
    init_db()
    args = sys.argv[1:]
    if args[:1] == ["adduser"] and len(args) >= 2:
        make_admin = "--admin" in args
        rest = [a for a in args[1:] if a != "--admin"]
        pw = rest[1] if len(rest) > 1 else getpass.getpass("Password: ")
        if not pw:
            sys.exit("Password cannot be empty")
        set_user(rest[0], pw, True if make_admin else None)
        print("User '%s' saved%s." % (rest[0], " (admin)" if make_admin else ""))
        return
    if args[:1] == ["users"]:
        with db() as c:
            for r in c.execute("SELECT username FROM users ORDER BY username"):
                print(r["username"])
        return
    u, p = os.environ.get("SUMMITROAD_USER"), os.environ.get("SUMMITROAD_PASSWORD")
    if u and p:
        with db() as c:
            exists = c.execute("SELECT 1 FROM users WHERE username=?", (u,)).fetchone()
        if not exists:
            set_user(u, p, True)
            print("Created admin user '%s'." % u)
        else:
            with db() as c:       # the user named in the environment is always the admin
                c.execute("UPDATE users SET admin=1 WHERE username=?", (u,))
    with db() as c:
        if c.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0:
            print("WARNING: no users exist. Set SUMMITROAD_USER and SUMMITROAD_PASSWORD, or run: "
                  "docker exec -it summitroad python server.py adduser NAME --admin")
    drop_privileges()
    threading.Thread(target=_event_worker, daemon=True).start()
    print("SummitRoad server %s listening on :%d (data: %s, uid %d, trust proxy: %s)"
          % (VERSION, PORT, DATA_DIR, os.getuid(), TRUST_PROXY))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
