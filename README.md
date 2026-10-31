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

## Deploy

On a Linux server, point your domain's DNS at it and run:

```bash
./install.sh
```

It asks only for the domain. Everything else is automatic: Docker, an HTTPS
certificate (renewed daily), voice and video. On a server in Iran, blocked
downloads (Docker, Docker Hub, npm, Debian) go through local mirrors that are
tested on the spot. Then open `https://your-domain`: the first visitor names
the server and becomes its owner. See `.env.example` for every setting.

## License

AGPL-3.0-only. If you run a modified version for other people, you must offer
them its source code.
