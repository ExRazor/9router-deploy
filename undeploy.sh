#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Podman-only paths
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/9router.container"
HEADROOM_QUADLET="$QUADLET_DIR/headroom.container"
NETWORK_QUADLET="$QUADLET_DIR/9router.network"

# --- Engine detection ---
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD=docker
else
  echo "❌ podman or docker not found." >&2
  exit 1
fi

PURGE_DATA=false
PURGE_NGINX=false
REMOVE_IMAGES=false
ASSUME_YES=false

for arg in "$@"; do
  case "$arg" in
    --purge-data)     PURGE_DATA=true ;;
    --purge-nginx)   PURGE_NGINX=true ;;
    --remove-images) REMOVE_IMAGES=true ;;
    --yes|-y)        ASSUME_YES=true ;;
    --all)           PURGE_DATA=true; PURGE_NGINX=true; REMOVE_IMAGES=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  read -rp "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
HOST_DATA_DIR="${HOST_DATA_DIR:-$SCRIPT_DIR/data}"
DOMAIN="${DOMAIN:-}"

# ==================== Podman path ====================
if [[ "$CONTAINER_CMD" == "podman" ]]; then

  if systemctl --user list-unit-files 2>/dev/null | grep -q 9router.service; then
    systemctl --user stop 9router.service 2>/dev/null || true
    systemctl --user disable 9router.service 2>/dev/null || true
    echo "🛑 Service 9router stopped & disabled"
  fi

  if systemctl --user list-unit-files 2>/dev/null | grep -q headroom.service; then
    systemctl --user stop headroom.service 2>/dev/null || true
    systemctl --user disable headroom.service 2>/dev/null || true
    echo "🛑 Service headroom stopped & disabled"
  fi

  if [[ -f "$QUADLET_FILE" || -f "$HEADROOM_QUADLET" || -f "$NETWORK_QUADLET" ]]; then
    rm -f "$QUADLET_FILE" "$HEADROOM_QUADLET" "$NETWORK_QUADLET"
    systemctl --user daemon-reload
    echo "🗑️  Quadlet removed: 9router, headroom, network"
  fi

  podman rm -f 9router >/dev/null 2>&1 && echo "🗑️  Container 9router removed" || true
  podman rm -f headroom >/dev/null 2>&1 && echo "🗑️  Container headroom removed" || true

  if [[ "$REMOVE_IMAGES" == true ]]; then
    podman rmi -f docker.io/decolua/9router:latest >/dev/null 2>&1 && echo "🗑️  Image docker.io/decolua/9router:latest removed" || true
    podman rmi -f ghcr.io/chopratejas/headroom:latest >/dev/null 2>&1 && echo "🗑️  Image ghcr.io/chopratejas/headroom:latest removed" || true
    podman image prune -f >/dev/null 2>&1 || true
  fi

# ==================== Docker path ====================
else

  if [[ -f "$COMPOSE_FILE" ]]; then
    down_opts="down"
    [[ "$REMOVE_IMAGES" == true ]] && down_opts="down --rmi all"
    docker compose -f "$COMPOSE_FILE" $down_opts
    rm -f "$COMPOSE_FILE"
    echo "🗑️  docker-compose.yml removed"
  else
    echo "ℹ️  No docker-compose.yml found."
  fi

fi

# --- Remove data (optional) ---
if [[ "$PURGE_DATA" == true ]]; then
  if confirm "Remove data at $HOST_DATA_DIR (database, provider, combo)?"; then
    rm -rf "$HOST_DATA_DIR"
    echo "🗑️  Data removed: $HOST_DATA_DIR"
  fi
fi

# --- Remove nginx config (optional) ---
if [[ "$PURGE_NGINX" == true ]]; then
  CONF_A="/etc/nginx/sites-available/9router.conf"
  LINK_A="/etc/nginx/sites-enabled/9router.conf"
  CONF_B="/etc/nginx/conf.d/9router.conf"

  found=false
  [[ -f "$CONF_A" || -L "$LINK_A" || -f "$CONF_B" ]] && found=true

  if [[ "$found" == true ]]; then
    if confirm "Remove nginx config for ${DOMAIN:-9router}?"; then
      sudo rm -f "$LINK_A" "$CONF_A" "$CONF_B"
      if sudo nginx -t; then
        sudo systemctl reload nginx
        echo "🗑️  nginx config removed & nginx reloaded"
      else
        echo "⚠️  nginx -t failed after removing config, check manually before reload." >&2
      fi
    fi
  else
    echo "ℹ️  No 9router nginx config found."
  fi
fi

echo "✅ Undeploy complete."
[[ "$PURGE_DATA" == false ]]    && echo "   (data kept, use --purge-data to remove)"
[[ "$PURGE_NGINX" == false ]]  && echo "   (nginx config kept, use --purge-nginx to remove)"
[[ "$REMOVE_IMAGES" == false ]] && echo "   (images kept, use --remove-images to remove)"
