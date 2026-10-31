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

## patogh-setup.sh

Installs Patogh on a Linux server (Ubuntu / Debian) with Docker, behind nginx
with a Let's Encrypt certificate, with voice and video (LiveKit):

- asks for the domain and checks that it points to the server
- installs Docker and the compose plugin (from download.docker.com, or from
  the distro packages if that is unreachable)
- on a server in Iran, Docker Hub, npm and Debian are blocked: the script
  tests local mirrors on the spot and uses the ones that answer
- clones the repository to `/opt/patogh`, generates the secrets and LiveKit
  keys once (kept on re-runs), builds the image and starts it on 127.0.0.1
- nginx on the host in front of it (websockets, `/livekit`), a Let's Encrypt
  certificate that renews automatically, and a 2 GB swap file on servers with
  less than 3 GB of RAM (for the build)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/patogh/main/patogh-setup.sh)
```

Then open `https://<domain>` right away: the first visitor names the server
and becomes its owner.

Update to the latest commit: run the same command again. It takes a database
snapshot, pulls, rebuilds and restarts; settings and secrets are kept.

Show all options:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/FarzinNs83/patogh/main/patogh-setup.sh) --help
```

Ports: TCP 80/443, and for voice UDP 3478, TCP 7881 and UDP 50000-60000 (open
them in the provider firewall; `--open-firewall` opens them in ufw). Next to
`dns-setup.sh` from my-scripts, Patogh sits behind its relay on
`127.0.0.1:10446`.

## backup.sh / restore.sh

From `/opt/patogh`:

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
