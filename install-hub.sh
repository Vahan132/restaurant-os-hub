#!/usr/bin/env bash
# EDGE-PKG-3-UBUNTU - Restaurant OS Edge Hub installer (Ubuntu / Debian-family).
#
# One command to install and start the hub on an Ubuntu mini-PC:
#   * installs Docker Engine + the compose plugin if absent,
#   * downloads the public compose + env template from the GitHub Release,
#   * generates the required auth secrets into .env.edge (nothing to hand-edit),
#   * opens the LAN port in ufw (only if the firewall is active),
#   * pulls the public image and brings the stack up,
#   * installs a systemd unit so the hub returns on power-on, unattended.
#
# No registry credentials are ever needed (the image is public). The hub's
# identity + keys arrive later, when you pair it at /setup.
#
# Recommended (download, review, then run as root):
#   curl -fsSLO https://raw.githubusercontent.com/Vahan132/restaurant-os-hub/main/install-hub.sh
#   sudo bash install-hub.sh
#
# Options (flags or env vars):
#   --tag edge-v0.1.0   (TAG)        image release to PIN (EDGE_IMAGE_TAG)
#   --repo owner/repo   (REPO)       PUBLIC repo holding the dist files
#   --branch main       (BRANCH)     branch to fetch the raw dist files from
#   --port 3001         (PORT)       LAN port the hub serves on
#   --dir /opt/restaurant-os (INSTALL_DIR)
#   --cloud-url URL     (CLOUD_URL)  optional platform base URL
set -euo pipefail

TAG="${TAG:-edge-v0.1.0}"
REPO="${REPO:-Vahan132/restaurant-os-hub}"
BRANCH="${BRANCH:-main}"
PORT="${PORT:-3001}"
INSTALL_DIR="${INSTALL_DIR:-/opt/restaurant-os}"
CLOUD_URL="${CLOUD_URL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --dir) INSTALL_DIR="$2"; shift 2;;
    --cloud-url) CLOUD_URL="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

log() { printf '\033[36m[hub]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[hub] %s\033[0m\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root:  sudo bash install-hub.sh" >&2
  exit 1
fi

# ---- 1. Docker Engine + compose plugin --------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine (official convenience script)..."
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  log "Installing the docker compose plugin..."
  apt-get update -y && apt-get install -y docker-compose-plugin
fi
# Ensure the daemon is enabled (boot) and running now.
systemctl enable --now docker >/dev/null 2>&1 || true

# ---- 2. Files ----------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
asset() { # asset <name> <outfile>
  # Fetch from the PUBLIC hub repo's RAW URL: no auth (public repo), the file keeps
  # its real name (no `default.` prefix that Release-asset downloads add to leading-
  # dot files like .env.edge.example), and no Release needs to exist. The image
  # version is pinned separately via --tag (EDGE_IMAGE_TAG).
  local url="https://raw.githubusercontent.com/$REPO/$BRANCH/$1"
  log "downloading $1 ..."
  curl -fsSL "$url" -o "$2"
}
asset docker-compose.edge.yml "$INSTALL_DIR/docker-compose.edge.yml"
[ -f "$INSTALL_DIR/.env.edge.example" ] || asset .env.edge.example "$INSTALL_DIR/.env.edge.example"

# ---- 3. Environment + secrets -----------------------------------------------
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24
  else head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
set_env() { # set_env <KEY> <VALUE>  (update-or-append in .env.edge)
  local key="$1" val="$2" file="$INSTALL_DIR/.env.edge"
  if grep -qE "^\s*${key}=" "$file"; then
    sed -i "s|^\s*${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}
if [ ! -f "$INSTALL_DIR/.env.edge" ]; then
  cp "$INSTALL_DIR/.env.edge.example" "$INSTALL_DIR/.env.edge"
  log "Generating auth secrets into .env.edge ..."
  for k in JWT_ACCESS_SECRET JWT_REFRESH_SECRET CONSUMER_JWT_ACCESS_SECRET CONSUMER_JWT_REFRESH_SECRET; do
    set_env "$k" "$(gen_secret)"
  done
  set_env EDGE_IMAGE_TAG "$TAG"
  set_env PORT "$PORT"
  [ -n "$CLOUD_URL" ] && set_env CLOUD_URL "$CLOUD_URL"
  chmod 600 "$INSTALL_DIR/.env.edge"
else
  log ".env.edge already exists - keeping your settings (not regenerating secrets)."
fi

# ---- 4. Firewall (only if ufw is active) ------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "ufw is active - allowing TCP $PORT ..."
  ufw allow "${PORT}/tcp" >/dev/null || true
fi

# ---- 5. Bring the stack up ---------------------------------------------------
log "Pulling the public image and starting the hub ..."
docker compose -f docker-compose.edge.yml --env-file .env.edge pull
docker compose -f docker-compose.edge.yml --env-file .env.edge up -d

# ---- 6. systemd boot-on-power ------------------------------------------------
UNIT_SRC="$(dirname "$0")/edge-hub.service"
UNIT_DST="/etc/systemd/system/edge-hub.service"
if [ -f "$UNIT_SRC" ]; then
  sed "s|__INSTALL_DIR__|${INSTALL_DIR}|g" "$UNIT_SRC" > "$UNIT_DST"
else
  # Fallback: write the unit inline if the template isn't next to the installer.
  cat > "$UNIT_DST" <<UNIT
[Unit]
Description=Restaurant OS Edge Hub (docker compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose -f docker-compose.edge.yml --env-file .env.edge up -d
ExecStop=/usr/bin/docker compose -f docker-compose.edge.yml --env-file .env.edge stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT
fi
systemctl daemon-reload
systemctl enable --now edge-hub.service >/dev/null 2>&1 || systemctl enable edge-hub.service
log "systemd unit 'edge-hub.service' enabled - the hub will start on boot."

# ---- 7. Where to go next -----------------------------------------------------
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
log "Done. The hub is starting."
echo "  On this machine : http://localhost:${PORT}/setup"
[ -n "$LAN_IP" ] && echo "  From a tablet   : http://${LAN_IP}:${PORT}/setup"
echo
echo "Open that page, enter your pairing code, and the hub takes over from there."
