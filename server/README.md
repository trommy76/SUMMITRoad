# SummitRoad Home Server (optional)

Stores your rides, FTP history and .FIT files on your own machine so other computers see them, and gives you a
browser dashboard. The SummitRoad app works fine without it.

## Run it

GitHub builds the server image automatically (`ghcr.io/trommy76/summitroad-server:latest`, for Intel and ARM), so
the Docker host never has to build anything and needs no git. All it needs is `docker-compose.yml`.

1. Copy [docker-compose.yml](docker-compose.yml) to the Docker host, or paste it into Dockhand / Portainer as a stack.
2. Set `SUMMITROAD_USER` and `SUMMITROAD_PASSWORD` in it.
3. Start it: `docker compose up -d` (or deploy the stack).

Open `http://<this-machine>:8787` and sign in. Data lives in the `summitroad-data` Docker volume, so back that up.
To update: `docker compose pull && docker compose up -d` (or redeploy the stack).

The first time, the package may be private. On GitHub open your profile > Packages > summitroad-server >
Package settings > Change visibility > Public, so the host can pull it without a login.

To build it yourself instead, run `docker build -t summitroad-server server` and use `image: summitroad-server` in the compose file.

## In the app

Settings > Home Server: enter the address (for example `192.168.1.20:8787`), your username and password, and click
Connect. The app offers to upload your existing rides, FTP history, training plan and settings to that profile.
After that:

- new rides, deleted rides and FTP results sync automatically,
- your **training plan** (including completed workouts) and settings (max heart rate, voice cues, auto-upload to
  Strava) sync too: the most recent change wins, so edit on whichever Mac you like. Trainer/strap pairings and the
  Strava login stay per Mac,
- the app downloads anything new from the server each time it starts,
- **Sync Now** does a full two-way sync.

macOS only allows plain `http://` to local addresses: use an IP address, a `.local` name or a name without dots.

## Signing in and out

Browsers get a sign-in page (username, password, "keep me signed in on this device" for 30 days; otherwise the
session lasts 12 hours). Use **Sign out** at the top right of the dashboard to end the session on the server. Sessions
are stored in the server's database as a hash and sent as a secure `HttpOnly`, `SameSite=Strict` cookie (also
`Secure` when the request came in over HTTPS). Changing or resetting a password, or deleting a user, signs that user out
everywhere. The SummitRoad Mac app does not use cookies: it keeps sending its username and password with each
request, so it is unaffected.

## Users and passwords

The user in `docker-compose.yml` (`SUMMITROAD_USER`) is the **admin**. Sign in to the dashboard in a browser:

- **Everyone** can change their own password on the **Settings** page (top menu).
- **The admin** also sees a Users section on Settings to add users (optionally as admins), reset anyone's password,
  and delete a user (this removes all of that user's rides and FTP history).
- Each user has their own login and their own data; nobody sees anyone else's rides.

If you change your password, the SummitRoad app needs the new one: Settings > Home Server > Update Login.

Command-line alternative (also how to recover a forgotten admin password):

```bash
docker exec -it summitroad python server.py adduser anna            # new user, prompts for a password
docker exec -it summitroad python server.py adduser kevin --admin   # reset a password / make an admin
docker exec -it summitroad python server.py users                   # list users
```

The password in `docker-compose.yml` is only used to create the admin the first time. Changing it later does not
change the stored password; use the dashboard or the command above.

## Training plan page

The dashboard has a read-only **Training Plan** page showing the plan synced from the app: goal, progress, missed and
completed workouts with their scores, and every week grouped by phase. Edit the plan in the app.

## Activity log

The server records what happens: sign-ins, failed sign-ins and lockouts, app syncs and dashboard views, rides and FTP
results being added or deleted, password changes and resets, and users being added or removed. Each entry has the time,
user, client (`app` or `browser`) and IP address (the real visitor's IP when behind Cloudflare with
`SUMMITROAD_TRUST_PROXY: "1"`).

- **In the dashboard:** Settings > Activity log. The admin sees everyone (with a user filter); other users see only
  their own activity, including failed attempts on their username.
- **In the container log:** the same events appear as `EVENT ...` lines in `docker logs summitroad`.
- Entries are kept for 90 days (and at most 20,000). Repeated sign-ins and syncs from the same place are logged once
  per 30 minutes / 1 minute so the log stays readable.

## Exposing it to the internet (Cloudflare in front)

The server itself only speaks HTTP, so never publish port 8787 directly. Put HTTPS in front of it:

- **Cloudflare Tunnel (recommended):** run `cloudflared` on the same Docker network and point the tunnel's public
  hostname at `http://summitroad:8787`. Nothing is opened on your router.
- Keep `SUMMITROAD_TRUST_PROXY: "1"` in the compose file so login throttling sees each visitor's real IP
  (from Cloudflare's `CF-Connecting-IP` header). Only use it when the server is reachable **only** through the proxy,
  because otherwise a client could fake that header.
- In the app, enter the address as `https://summitroad.yourdomain.com` in Settings > Home Server.
- Optional extras in Cloudflare: a WAF rate-limiting rule on `/api/*`, and "Always Use HTTPS" + HSTS.

Built-in protections: 10 failed logins per client IP (or 30 per username) in 10 minutes returns HTTP 429 for a while;
writes must carry an `X-Requested-With: SummitRoad` header (blocks forged cross-site requests; the app and dashboard
send it); new passwords must be at least 10 characters; security headers and a content-security policy are set;
slow connections time out; and the container drops from root to an unprivileged user after fixing the data volume's
permissions. Failed logins are written to the container log as `AUTH FAIL ip=... user=...` if you want fail2ban.

Note: someone who deliberately fails 30 logins for your username locks that username out for 10 minutes.

## Security notes

- The server speaks plain HTTP, so keep it on your home network. If you ever expose it, put it behind a
  reverse proxy that adds HTTPS.
- Passwords are stored as salted PBKDF2 hashes. Change the example password in `docker-compose.yml` before
  first start. Writes need an `X-Requested-With: SummitRoad` header, so use app version 1.0.21 or newer with server 1.1.2+.
- API: `GET/PUT /api/rides/<id>` (+ `/fit`), `DELETE /api/rides/<id>`, `GET/PUT /api/ftp/<id>`, `GET /api/ping`,
  `POST /api/password`, and admin-only `GET/POST /api/users`, `POST /api/users/<name>/password`, `DELETE /api/users/<name>`.
  All use HTTP Basic auth.
