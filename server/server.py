#!/usr/bin/env python3
"""SummitRoad home server: stores rides, FTP history and .FIT files per user, and serves a browser dashboard.

Standard library only. Data lives in $SUMMITROAD_DATA (default /data).
  python server.py                      run the server
  python server.py adduser NAME [PASS]  create or update a user (prompts for the password if omitted)
  python server.py users                list users
"""
import base64, getpass, hashlib, hmac, json, os, re, secrets, sqlite3, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

VERSION = "1.0.0"
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
"""


def db():
    c = sqlite3.connect(DB_PATH, timeout=30)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    os.makedirs(DATA_DIR, exist_ok=True)
    with db() as c:
        c.executescript(SCHEMA)


def hash_pw(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 200_000)


def set_user(username, password):
    salt = secrets.token_bytes(16)
    with db() as c:
        c.execute("INSERT INTO users (username, salt, hash, created) VALUES (?,?,?,?) "
                  "ON CONFLICT(username) DO UPDATE SET salt=excluded.salt, hash=excluded.hash",
                  (username, salt, hash_pw(password, salt), time.time()))


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


def ride_summary(row):
    if row["deleted"]:
        return {"id": row["id"], "deleted": True}
    d = json.loads(row["data"])
    d.pop("samples", None)
    d.pop("feedback", None)
    d["hasFit"] = row["fit"] is not None
    d["deleted"] = False
    return d


class Handler(BaseHTTPRequestHandler):
    server_version = "SummitRoad/" + VERSION

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
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def user(self):
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                u, _, p = base64.b64decode(h[6:]).decode().partition(":")
                if check_login(u, p):
                    return u
            except Exception:
                pass
        self.send(401, {"error": "login required"}, extra={"WWW-Authenticate": 'Basic realm="SummitRoad", charset="UTF-8"'})
        return None

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
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
                return self.send(200, {"ok": True, "user": u, "server": VERSION})
            if parts == ["rides"]:
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
                    c.execute("INSERT INTO ftp (user, id, date, ftp, method) VALUES (?,?,?,?,?) "
                              "ON CONFLICT(user, id) DO UPDATE SET date=excluded.date, ftp=excluded.ftp, method=excluded.method",
                              (u, rid, str(obj["date"]), float(obj["ftp"]), str(obj.get("method", ""))))
                except Exception as e:
                    return self.send(400, {"error": "bad ftp json: %s" % e})
                return self.send(200, {"ok": True})
        self.send(404, {"error": "not found"})

    def do_DELETE(self):
        parts = self.route()
        u = self.user()
        if not u:
            return
        if len(parts) == 3 and parts[:2] == ["api", "rides"] and UUID_RE.match(parts[2]):
            rid = parts[2].upper()
            with db() as c:
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
.fb li{margin:4px 0}button{background:#2c2c33;color:var(--fg);border:0;border-radius:6px;padding:6px 12px;cursor:pointer}
</style></head><body>
<header><div class="logo"><b>SUMMIT</b><span>ROAD</span></div><div class="muted" id="who"></div></header>
<main>
<div class="tiles" id="tiles"></div>
<div class="grid"><div class="card"><h2>FTP history</h2><div id="ftp"></div></div>
<div class="card"><h2>Weekly TSS (last 12 weeks)</h2><div id="weekly"></div></div></div>
<div class="card" id="detail"><div style="display:flex;justify-content:space-between"><h2 id="dtitle"></h2><button onclick="document.getElementById('detail').style.display='none'">Close</button></div>
<div id="dmeta" class="muted"></div><div id="dchart"></div><ul class="fb" id="dfb"></ul><div id="dlinks"></div></div>
<div class="card" style="margin-top:20px"><h2>Rides</h2><div class="scroll"><table><thead><tr>
<th>Date</th><th>Workout</th><th>Time</th><th>Avg W</th><th>NP</th><th>TSS</th><th>HR</th><th>Score</th></tr></thead><tbody id="rows"></tbody></table></div></div>
</main>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmtT=s=>{s=Math.round(s);const h=Math.floor(s/3600),m=Math.floor(s%3600/60);return h?h+':'+String(m).padStart(2,'0')+'h':m+' min'};
const fmtD=d=>new Date(d).toLocaleDateString(undefined,{year:'numeric',month:'short',day:'numeric'});
function line(pts,w,h,color,pad){ // pts: [[x,y]] already scaled to 0..1
  return '<polyline fill="none" stroke="'+color+'" stroke-width="2" points="'+pts.map(p=>(pad+p[0]*(w-2*pad)).toFixed(1)+','+(h-pad-p[1]*(h-2*pad)).toFixed(1)).join(' ')+'"/>'}
async function api(p){const r=await fetch(location.origin+p);if(!r.ok)throw new Error(p+' '+r.status);return r.json()}
async function load(){
  const [rides,ftp,me]=await Promise.all([api('/api/rides'),api('/api/ftp'),api('/api/ping')]);
  $('who').textContent='signed in as '+me.user;
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
        pw = args[2] if len(args) > 2 else getpass.getpass("Password: ")
        if not pw:
            sys.exit("Password cannot be empty")
        set_user(args[1], pw)
        print("User '%s' saved." % args[1])
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
            set_user(u, p)
            print("Created user '%s'." % u)
    with db() as c:
        if c.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0:
            print("WARNING: no users exist. Set SUMMITROAD_USER and SUMMITROAD_PASSWORD, or run: "
                  "docker exec -it summitroad python server.py adduser NAME")
    print("SummitRoad server %s listening on :%d (data: %s)" % (VERSION, PORT, DATA_DIR))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
