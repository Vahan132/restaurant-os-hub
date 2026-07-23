#!/usr/bin/env bash
# EDGE-PKG-3-UBUNTU - Update the Restaurant OS Edge Hub to a newer image.
#
# Pulls the newer public image and restarts. The hub keeps serving locally during
# the update, applies any new database migrations on start, and preserves its
# pairing + data on the named volumes. Safe to run during service.
#
#   sudo bash update-hub.sh                 # pull the current channel + restart
#   sudo bash update-hub.sh --tag edge-v0.2.0   # move to a specific release
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/restaurant-os}"
TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2;;
    --dir) INSTALL_DIR="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

cd "$INSTALL_DIR"
ENV_FILE="$INSTALL_DIR/.env.edge"

if [ -n "$TAG" ]; then
  if grep -qE '^\s*EDGE_IMAGE_TAG=' "$ENV_FILE"; then
    sed -i "s|^\s*EDGE_IMAGE_TAG=.*|EDGE_IMAGE_TAG=${TAG}|" "$ENV_FILE"
  else
    printf 'EDGE_IMAGE_TAG=%s\n' "$TAG" >> "$ENV_FILE"
  fi
  echo "Pinned EDGE_IMAGE_TAG=${TAG}"
fi

docker compose -f docker-compose.edge.yml --env-file .env.edge pull
docker compose -f docker-compose.edge.yml --env-file .env.edge up -d
docker compose -f docker-compose.edge.yml --env-file .env.edge ps
echo "Update complete."
