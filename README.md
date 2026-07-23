# Restaurant OS — Edge Hub installer (public)

Everything a restaurant needs to stand up an on-prem **Edge Hub**. All files
here are public — **no GitHub account, no login, no token** required.

Current pinned image: `ghcr.io/vahan132/restaurant-os-edge:edge-v0.1.0`

## Windows

1. Download **`install-hub.bat`** and the `*.ps1` scripts from this page
   (click a file → **Download raw file**, or **Code → Download ZIP**).
2. Put them in one folder and **double-click `install-hub.bat`**.
3. When it prints **"Done. The hub is starting."**, open
   `http://localhost:3001/setup` and enter your pairing code.

Full guide: `EDGE_HUB_WINDOWS_GUIDE.md`.

## Ubuntu / Debian

```bash
curl -fsSLO https://raw.githubusercontent.com/Vahan132/restaurant-os-hub/main/install-hub.sh
sudo bash install-hub.sh
```

Then open `http://localhost:3001/setup` and enter your pairing code.
Full guide: `EDGE_HUB_UBUNTU_GUIDE.md`.

## What the installer fetches (public raw URLs, no auth)

- `https://raw.githubusercontent.com/Vahan132/restaurant-os-hub/main/docker-compose.edge.yml`
- `https://raw.githubusercontent.com/Vahan132/restaurant-os-hub/main/.env.edge.example`

The hub image itself is a public GHCR package, so `docker compose pull`
needs no credentials either.

---

> This repo is generated. The installer/compose/guides are authored in the
> main (private) repo and mirrored here automatically on each `edge-v*`
> release. Don't hand-edit files here — changes are overwritten.
