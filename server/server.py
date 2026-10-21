#!/usr/bin/env python3
"""SummitRoad home server: stores rides, FTP history and .FIT files per user, and serves a browser dashboard.

Standard library only. Data lives in $SUMMITROAD_DATA (default /data).
  python server.py                      run the server
  python server.py adduser NAME [PASS] [--admin]  create a user or reset their password (prompts if PASS omitted)
  python server.py users                list users
  python server.py resetmfa NAME        turn two-factor off for a user (lost phone)
"""
import base64, getpass, hashlib, hmac, http.cookies, json, os, queue, re, secrets, sqlite3, struct, sys, threading, time
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
SESSION_COOKIE = "sr_session"
SESSION_LONG = 30 * 86400    # "keep me signed in"
SESSION_SHORT = 12 * 3600
DOC_NAMES = ("plan", "settings")
try:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "qrcode.js"), "rb") as _f:
        QR_JS = _f.read()      # MIT-licensed QR generator (Kazuhiko Arase), served to the sign-in setup screen
except OSError:
    QR_JS = b""   # small synced documents: newest change wins
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
CREATE TABLE IF NOT EXISTS mfa (user TEXT PRIMARY KEY, secret TEXT, enabled INTEGER DEFAULT 0, last_step INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS recovery (user TEXT, hash TEXT, PRIMARY KEY (user, hash));
CREATE TABLE IF NOT EXISTS app_passwords (id INTEGER PRIMARY KEY AUTOINCREMENT, user TEXT, name TEXT, salt TEXT, hash TEXT, created REAL, last_used REAL);
CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY, user TEXT, created REAL, expires REAL, ip TEXT);
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


# ---- two-factor sign-in (TOTP, RFC 6238: compatible with Google/Microsoft Authenticator, Authy, 1Password...)

def totp_at(secret, t, step=30, digits=6):
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    mac = hmac.new(key, struct.pack(">Q", int(t // step)), hashlib.sha1).digest()
    o = mac[-1] & 15
    return str((int.from_bytes(mac[o:o + 4], "big") & 0x7FFFFFFF) % (10 ** digits)).zfill(digits)


def new_totp_secret():
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def mfa_enabled(username):
    with db() as c:
        row = c.execute("SELECT enabled FROM mfa WHERE user=?", (username,)).fetchone()
    return bool(row and row["enabled"])


def verify_totp(username, secret, code, now=None):
    """True if `code` is the current (+/- one 30 s step) code and has not been used before."""
    code = re.sub(r"\D", "", code or "")
    if len(code) != 6:
        return False
    cur = int((now or time.time()) // 30)
    with db() as c:
        row = c.execute("SELECT last_step FROM mfa WHERE user=?", (username,)).fetchone()
        last = (row["last_step"] if row else 0) or 0
        for d in (0, -1, 1):
            step = cur + d
            if step > last and hmac.compare_digest(totp_at(secret, step * 30), code):
                c.execute("UPDATE mfa SET last_step=? WHERE user=?", (step, username))
                return True
    return False


def _norm_rc(code):
    return re.sub(r"[^0-9a-f]", "", (code or "").lower())


def make_recovery_codes(username):
    codes = []
    with db() as c:
        c.execute("DELETE FROM recovery WHERE user=?", (username,))
        for _ in range(10):
            h = secrets.token_hex(5)
            codes.append("%s-%s" % (h[:5], h[5:]))
            c.execute("INSERT INTO recovery (user, hash) VALUES (?,?)", (username, hashlib.sha256(h.encode()).hexdigest()))
    return codes


def use_recovery(username, code):
    n = _norm_rc(code)
    if len(n) != 10:
        return False
    with db() as c:
        return c.execute("DELETE FROM recovery WHERE user=? AND hash=?", (username, hashlib.sha256(n.encode()).hexdigest())).rowcount == 1


def recovery_left(username):
    with db() as c:
        return c.execute("SELECT COUNT(*) FROM recovery WHERE user=?", (username,)).fetchone()[0]


def verify_second_factor(username, code):
    """Returns "totp", "recovery" or None."""
    with db() as c:
        row = c.execute("SELECT secret, enabled FROM mfa WHERE user=?", (username,)).fetchone()
    if not row or not row["enabled"]:
        return None
    if verify_totp(username, row["secret"], code):
        return "totp"
    if use_recovery(username, code):
        return "recovery"
    return None


def clear_mfa(username):
    with db() as c:
        c.execute("DELETE FROM mfa WHERE user=?", (username,))
        c.execute("DELETE FROM recovery WHERE user=?", (username,))
    forget_logins()


# Half-finished sign-ins: password accepted, waiting for the second factor.
_tickets = {}


def make_ticket(username, remember):
    tok = secrets.token_urlsafe(24)
    now = time.time()
    with _fails_lock:
        for k in [k for k, v in _tickets.items() if v["exp"] < now]:
            del _tickets[k]
        _tickets[hashlib.sha256(tok.encode()).hexdigest()] = {"user": username, "remember": remember, "exp": now + 300, "tries": 0}
    return tok


def get_ticket(tok):
    with _fails_lock:
        t = _tickets.get(hashlib.sha256((tok or "").encode()).hexdigest())
        return t if t and t["exp"] > time.time() else None


def drop_ticket(tok):
    with _fails_lock:
        _tickets.pop(hashlib.sha256((tok or "").encode()).hexdigest(), None)


# ---- app passwords: long random passwords for the Mac app, usable when two-factor is on

APP_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"


def create_app_password(username, name):
    pw = "-".join("".join(secrets.choice(APP_ALPHABET) for _ in range(4)) for _ in range(4))
    salt = secrets.token_hex(8)
    with db() as c:
        c.execute("INSERT INTO app_passwords (user, name, salt, hash, created) VALUES (?,?,?,?,?)",
                  (username, name[:60] or "App", salt, hashlib.sha256((salt + pw).encode()).hexdigest(), time.time()))
    return pw


def check_app_password(username, password):
    if not re.fullmatch(r"[a-z0-9]{4}(-[a-z0-9]{4}){3}", password or ""):
        return False
    with db() as c:
        for r in c.execute("SELECT id, salt, hash, last_used FROM app_passwords WHERE user=?", (username,)).fetchall():
            if hmac.compare_digest(hashlib.sha256((r["salt"] + password).encode()).hexdigest(), r["hash"]):
                if not r["last_used"] or time.time() - r["last_used"] > 60:
                    c.execute("UPDATE app_passwords SET last_used=? WHERE id=?", (time.time(), r["id"]))
                return True
    return False


def check_basic(username, password):
    """HTTP Basic (the Mac app): an app password always works; the account password only while two-factor is off."""
    key = ("basic", username, hashlib.sha256(password.encode()).hexdigest())
    with _auth_lock:
        if _auth_cache.get(key, 0) > time.time():
            return True
    ok = check_app_password(username, password)
    if not ok:
        if mfa_enabled(username):
            time.sleep(0.5)
        else:
            ok = check_login(username, password)
    if ok:
        with _auth_lock:
            _auth_cache[key] = time.time() + 300
    return ok


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


def _tok_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_session(username, ip, ttl):
    token = secrets.token_urlsafe(32)
    now = time.time()
    with db() as c:
        c.execute("DELETE FROM sessions WHERE expires < ?", (now,))
        c.execute("INSERT INTO sessions (token, user, created, expires, ip) VALUES (?,?,?,?,?)",
                  (_tok_hash(token), username, now, now + ttl, ip))
    return token


def session_user(token):
    if not token:
        return None
    with db() as c:
        row = c.execute("SELECT user, expires FROM sessions WHERE token=?", (_tok_hash(token),)).fetchone()
        if not row or row["expires"] < time.time():
            return None
        if not c.execute("SELECT 1 FROM users WHERE username=?", (row["user"],)).fetchone():
            return None
        return row["user"]


def end_session(token):
    if token:
        with db() as c:
            c.execute("DELETE FROM sessions WHERE token=?", (_tok_hash(token),))


def end_user_sessions(username):
    with db() as c:
        c.execute("DELETE FROM sessions WHERE user=?", (username,))


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

    def session_token(self):
        raw = self.headers.get("Cookie", "")
        if not raw:
            return None
        try:
            jar = http.cookies.SimpleCookie(raw)
            return jar[SESSION_COOKIE].value if SESSION_COOKIE in jar else None
        except http.cookies.CookieError:
            return None

    def cookie_header(self, token, max_age=None):
        parts = ["%s=%s" % (SESSION_COOKIE, token), "Path=/", "HttpOnly", "SameSite=Strict"]
        if max_age is not None:
            parts.append("Max-Age=%d" % max_age)
        if "https" in (self.headers.get("X-Forwarded-Proto", "") + self.headers.get("CF-Visitor", "")).lower():
            parts.append("Secure")
        return "; ".join(parts)

    def user(self, silent=False):
        """The signed-in username, from a session cookie (browser) or HTTP Basic (the Mac app). With `silent`, an
        unauthenticated request just returns None instead of sending an error."""
        # State-changing requests must carry a custom header. A web page on another site cannot add it without
        # a CORS preflight, which this server never allows, so forged cross-site requests are rejected.
        self.auth_kind = None
        if not silent and self.command in ("POST", "PUT", "DELETE") and self.headers.get("X-Requested-With") != "SummitRoad":
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
                    if not silent:
                        self.send(429, {"error": "too many failed logins, try again later"}, extra={"Retry-After": "300"})
                    return None
                if check_basic(u, p):
                    self.auth_kind = "basic"
                    if first_seen(("login", u, ip, self.client_kind()), 1800):
                        self.ev(u, "login")
                    return u
                record_fail(ip, u)
                sys.stderr.write("AUTH FAIL ip=%s user=%r\n" % (ip, u[:40]))
                log_event(u[:40], ip, self.client_kind(), "login_failed")
            except Exception:
                pass
        else:
            su = session_user(self.session_token())
            if su:
                self.auth_kind = "session"
                return su
        if not silent:
            self.send(401, {"error": "login required"})
        return None

    def need_session(self):
        """Account management is only for the website: an app password (or the Mac app's login) cannot do it."""
        if getattr(self, "auth_kind", None) != "session":
            self.send(403, {"error": "this action is only available when signed in on the website"})
            return False
        return True

    def finish_login(self, username, remember, ip, how):
        token = new_session(username, ip, SESSION_LONG if remember else SESSION_SHORT)
        log_event(username, ip, "browser", "login", how + (" (kept signed in)" if remember else ""))
        return self.send(200, {"ok": True, "user": username},
                         extra={"Set-Cookie": self.cookie_header(token, SESSION_LONG if remember else None)})

    def do_login_mfa(self):
        if self.headers.get("X-Requested-With") != "SummitRoad":
            return self.send(403, {"error": "missing X-Requested-With header"})
        try:
            obj = json.loads(self.body() or b"{}")
            ticket, code = str(obj.get("ticket", "")), str(obj.get("code", ""))
        except Exception:
            return self.send(400, {"error": "bad request"})
        ip = self.client_ip()
        t = get_ticket(ticket)
        if not t:
            return self.send(401, {"error": "Your sign-in timed out. Please start again.", "expired": True})
        u = t["user"]
        if throttled(ip, u):
            return self.send(429, {"error": "Too many failed attempts. Please wait a few minutes and try again."},
                             extra={"Retry-After": "300"})
        how = verify_second_factor(u, code)
        if not how:
            t["tries"] += 1
            record_fail(ip, u)
            log_event(u, ip, "browser", "mfa_failed", "wrong code")
            if t["tries"] >= 5:
                drop_ticket(ticket)
                return self.send(401, {"error": "Too many wrong codes. Please sign in again.", "expired": True})
            return self.send(401, {"error": "That code didn't work. Check the time on your phone and try the next code."})
        drop_ticket(ticket)
        if how == "recovery":
            log_event(u, ip, "browser", "recovery_code_used", "%d left" % recovery_left(u))
        return self.finish_login(u, t["remember"], ip, "signed in with a recovery code" if how == "recovery" else "signed in with 2FA")

    def do_login(self):
        if self.headers.get("X-Requested-With") != "SummitRoad":
            return self.send(403, {"error": "missing X-Requested-With header"})
        raw = self.body()
        try:
            obj = json.loads(raw or b"{}")
            u, p = str(obj.get("username", "")).strip(), str(obj.get("password", ""))
        except Exception:
            return self.send(400, {"error": "bad request"})
        ip = self.client_ip()
        if throttled(ip, u):
            if first_seen(("throttle", ip), 300):
                log_event(u[:40], ip, "browser", "throttled", "too many failed logins")
            return self.send(429, {"error": "Too many failed attempts. Please wait a few minutes and try again."},
                             extra={"Retry-After": "300"})
        if not (u and p and check_login(u, p)):
            record_fail(ip, u)
            sys.stderr.write("AUTH FAIL ip=%s user=%r\n" % (ip, u[:40]))
            log_event(u[:40], ip, "browser", "login_failed")
            return self.send(401, {"error": "Wrong username or password."})
        if mfa_enabled(u):                  # password was right: now ask for the 6-digit code
            return self.send(200, {"mfa": True, "ticket": make_ticket(u, bool(obj.get("remember")))})
        return self.finish_login(u, bool(obj.get("remember")), ip, "signed in")

    def do_logout(self):
        if self.headers.get("X-Requested-With") != "SummitRoad":
            return self.send(403, {"error": "missing X-Requested-With header"})
        token = self.session_token()
        who = session_user(token)
        end_session(token)
        if who:
            log_event(who, self.client_ip(), "browser", "logout")
        self.send(200, {"ok": True}, extra={"Set-Cookie": self.cookie_header("", 0)})

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
        if parts == ["qrcode.js"]:
            return self.send(200, QR_JS, "application/javascript; charset=utf-8")
        if not parts:                     # the page itself: dashboard when signed in, otherwise the sign-in page
            return self.send(200, DASHBOARD if self.user(silent=True) else LOGIN_PAGE, "text/html; charset=utf-8")
        u = self.user()
        if not u:
            return
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
                if not self.need_session():
                    return
                if not is_admin(u):
                    return self.send(403, {"error": "admin only"})
                rows = c.execute(
                    "SELECT u.username, u.admin, (SELECT COUNT(*) FROM rides r WHERE r.user=u.username AND r.deleted=0) AS rides, "
                    "COALESCE((SELECT enabled FROM mfa m WHERE m.user=u.username), 0) AS mfa "
                    "FROM users u ORDER BY u.username").fetchall()
                return self.send(200, [{"username": r["username"], "admin": bool(r["admin"]), "rides": r["rides"], "mfa": bool(r["mfa"])} for r in rows])
            if parts == ["mfa"]:
                if not self.need_session():
                    return
                return self.send(200, {"enabled": mfa_enabled(u), "recoveryLeft": recovery_left(u)})
            if parts == ["apppasswords"]:
                if not self.need_session():
                    return
                rows = c.execute("SELECT id, name, created, last_used FROM app_passwords WHERE user=? ORDER BY id", (u,)).fetchall()
                return self.send(200, [dict(r) for r in rows])
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
        if parts == ["api", "login"]:
            return self.do_login()
        if parts == ["api", "login", "mfa"]:
            return self.do_login_mfa()
        if parts == ["api", "logout"]:
            return self.do_logout()
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
            if not self.need_session():
                return
            old, new = str(obj.get("old", "")), str(obj.get("new", ""))
            if not check_login(u, old):
                self.ev(u, "password_change_failed", "wrong current password")
                return self.send(403, {"error": "current password is wrong"})
            if len(new) < MIN_PW:
                return self.send(400, {"error": "new password must be at least %d characters" % MIN_PW})
            set_user(u, new)
            end_user_sessions(u)                      # everyone signed in as this user has to sign in again
            self.ev(u, "password_changed")
            return self.send(200, {"ok": True, "signedOut": True}, extra={"Set-Cookie": self.cookie_header("", 0)})
        if parts[:2] == ["api", "mfa"] or parts[:2] == ["api", "apppasswords"]:
            if not self.need_session():
                return
            ip = self.client_ip()
            if parts == ["api", "mfa", "setup"]:
                if mfa_enabled(u):
                    return self.send(409, {"error": "two-factor is already on"})
                secret = new_totp_secret()
                with db() as c:
                    c.execute("INSERT INTO mfa (user, secret, enabled, last_step) VALUES (?,?,0,0) "
                              "ON CONFLICT(user) DO UPDATE SET secret=excluded.secret, enabled=0, last_step=0", (u, secret))
                uri = "otpauth://totp/SummitRoad:%s?secret=%s&issuer=SummitRoad&algorithm=SHA1&digits=6&period=30" % (u, secret)
                return self.send(200, {"secret": secret, "uri": uri})
            if parts == ["api", "mfa", "enable"]:
                with db() as c:
                    row = c.execute("SELECT secret, enabled FROM mfa WHERE user=?", (u,)).fetchone()
                if not row or row["enabled"]:
                    return self.send(409, {"error": "start the setup first"})
                if throttled(ip, u) or not verify_totp(u, row["secret"], str(obj.get("code", ""))):
                    record_fail(ip, u)
                    log_event(u, ip, "browser", "mfa_failed", "wrong code during setup")
                    return self.send(400, {"error": "That code didn't match. Check the code in your app and try again."})
                with db() as c:
                    c.execute("UPDATE mfa SET enabled=1 WHERE user=?", (u,))
                codes = make_recovery_codes(u)
                with db() as c:
                    has_app = c.execute("SELECT 1 FROM app_passwords WHERE user=?", (u,)).fetchone()
                app = None
                if not has_app:                                # keep the Mac app working: give it its own password
                    app = {"name": "Mac app", "password": create_app_password(u, "Mac app")}
                forget_logins()
                self.ev(u, "mfa_enabled")
                return self.send(200, {"ok": True, "recoveryCodes": codes, "appPassword": app})
            if parts in (["api", "mfa", "disable"], ["api", "mfa", "recovery"]):
                if not mfa_enabled(u):
                    return self.send(409, {"error": "two-factor is not on"})
                if throttled(ip, u):
                    return self.send(429, {"error": "Too many failed attempts. Please wait a few minutes and try again."})
                if not (check_login(u, str(obj.get("password", ""))) and verify_second_factor(u, str(obj.get("code", "")))):
                    record_fail(ip, u)
                    log_event(u, ip, "browser", "mfa_failed", "wrong password or code on " + parts[2])
                    return self.send(403, {"error": "Your password or code was wrong."})
                if parts[2] == "disable":
                    clear_mfa(u)
                    self.ev(u, "mfa_disabled")
                    return self.send(200, {"ok": True})
                codes = make_recovery_codes(u)
                self.ev(u, "recovery_codes_regenerated")
                return self.send(200, {"ok": True, "recoveryCodes": codes})
            if parts == ["api", "apppasswords"]:
                name = str(obj.get("name", "")).strip() or "App"
                pw = create_app_password(u, name)
                self.ev(u, "app_password_created", name[:60])
                return self.send(200, {"ok": True, "name": name[:60], "password": pw})
            return self.send(404, {"error": "not found"})
        if parts[:2] == ["api", "users"]:
            if not self.need_session():
                return
            if not is_admin(u):
                return self.send(403, {"error": "admin only"})
            if len(parts) == 5 and parts[3:] == ["mfa", "reset"]:    # lost phone: admin turns two-factor off for a user
                name = parts[2]
                clear_mfa(name)
                end_user_sessions(name)
                self.ev(u, "mfa_reset", "for " + name)
                return self.send(200, {"ok": True})
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
                end_user_sessions(name)
                self.ev(u, "password_reset", "for " + name)
                return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})

    def do_DELETE(self):
        parts = self.route()
        u = self.user()
        if not u:
            return
        if len(parts) == 3 and parts[:2] == ["api", "apppasswords"]:
            if not self.need_session():
                return
            with db() as c:
                row = c.execute("SELECT name FROM app_passwords WHERE user=? AND id=?", (u, parts[2])).fetchone()
                n = c.execute("DELETE FROM app_passwords WHERE user=? AND id=?", (u, parts[2])).rowcount
            forget_logins()
            if n:
                self.ev(u, "app_password_revoked", (row["name"] if row else "")[:60])
            return self.send(200 if n else 404, {"ok": n > 0})
        if len(parts) == 3 and parts[:2] == ["api", "users"]:   # remove a user and all their data
            if not self.need_session():
                return
            if not is_admin(u):
                return self.send(403, {"error": "admin only"})
            name = parts[2]
            if name == u:
                return self.send(400, {"error": "you cannot delete yourself"})
            with db() as c:
                c.execute("DELETE FROM rides WHERE user=?", (name,))
                c.execute("DELETE FROM ftp WHERE user=?", (name,))
                c.execute("DELETE FROM docs WHERE user=?", (name,))
                c.execute("DELETE FROM sessions WHERE user=?", (name,))
                c.execute("DELETE FROM mfa WHERE user=?", (name,))
                c.execute("DELETE FROM recovery WHERE user=?", (name,))
                c.execute("DELETE FROM app_passwords WHERE user=?", (name,))
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
header{display:flex;align-items:center;gap:12px;padding:18px 24px;border-bottom:1px solid var(--line)}
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
#planWeeks table{table-layout:fixed}#planWeeks td:nth-child(1){width:150px}#planWeeks td:nth-child(3){width:230px}
nav{display:flex;gap:4px;margin-left:12px}nav a{color:var(--mut);text-decoration:none;padding:6px 12px;border-radius:6px}nav a.on{color:var(--fg);background:#2c2c33}
.tip{position:absolute;pointer-events:none;display:none;background:#25252b;border:1px solid var(--line);border-radius:8px;padding:8px 10px;font-size:12px;line-height:1.55;white-space:nowrap;z-index:5}
.secret{margin:8px 0;font-size:16px}code{background:#111114;padding:3px 8px;border-radius:6px;border:1px solid var(--line);font-size:15px}pre{margin:8px 0;background:#111114;padding:10px 12px;border-radius:8px;border:1px solid var(--line)}
.fb li{margin:4px 0}button{background:#2c2c33;color:var(--fg);border:0;border-radius:6px;padding:6px 12px;cursor:pointer}
</style></head><body>
<header><div class="logo"><b>SUMMIT</b><span>ROAD</span></div><nav><a href="#" id="navDash">Dashboard</a><a href="#plan" id="navPlan">Training Plan</a><a href="#settings" id="navSettings">Settings</a></nav><div class="muted" id="who" style="margin-left:auto"></div><div class="muted" id="ver"></div><button onclick="logout()" title="Sign out of this browser">Sign out</button></header>
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
<div id="pagePlan" style="display:none"><h1 style="font-size:22px;margin:0 0 16px">Training Plan</h1>
<div class="tiles" id="planTiles"></div><div id="planWeeks"></div></div>
<div id="pageSettings" style="display:none"><h1 style="font-size:22px;margin:0 0 16px">Settings</h1>
<div class="card"><h2>Change password</h2>
<form class="row" onsubmit="changePw();return false"><input type="text" autocomplete="username" style="display:none" tabindex="-1" aria-hidden="true"><input type="password" id="pwold" autocomplete="current-password" placeholder="Current password" required><input type="password" id="pwnew" autocomplete="new-password" placeholder="New password (min 10)" required><input type="password" id="pwnew2" autocomplete="new-password" placeholder="Repeat new password" required><button type="submit">Change password</button></form>
<div id="pwmsg" class="msg"></div></div>
<div class="card" id="mfaCard" style="margin-top:20px"><h2>Two-factor authentication</h2><div id="mfaBody" class="muted">Loading…</div><div id="mfaMsg" class="msg"></div><div id="mfaCodes"></div></div>
<div class="card" id="appCard" style="margin-top:20px"><h2>App passwords</h2>
<div class="muted" style="margin-bottom:10px">The SummitRoad Mac app signs in with one of these (Settings &gt; Home Server &gt; Update Login). While two-factor is on, your normal password no longer works in the app. You can make one per computer and revoke it any time.</div>
<div class="scroll"><table><thead><tr><th>Name</th><th>Created</th><th>Last used</th><th></th></tr></thead><tbody id="appRows"></tbody></table></div>
<form class="row" onsubmit="makeAppPw();return false" autocomplete="off" style="margin-top:10px"><input type="text" id="appName" value="Mac app" placeholder="Name, e.g. Kevin's MacBook" autocomplete="off"><button type="submit">Create app password</button></form><div id="appMsg" class="msg"></div></div>
<div class="card" id="usersCard" style="display:none;margin-top:20px"><h2>Users (admin)</h2>
<div class="scroll"><table><thead><tr><th>User</th><th>Role</th><th>Rides</th><th>2FA</th><th></th></tr></thead><tbody id="users"></tbody></table></div>
<h2 style="margin-top:16px">Add a user</h2>
<form class="row" onsubmit="addUser();return false" autocomplete="off"><input type="text" id="nuname" autocomplete="off" placeholder="Username" required><input type="password" id="nupw" autocomplete="new-password" placeholder="Password (min 10)" required><label class="muted" style="margin-right:10px"><input type="checkbox" id="nuadmin"> admin</label><button type="submit">Add user</button></form>
<div id="umsg" class="msg"></div></div>


<div class="card" style="margin-top:20px"><div style="display:flex;justify-content:space-between;align-items:center"><h2>Activity log</h2>
<div><select id="logUser" style="display:none;background:#111114;color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:6px"></select> <button onclick="loadLog()">Refresh</button></div></div>
<div class="scroll"><table><thead><tr><th>Time</th><th>User</th><th>Event</th><th>From</th><th>Details</th></tr></thead><tbody id="logRows"></tbody></table></div>
<div class="muted" style="margin-top:8px;font-size:12px">Showing the latest 200 events. Kept for 90 days.</div></div>
</div>
</main>
<script src="/qrcode.js"></script>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtT=s=>{s=Math.round(s);const h=Math.floor(s/3600),m=Math.floor(s%3600/60);return h?h+':'+String(m).padStart(2,'0')+'h':m+' min'};
const fmtD=d=>new Date(d).toLocaleDateString(undefined,{year:'numeric',month:'short',day:'numeric'});
function line(pts,w,h,color,pad){ // pts: [[x,y]] already scaled to 0..1
  return '<polyline fill="none" stroke="'+color+'" stroke-width="2" points="'+pts.map(p=>(pad+p[0]*(w-2*pad)).toFixed(1)+','+(h-pad-p[1]*(h-2*pad)).toFixed(1)).join(' ')+'"/>'}
async function api(p){const r=await fetch(location.origin+p);if(r.status===401){location.reload();throw new Error('signed out')}if(!r.ok)throw new Error(p+' '+r.status);return r.json()}
async function logout(){try{await call('POST','/api/logout')}catch(e){}location.href='/'}
async function call(method,p,body){const r=await fetch(location.origin+p,{method,headers:{'Content-Type':'application/json','X-Requested-With':'SummitRoad'},body:body?JSON.stringify(body):undefined});
  let j={};try{j=await r.json()}catch(e){}if(r.status===401){location.reload();throw new Error('signed out')}if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j}
function say(id,text,good){const e=$(id);e.textContent=text;e.className='msg '+(good?'ok':'err')}
async function changePw(){
  const o=$('pwold').value,n=$('pwnew').value;
  if(n!==$('pwnew2').value)return say('pwmsg','The new passwords do not match.');
  try{await call('POST','/api/password',{old:o,new:n});['pwold','pwnew','pwnew2'].forEach(i=>$(i).value='');
    say('pwmsg','Password changed. Signing you out so you can sign in with the new one. The SummitRoad app needs the new password too (Settings > Home Server > Update Login).',true);setTimeout(()=>location.href='/',3500)}
  catch(e){say('pwmsg',e.message)}}
async function loadUsers(){
  const us=await api('/api/users');$('usersCard').style.display='block';
  $('users').innerHTML=us.map(u=>'<tr style="cursor:default"><td>'+esc(u.username)+'</td><td>'+(u.admin?'admin':'user')+'</td><td>'+u.rides+'</td><td>'+(u.mfa?'on':'off')+'</td><td>'
    +'<button data-u="'+esc(u.username)+'" onclick="resetPw(this.dataset.u)">Reset password</button> '
    +(u.mfa?'<button data-u="'+esc(u.username)+'" onclick="resetMfa(this.dataset.u)">Reset 2FA</button> ':'')
    +(u.username===me?'':'<button data-u="'+esc(u.username)+'" onclick="delUser(this.dataset.u)">Delete</button>')+'</td></tr>').join('')}
async function resetMfa(name){
  if(!confirm('Turn off two-factor for '+name+'? Use this if they lost their phone. They will be signed out and can set it up again.'))return;
  try{await call('POST','/api/users/'+encodeURIComponent(name)+'/mfa/reset');say('umsg','Two-factor reset for '+name+'.',true);loadUsers()}
  catch(e){say('umsg',e.message)}}
function fmtDT(t){return t?new Date(t*1000).toLocaleString():'never'}
function copyText(t,btn){if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(()=>{btn.textContent='Copied'},()=>{btn.textContent='Select and copy by hand'})}else{btn.textContent='Select and copy by hand'}}
async function loadMfa(){
  try{renderMfa(await api('/api/mfa'))}catch(e){}
  try{await loadApps()}catch(e){}
  if($('usersCard').style.display==='block')loadUsers().catch(()=>{})}
function renderMfa(m){
  $('mfaBody').className='';
  $('mfaBody').innerHTML=m.enabled
   ?'<p class="ok" style="margin-top:0">&#10003; Two-factor is on. '+m.recoveryLeft+' recovery code'+(m.recoveryLeft===1?'':'s')+' left.</p>'
    +'<div class="muted" style="margin-bottom:8px">To change it, confirm with your password and a code from your app (or a recovery code).</div>'
    +'<form class="row" onsubmit="return false" autocomplete="off"><input type="password" id="mfaPw" autocomplete="current-password" placeholder="Your password"><input type="text" id="mfaCode" inputmode="numeric" autocomplete="one-time-code" placeholder="Code" maxlength="12"></form>'
    +'<div class="row"><button type="button" onclick="mfaRecovery()">Make new recovery codes</button><button type="button" onclick="mfaDisable()" style="margin-left:6px">Turn off two-factor</button></div>'
   :'<p style="margin-top:0" class="muted">Adds a second step when you sign in: a 6-digit code from an app such as Google Authenticator, Microsoft Authenticator or Authy. The Mac app will then sign in with an app password instead of your normal password.</p><button type="button" onclick="mfaSetup()">Set up two-factor</button><div id="mfaSetup"></div>'}
async function mfaSetup(){
  try{const r=await call('POST','/api/mfa/setup');
    const q=qrcode(0,'M');q.addData(r.uri);q.make();
    $('mfaSetup').innerHTML='<ol class="muted" style="line-height:1.7"><li>In your authenticator app, add an account and scan this code (or type the key below).</li><li>Enter the 6-digit code the app shows to turn two-factor on.</li></ol>'
      +'<div style="background:#fff;padding:12px;display:inline-block;border-radius:8px">'+q.createSvgTag(6,0)+'</div>'
      +'<div class="muted" style="margin:8px 0">Can&rsquo;t scan? Enter this key: <code>'+r.secret.replace(/(.{4})/g,'$1 ').trim()+'</code></div>'
      +'<form class="row" onsubmit="mfaEnable();return false" autocomplete="off"><input type="text" id="mfaEnableCode" inputmode="numeric" autocomplete="one-time-code" maxlength="8" placeholder="6-digit code" required><button type="submit">Turn on</button></form>';
    say('mfaMsg','',true)}
  catch(e){say('mfaMsg',e.message)}}
function showCodes(codes,app){
  $('mfaCodes').innerHTML=(app?'<div class="card" style="background:#111114;margin-top:12px"><b>Your Mac app now needs an app password</b><div class="muted">In the Mac app open Settings &gt; Home Server, keep your username and paste this as the password, then press Update Login. It is shown only once.</div><div class="secret"><code>'+esc(app.password)+'</code> <button type="button" data-t="'+esc(app.password)+'" onclick="copyText(this.dataset.t,this)">Copy</button></div></div>':'')
   +'<div class="card" style="background:#111114;margin-top:12px"><b>Recovery codes</b><div class="muted">Each works once if you lose your phone. Save them somewhere safe: they will not be shown again.</div><pre>'+codes.map(esc).join('\n')+'</pre><button type="button" data-t="'+esc(codes.join('\n'))+'" onclick="copyText(this.dataset.t,this)">Copy all</button></div>'}
async function mfaEnable(){
  try{const r=await call('POST','/api/mfa/enable',{code:$('mfaEnableCode').value});await loadMfa();showCodes(r.recoveryCodes,r.appPassword);say('mfaMsg','Two-factor is on. Save your recovery codes below.',true)}
  catch(e){say('mfaMsg',e.message)}}
async function mfaRecovery(){
  try{const r=await call('POST','/api/mfa/recovery',{password:$('mfaPw').value,code:$('mfaCode').value});await loadMfa();showCodes(r.recoveryCodes,null);say('mfaMsg','New recovery codes made. The old ones no longer work.',true)}
  catch(e){say('mfaMsg',e.message)}}
async function mfaDisable(){
  if(!confirm('Turn off two-factor? Signing in will only need your password again.'))return;
  try{await call('POST','/api/mfa/disable',{password:$('mfaPw').value,code:$('mfaCode').value});$('mfaCodes').innerHTML='';await loadMfa();say('mfaMsg','Two-factor is off. The Mac app can use your normal password again (app passwords keep working too).',true)}
  catch(e){say('mfaMsg',e.message)}}
async function loadApps(){
  const l=await api('/api/apppasswords');
  $('appRows').innerHTML=l.map(a=>'<tr style="cursor:default"><td>'+esc(a.name)+'</td><td>'+fmtDT(a.created)+'</td><td>'+fmtDT(a.last_used)+'</td><td><button data-id="'+a.id+'" onclick="revokeApp(this.dataset.id)">Revoke</button></td></tr>').join('')||'<tr style="cursor:default"><td colspan="4" class="muted">No app passwords yet.</td></tr>'}
async function makeAppPw(){
  try{const r=await call('POST','/api/apppasswords',{name:$('appName').value});
    $('appMsg').className='msg';$('appMsg').innerHTML='App password for &ldquo;'+esc(r.name)+'&rdquo; (shown only once):<div class="secret"><code>'+esc(r.password)+'</code> <button type="button" data-t="'+esc(r.password)+'" onclick="copyText(this.dataset.t,this)">Copy</button></div>';loadApps()}
  catch(e){say('appMsg',e.message)}}
async function revokeApp(id){
  if(!confirm('Revoke this app password? Anything using it (like the Mac app) will stop signing in.'))return;
  try{await call('DELETE','/api/apppasswords/'+id);say('appMsg','Revoked.',true);loadApps()}catch(e){say('appMsg',e.message)}}
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
const EV={login:'Signed in',login_failed:'Failed sign-in',throttled:'Blocked (too many failures)',sync:'App synced',dashboard_view:'Viewed dashboard',ride_added:'Ride uploaded',ride_updated:'Ride updated',ride_deleted:'Ride deleted',logout:'Signed out',mfa_enabled:'Two-factor turned on',mfa_disabled:'Two-factor turned off',mfa_reset:'Two-factor reset by admin',mfa_failed:'Failed two-factor code',recovery_code_used:'Recovery code used',recovery_codes_regenerated:'New recovery codes made',app_password_created:'App password created',app_password_revoked:'App password revoked',plan_updated:'Training plan synced',plan_cleared:'Training plan cleared',settings_updated:'Settings synced',ftp_added:'FTP result added',password_changed:'Password changed',password_change_failed:'Password change failed',password_reset:'Password reset',user_added:'User added',user_deleted:'User deleted'};
const KIND={endurance:'Endurance',tempo:'Tempo',sweetSpot:'Sweet Spot',threshold:'Threshold',overUnder:'Over-Unders',vo2:'VO2 Max',vo2OnOff:'VO2 Max On-Offs',ftpRamp:'FTP Ramp Test',ftp20:'FTP 20-Minute Test',adhoc:'Workout'};
const GOAL={raiseFTP:'Raise my FTP',timeTrial:'Time trial / sustained power',roadRace:'Road race / criterium',century:'Century / long event',general:'General fitness'};
const PHASE={base:'Base',build:'Build',specialty:'Specialty'};
async function loadPlan(){
  let doc;try{doc=await api('/api/docs/plan')}catch(e){doc=null}
  if(!doc||doc.deleted||!doc.data){$('planTiles').innerHTML='';$('planWeeks').innerHTML='<div class="card muted">No training plan has been synced yet. Build one in the SummitRoad app and it will appear here.</div>';return}
  const p=doc.data,ws=p.workouts||[],today=new Date();today.setHours(0,0,0,0);
  const done=ws.filter(w=>w.completedDate).length,missed=ws.filter(w=>!w.completedDate&&new Date(w.date)<today).length;
  const scores=ws.filter(w=>w.completedScore!=null).map(w=>w.completedScore),avg=scores.length?Math.round(scores.reduce((a,b)=>a+b,0)/scores.length):null;
  const q=p.questionnaire||{},adj=p.levelAdjust||0;
  $('planTiles').innerHTML=[['Goal',GOAL[q.goal]||q.goal||'—'],['Length',(q.weeks||'?')+' weeks · '+(q.weeklyHours||'?')+' h/wk'],['Completed',done+' of '+ws.length],['Missed',missed],['Avg score',avg??'—'],['Start FTP',Math.round(p.startFTP||0)+' W'],['Difficulty adj.',(adj>=0?'+':'')+adj]]
    .map(([l,v])=>'<div class="tile"><div class="v" style="font-size:20px">'+esc(v)+'</div><div class="l">'+l+'</div></div>').join('');
  const byWeek={};ws.forEach(w=>(byWeek[w.week]=byWeek[w.week]||[]).push(w));
  $('planWeeks').innerHTML=Object.keys(byWeek).map(Number).sort((a,b)=>a-b).map(wk=>{
    const items=byWeek[wk].sort((a,b)=>new Date(a.date)-new Date(b.date)),f=items[0];
    const start=new Date(items[0].date),end=new Date(items[items.length-1].date),cur=today>=new Date(+start-6*864e5)&&today<=end;
    return '<div class="card" style="margin-bottom:12px'+(cur?';border:1px solid var(--accent)':'')+'"><h2>Week '+wk+' · '+esc(PHASE[f.phase]||f.phase)+(f.recoveryWeek?' · Recovery':'')+(cur?' <span class="muted">(this week)</span>':'')+'</h2><table><tbody>'
     +items.map(w=>{const isDone=!!w.completedDate,isMissed=!isDone&&new Date(w.date)<today;
       const name=(KIND[w.kind]||w.kind)+(['ftpRamp','ftp20'].includes(w.kind)?'':' · level '+w.level)+(w.kind==='endurance'&&w.minutes?' · '+w.minutes+' min':'')+(w.isLong?' (long)':'');
       const status=isDone?'<span class="score">✓ done'+(w.completedScore!=null?' · score '+Math.round(w.completedScore):'')+'</span>':isMissed?'<span class="err">missed</span>':'<span class="muted">upcoming</span>';
       return '<tr style="cursor:default"><td>'+fmtD(w.date)+'</td><td>'+esc(name)+'</td><td>'+status+'</td></tr>'}).join('')+'</tbody></table></div>'}).join('')
    +'<div class="muted" style="font-size:12px">Last updated '+new Date(doc.updated*1000).toLocaleString()+'. Read-only: edit the plan in the SummitRoad app.</div>'}
async function loadLog(){
  const sel=$('logUser');const who=sel.style.display==='none'?'':sel.value;
  const rows=await api('/api/log?limit=200'+(who?'&user='+encodeURIComponent(who):''));
  $('logRows').innerHTML=rows.map(r=>'<tr style="cursor:default"><td>'+new Date(r.ts*1000).toLocaleString()+'</td><td>'+esc(r.user)+'</td><td>'+esc(EV[r.type]||r.type)+'</td><td>'+esc(r.client)+' · '+esc(r.ip)+'</td><td class="muted">'+esc(r.detail)+'</td></tr>').join('')||'<tr><td colspan="5" class="muted">Nothing logged yet.</td></tr>'}
async function initLog(isAdmin){
  if(isAdmin){const us=await api('/api/users');const sel=$('logUser');sel.innerHTML='<option value="">All users</option>'+us.map(u=>'<option>'+esc(u.username)+'</option>').join('');sel.style.display='inline-block';sel.onchange=loadLog}
  loadLog()}
function route(){const h=location.hash,pg=h==='#settings'?'settings':h==='#plan'?'plan':'dash';
  $('pageDash').style.display=pg==='dash'?'block':'none';$('pagePlan').style.display=pg==='plan'?'block':'none';$('pageSettings').style.display=pg==='settings'?'block':'none';
  $('navDash').className=pg==='dash'?'on':'';$('navPlan').className=pg==='plan'?'on':'';$('navSettings').className=pg==='settings'?'on':'';
  if(pg==='plan')loadPlan();if(pg==='settings')loadMfa();window.scrollTo(0,0)}
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
  if(s.length>1){const W=1000,H=260,P=30,n=s.length-1,mp=Math.max(100,...s.map(x=>Math.max(x.power,x.target||0)))*1.1,mh=Math.max(...s.map(x=>x.hr||0),1),mc=Math.max(...s.map(x=>x.cad||0),1);
    const sm=s.map((x,i)=>{let a=0,c=0;for(let j=Math.max(0,i-4);j<=i;j++){a+=s[j].power;c++}return a/c});
    const tg=s.map((x,i)=>[i/n,(x.target||0)/mp]),pw=sm.map((v,i)=>[i/n,v/mp]),hr=s.map((x,i)=>[i/n,(x.hr||0)/(mh*1.1)]),cd=s.map((x,i)=>[i/n,(x.cad||0)/(mc*1.1)]);
    $('dchart').innerHTML='<div id="cwrap" style="position:relative"><svg id="csvg" viewBox="0 0 '+W+' '+H+'">'+line(tg,W,H,'#555566',P)+line(pw,W,H,'#9e52f2',P)+(mh>1?line(hr,W,H,'#e5484d',P):'')+(mc>1?line(cd,W,H,'#4cc38a',P):'')
      +'<text x="4" y="14" fill="#8b8b96" font-size="11">'+Math.round(mp)+' W</text>'
      +'<line id="hline" x1="0" x2="0" y1="'+P+'" y2="'+(H-P)+'" stroke="#8b8b96" stroke-dasharray="3 3" style="display:none"/>'
      +'<circle id="hpw" r="4.5" fill="#9e52f2" style="display:none"/><circle id="htg" r="3.5" fill="#8b8b99" style="display:none"/><circle id="hhr" r="4" fill="#e5484d" style="display:none"/><circle id="hcd" r="4" fill="#4cc38a" style="display:none"/>'
      +'</svg><div id="tip" class="tip"></div></div><div class="muted">Power (purple), target (grey), heart rate (red), cadence (green); each of heart rate and cadence is scaled to its own maximum. Hover the chart for the values at each point.</div>';
    const svg=$('csvg'),tip=$('tip'),X=i=>P+i/n*(W-2*P),Y=(v,m)=>H-P-v/m*(H-2*P);
    const clock=t=>{t=Math.round(t);const h=Math.floor(t/3600),m=Math.floor(t%3600/60),sec=t%60;return (h?h+':'+String(m).padStart(2,'0'):m)+':'+String(sec).padStart(2,'0')};
    const hide=()=>{tip.style.display='none';['hline','hpw','htg','hhr','hcd'].forEach(i=>$(i).style.display='none')};
    const move=ev=>{
      const rc=svg.getBoundingClientRect(),fx=(ev.clientX-rc.left)/rc.width*W;
      const i=Math.max(0,Math.min(n,Math.round((fx-P)/(W-2*P)*n))),d=s[i],x=X(i);
      $('hline').setAttribute('x1',x);$('hline').setAttribute('x2',x);$('hline').style.display='block';
      const dot=(id,v,m)=>{const e=$(id);if(v==null||!(v>0)){e.style.display='none';return}e.setAttribute('cx',x);e.setAttribute('cy',Y(v,m));e.style.display='block'};
      dot('hpw',sm[i],mp);dot('htg',d.target,mp);dot('hhr',d.hr,mh*1.1);dot('hcd',d.cad,mc*1.1);
      const row=(label,val,color)=>val==null||val===''?'':'<div><span style="color:'+color+'">&#9679;</span> '+label+' <b>'+val+'</b></div>';
      tip.innerHTML='<div class="muted">'+clock(d.t!=null?d.t:i)+' into the ride'+(d.kind?' · '+esc(d.kind):'')+'</div>'
        +row('Power',d.power+' W','#9e52f2')+'<div class="muted" style="margin-left:14px">5 s avg '+Math.round(sm[i])+' W</div>'
        +row('Target',d.target?d.target+' W':null,'#8b8b99')+row('Heart rate',d.hr?d.hr+' bpm':null,'#e5484d')
        +row('Cadence',d.cad?d.cad+' rpm':null,'#4cc38a')+row('Speed',d.speed!=null?d.speed.toFixed(1)+' km/h':null,'#4aa3ff');
      tip.style.display='block';
      const px=x/W*rc.width,tw=tip.offsetWidth;
      tip.style.left=(px+14+tw>rc.width?Math.max(0,px-14-tw):px+14)+'px';tip.style.top='6px';
    };
    svg.addEventListener('pointermove',move);svg.addEventListener('pointerdown',move);svg.addEventListener('pointerleave',hide)}
  else $('dchart').innerHTML='';
  $('dfb').innerHTML=(r.feedback||[]).map(f=>'<li>'+esc(f)+'</li>').join('');
  $('dlinks').innerHTML=r.hasFit===false?'':'<a href="/api/rides/'+id+'/fit">Download .FIT</a>';
  $('detail').scrollIntoView({behavior:'smooth'});
}
load().catch(e=>{$('tiles').innerHTML='<div class="tile">Could not load: '+esc(e.message)+'</div>'});
</script></body></html>"""


LOGIN_PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign in · SummitRoad</title>
<style>
:root{--bg:#0b0b0e;--card:#17171c;--line:#2c2c35;--fg:#ececf0;--mut:#8b8b96;--accent:#9e52f2;--err:#ff6b6f}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;background:radial-gradient(900px 500px at 50% -10%,#2a1650 0%,transparent 70%),var(--bg);color:var(--fg);
  font:15px -apple-system,system-ui,sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;position:relative;overflow:hidden}
.road{position:absolute;left:0;bottom:0;width:100%;height:46%;opacity:.5;pointer-events:none}
.wrap{position:relative;width:100%;max-width:400px}
.logo{text-align:center;font-size:38px;font-style:italic;letter-spacing:.5px;margin-bottom:6px}
.logo b{color:var(--accent);font-weight:800}.logo span{font-weight:300}
.tag{text-align:center;color:var(--mut);margin-bottom:26px}
.card{background:rgba(23,23,28,.92);border:1px solid var(--line);border-radius:16px;padding:26px;box-shadow:0 20px 60px rgba(0,0,0,.5);backdrop-filter:blur(6px)}
label{display:block;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:0 0 6px}
.field{position:relative;margin-bottom:16px}
input[type=text],input[type=password]{width:100%;background:#0f0f13;color:var(--fg);border:1px solid var(--line);border-radius:10px;padding:12px 14px;font-size:16px;outline:none}
input[type=text]:focus,input[type=password]:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(158,82,242,.25)}
.eye{position:absolute;right:8px;top:30px;background:none;border:0;color:var(--mut);cursor:pointer;font-size:13px;padding:6px 8px}
.row{display:flex;align-items:center;gap:8px;margin:2px 0 18px;color:var(--mut);font-size:14px}
button.go{width:100%;border:0;border-radius:10px;padding:13px;font-size:16px;font-weight:600;color:#fff;cursor:pointer;
  background:linear-gradient(135deg,#9e52f2,#7b3fe0)}
button.go:hover{filter:brightness(1.1)}button.go:disabled{opacity:.6;cursor:default}
.err{color:var(--err);min-height:20px;font-size:14px;margin-top:14px;text-align:center}
.foot{text-align:center;color:#55555f;font-size:12px;margin-top:18px}
</style></head><body>
<svg class="road" viewBox="0 0 800 300" preserveAspectRatio="none" aria-hidden="true">
  <polygon points="-40,300 840,300 450,0 350,0" fill="#1c1c22"/>
  <polyline points="40,300 345,0" stroke="#3a3a44" stroke-width="3" fill="none"/>
  <polyline points="760,300 455,0" stroke="#3a3a44" stroke-width="3" fill="none"/>
  <g fill="#9e52f2" opacity=".8"><polygon points="394,0 406,0 410,40 390,40"/><polygon points="386,70 414,70 424,150 376,150"/><polygon points="370,190 430,190 460,300 340,300"/></g>
</svg>
<div class="wrap">
  <div class="logo"><b>SUMMIT</b><span>ROAD</span></div>
  <div class="tag">Your training, at home.</div>
  <form class="card" id="f" onsubmit="return go(event)" autocomplete="on">
    <div id="step1">
    <div class="field"><label for="u">Username</label><input type="text" id="u" name="username" autocomplete="username" autocapitalize="none" spellcheck="false" autofocus required></div>
    <div class="field"><label for="p">Password</label><input type="password" id="p" name="password" autocomplete="current-password" required>
      <button type="button" class="eye" id="eye" onclick="toggle()">Show</button></div>
    <div class="row"><input type="checkbox" id="r" checked><label for="r" style="margin:0;text-transform:none;letter-spacing:0;font-size:14px">Keep me signed in on this device</label></div>
    </div>
    <div id="step2" style="display:none">
      <div style="text-align:center;margin-bottom:14px;color:var(--mut)" id="s2msg">Enter the 6-digit code from your authenticator app.</div>
      <div class="field"><label for="c" id="clabel">Authentication code</label><input type="text" id="c" name="otp" inputmode="numeric" autocomplete="one-time-code" maxlength="12" spellcheck="false"></div>
      <div style="text-align:center;font-size:14px;margin:-6px 0 14px"><a href="#" id="alt" onclick="swapMode();return false" style="color:var(--accent)">Use a recovery code instead</a> &middot; <a href="#" onclick="backToPw();return false" style="color:var(--accent)">Back</a></div>
    </div>
    <button class="go" id="b" type="submit">Sign in</button>
    <div class="err" id="e" role="alert"></div>
  </form>
  <div class="foot">SummitRoad home server</div>
</div>
<script>
const $=id=>document.getElementById(id);
function toggle(){const p=$('p'),show=p.type==='password';p.type=show?'text':'password';$('eye').textContent=show?'Hide':'Show'}
let ticket=null,recovery=false;
function show2(){$('step2').style.display='block';$('step1').style.display='none';$('b').textContent='Verify';$('c').value='';$('c').focus()}
function backToPw(){ticket=null;$('step2').style.display='none';$('step1').style.display='block';$('b').textContent='Sign in';$('e').textContent='';$('p').value='';$('p').focus()}
function swapMode(){recovery=!recovery;$('c').value='';$('c').maxLength=recovery?12:8;$('c').inputMode=recovery?'text':'numeric';
  $('clabel').textContent=recovery?'Recovery code':'Authentication code';$('s2msg').textContent=recovery?'Enter one of your saved recovery codes. Each works once.':'Enter the 6-digit code from your authenticator app.';
  $('alt').textContent=recovery?'Use my authenticator app instead':'Use a recovery code instead';$('c').focus()}
async function post(path,body){const r=await fetch(location.origin+path,{method:'POST',headers:{'Content-Type':'application/json','X-Requested-With':'SummitRoad'},body:JSON.stringify(body)});
  let j={};try{j=await r.json()}catch(x){}return [r,j]}
async function go(ev){
  if(ev)ev.preventDefault();$('e').textContent='';$('b').disabled=true;$('b').textContent='Checking…';
  try{
    if(!ticket){
      const [r,j]=await post('/api/login',{username:$('u').value,password:$('p').value,remember:$('r').checked});
      if(r.ok&&j.mfa){ticket=j.ticket;recovery=true;swapMode();show2();$('b').disabled=false;return false}
      if(r.ok){location.href='/';return false}
      $('e').textContent=j.error||('Sign-in failed ('+r.status+')');$('p').select()
    }else{
      const [r,j]=await post('/api/login/mfa',{ticket:ticket,code:$('c').value});
      if(r.ok){location.href='/';return false}
      if(j.expired){backToPw();$('e').textContent=j.error}else{$('e').textContent=j.error||('Sign-in failed ('+r.status+')');$('c').select()}
    }
  }catch(x){$('e').textContent='Could not reach the server.'}
  $('b').disabled=false;$('b').textContent=ticket?'Verify':'Sign in';return false}
$('c').addEventListener('input',()=>{if(!recovery&&/^\d{6}$/.test($('c').value.replace(/\s/g,'')))go()});
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
    if args[:1] == ["resetmfa"] and len(args) == 2:
        clear_mfa(args[1])
        end_user_sessions(args[1])
        print("Two-factor turned off for '%s'." % args[1])
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
