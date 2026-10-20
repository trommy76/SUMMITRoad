# SummitRoad Home Server (optional)

Stores your rides, FTP history and .FIT files on your own machine so other computers see them, and gives you a
browser dashboard. The SummitRoad app works fine without it.

## Run it

```bash
cd server
# edit docker-compose.yml: set SUMMITROAD_USER and SUMMITROAD_PASSWORD
docker compose up -d --build
```

Open `http://<this-machine>:8787` and sign in. Your data lives in `./data` (a SQLite file), so back that folder up.

## In the app

Settings > Home Server: enter the address (for example `192.168.1.20:8787`), your username and password, and click
Connect. The app offers to upload your existing rides and FTP history to that profile. After that:

- new rides, deleted rides and FTP results sync automatically,
- the app downloads anything new from the server each time it starts,
- **Sync Now** does a full two-way sync.

macOS only allows plain `http://` to local addresses: use an IP address, a `.local` name or a name without dots.

## More users (separate profiles)

Each user has their own login and their own data; nobody sees anyone else's rides.

```bash
docker exec -it summitroad python server.py adduser anna      # prompts for a password
docker exec -it summitroad python server.py users             # list users
```

Running `adduser` for an existing name resets that user's password.

## Security notes

- The server speaks plain HTTP, so keep it on your home network. If you ever expose it, put it behind a
  reverse proxy that adds HTTPS.
- Passwords are stored as salted PBKDF2 hashes. Change the example password in `docker-compose.yml` before
  first start.
- API: `GET/PUT /api/rides/<id>` (+ `/fit`), `DELETE /api/rides/<id>`, `GET/PUT /api/ftp/<id>`, `GET /api/ping`.
  All use HTTP Basic auth.
