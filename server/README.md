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
Connect. The app offers to upload your existing rides and FTP history to that profile. After that:

- new rides, deleted rides and FTP results sync automatically,
- the app downloads anything new from the server each time it starts,
- **Sync Now** does a full two-way sync.

macOS only allows plain `http://` to local addresses: use an IP address, a `.local` name or a name without dots.

## Users and passwords

The user in `docker-compose.yml` (`SUMMITROAD_USER`) is the **admin**. Sign in to the dashboard in a browser:

- **Everyone** can change their own password in the Account box.
- **The admin** also sees a Users box to add users (optionally as admins), reset anyone's password, and delete a
  user (this removes all of that user's rides and FTP history).
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

## Security notes

- The server speaks plain HTTP, so keep it on your home network. If you ever expose it, put it behind a
  reverse proxy that adds HTTPS.
- Passwords are stored as salted PBKDF2 hashes. Change the example password in `docker-compose.yml` before
  first start.
- API: `GET/PUT /api/rides/<id>` (+ `/fit`), `DELETE /api/rides/<id>`, `GET/PUT /api/ftp/<id>`, `GET /api/ping`,
  `POST /api/password`, and admin-only `GET/POST /api/users`, `POST /api/users/<name>/password`, `DELETE /api/users/<name>`.
  All use HTTP Basic auth.
