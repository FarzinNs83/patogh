# Patogh (پاتوق)

A self-hosted place for one community: text channels, voice and video, roles,
friends and direct messages, all on a single server you run yourself.

The first person to open a fresh install sets it up: they name the server and
become its owner. Everyone who registers after that joins the same server.

## Run it locally

Requirements: Node.js 22.12 or newer.

```bash
npm install
npm run dev
```

The web app runs on http://127.0.0.1:5173 and the API on port 3005.

Voice and video need a LiveKit server. Point `LIVEKIT_URL`, `LIVEKIT_API_KEY`
and `LIVEKIT_API_SECRET` in `.env` at one (see `.env.example`).

## install.sh

Installs Patogh on a Linux server with Docker, behind nginx with a Let's
Encrypt certificate, with voice and video (LiveKit):

- installs Docker and the compose plugin (from get.docker.com, or from the
  distro packages if that is unreachable)
- on a server in Iran, Docker Hub, npm and Debian are blocked: the script
  tests local mirrors on the spot and uses the ones that answer
- asks only for the domain (point its DNS at the server first). With ports
  80/443 free it runs the bundled nginx, gets the certificate and renews it
  daily; when another reverse proxy already holds them it switches to proxy
  mode and prints ready-to-paste config for nginx, Caddy and Traefik
- generates the secrets and LiveKit keys once and keeps them on re-runs,
  pulls the prebuilt image (or builds from source when it cannot) and checks
  that `https://<domain>` answers

Clone the repository on the server and run it from there:

```bash
git clone https://github.com/FarzinNs83/patogh.git
cd patogh
./install.sh
```

Then open `https://<domain>`: the first visitor names the server and becomes
its owner. Re-running `install.sh` upgrades the install and keeps its settings.

Show all options:

```bash
./install.sh --help
```

Ports: TCP 80/443, and for voice UDP 3478, TCP 7881 and UDP 50000-60000.

## update.sh

```bash
./update.sh             # snapshot, pull the newest image, restart, verify
./update.sh --check     # is there a newer release? changes nothing
./update.sh --yes       # no confirmation (ssh, cron)
```

It takes a database snapshot first, restarts only the `patogh` container, waits
until it is healthy and checks that the running version changed. If the new
version does not come up, it puts the previous image back.

## backup.sh / restore.sh

```bash
./backup.sh                 # database snapshot to data/backups/
./restore.sh                # list the snapshots, newest first
./restore.sh <snapshot.db>  # restore one; the current database is saved first
```

## deploy.sh

Pushes this checkout from your machine to a server set up with `install.sh`
and rebuilds the image there, for running unreleased code. The server keeps
its `.env`, `data/`, `livekit.yaml` and certificates.

```bash
./deploy.sh                 # asks for the server (user@host)
```

Put `DEPLOY_HOST` and `DEPLOY_PATH` in `./.deploy.local` (git-ignored) to skip
the question.

## Other scripts

- `renew-cert.sh`: renews the certificate and reloads nginx. `install.sh` runs
  it daily from `/etc/cron.d/patogh-certbot`
- `electronbuild.sh`: desktop installers for macOS, Windows and Linux in
  `packages/desktop/installers/`

Each script has `--help`. See `.env.example` for every setting.

## License

AGPL-3.0-only. If you run a modified version for other people, you must offer
them its source code.
