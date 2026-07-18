#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_SRC="$SCRIPT_DIR/container"
ENV_FILE="$SCRIPT_DIR/.env"
NGINX_TMPL="$SCRIPT_DIR/9router.nginx.tmpl"
COMPOSE_TMPL="$CONTAINER_SRC/docker-compose.yml.tmpl"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# Podman-only paths
TMPL_FILE="$CONTAINER_SRC/9router.container.tmpl"
NETWORK_FILE="$CONTAINER_SRC/9router.network"
HEADROOM_TMPL="$CONTAINER_SRC/headroom.container.tmpl"
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/9router.container"
HEADROOM_QUADLET="$QUADLET_DIR/headroom.container"

# --- Engine detection ---
if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD=docker
else
  echo "❌ podman or docker not found." >&2
  exit 1
fi
echo "ℹ️  Container engine: $CONTAINER_CMD"

if [[ "$CONTAINER_CMD" == "docker" ]]; then
  if ! groups | grep -qw docker && [[ "$(id -u)" != "0" ]]; then
    echo "❌ User '$USER' is not in the docker group." >&2
    echo "   Run: sudo usermod -aG docker \$USER" >&2
    echo "   Then logout & login again, or run: newgrp docker" >&2
    exit 1
  fi
fi

command -v openssl >/dev/null 2>&1 || { echo "❌ openssl not found."; exit 1; }

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  echo "⚠️  .env created from .env.example. Fill in INITIAL_PASSWORD & DOMAIN then run again."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

changed=false
if [[ -z "${JWT_SECRET:-}" ]]; then
  JWT_SECRET="$(openssl rand -hex 32)"
  sed -i "s#^JWT_SECRET=.*#JWT_SECRET=${JWT_SECRET}#" "$ENV_FILE"
  changed=true
fi
if [[ -z "${API_KEY_SECRET:-}" ]]; then
  API_KEY_SECRET="$(openssl rand -hex 32)"
  sed -i "s#^API_KEY_SECRET=.*#API_KEY_SECRET=${API_KEY_SECRET}#" "$ENV_FILE"
  changed=true
fi
[[ "$changed" == true ]] && echo "🔐 Empty secrets generated & saved to .env"

if [[ -z "${INITIAL_PASSWORD:-}" || "$INITIAL_PASSWORD" == "ganti-password-login-pertama" ]]; then
  echo "❌ INITIAL_PASSWORD is still empty/placeholder." >&2
  exit 1
fi
if [[ -z "${DOMAIN:-}" ]]; then
  echo "❌ DOMAIN in .env is still empty." >&2
  exit 1
fi

HOST_DATA_DIR="${HOST_DATA_DIR:-$SCRIPT_DIR/data}"
PORT="${PORT:-20128}"

# --- Auto-detect base domain for cert path, if CERT_BASE_DOMAIN is empty ---
if [[ -z "${CERT_BASE_DOMAIN:-}" ]]; then
  CERT_BASE_DOMAIN="$(awk -F. '{ if (NF<=2) print $0; else print $(NF-1)"."$NF }' <<< "$DOMAIN")"
  echo "ℹ️  CERT_BASE_DOMAIN auto-detected from DOMAIN: ${CERT_BASE_DOMAIN}"
fi

ENABLE_HEADROOM="${ENABLE_HEADROOM:-false}"
mkdir -p "$HOST_DATA_DIR"
[[ "$CONTAINER_CMD" == "podman" ]] && mkdir -p "$QUADLET_DIR"

# ==================== Podman path ====================
if [[ "$CONTAINER_CMD" == "podman" ]]; then

  sed \
    -e "s#__PORT__#${PORT}#g" \
    -e "s#__HOST_DATA_DIR__#${HOST_DATA_DIR}#g" \
    -e "s#__ENV_FILE__#${ENV_FILE}#g" \
    "$TMPL_FILE" > "$QUADLET_FILE"
  echo "✅ Quadlet written to $QUADLET_FILE"

  cp "$NETWORK_FILE" "$QUADLET_DIR/9router.network"

  if [[ "$ENABLE_HEADROOM" == "true" ]]; then
    cp "$HEADROOM_TMPL" "$HEADROOM_QUADLET"
    echo "✅ Headroom quadlet written to $HEADROOM_QUADLET"
  elif [[ -f "$HEADROOM_QUADLET" ]]; then
    systemctl --user stop headroom.service 2>/dev/null || true
    rm -f "$HEADROOM_QUADLET"
    podman rm -f headroom >/dev/null 2>&1 || true
    echo "🗑️  Headroom disabled, quadlet & container removed"
  fi

  if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
    loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"
    echo "🔓 Linger enabled for user $USER"
  fi

  systemctl --user enable --now podman-auto-update.timer 2>/dev/null || true

  systemctl --user daemon-reload

  if ! systemctl --user cat 9router.service >/dev/null 2>&1; then
    echo "❌ Unit 9router.service not generated from Quadlet." >&2
    echo "   Check: podman --version (needs >=4.4), and ensure /usr/lib/systemd/user-generators/podman-user-generator exists." >&2
    exit 1
  fi

  systemctl --user restart 9router.service

  if [[ "$ENABLE_HEADROOM" == "true" ]]; then
    systemctl --user restart headroom.service
    echo "🧠 Headroom running. Login to 9Router dashboard -> Endpoint -> Token Saver -> Headroom,"
    echo "   confirm URL is http://headroom:8787, recheck status, then Enable (manual step, once only)."
  fi

# ==================== Docker path ====================
else

  rendered="$(sed \
    -e "s#__PORT__#${PORT}#g" \
    -e "s#__HOST_DATA_DIR__#${HOST_DATA_DIR}#g" \
    -e "s#__ENV_FILE__#${ENV_FILE}#g" \
    "$COMPOSE_TMPL")"

  if [[ "$ENABLE_HEADROOM" == "true" ]]; then
    rendered="$(sed '/#__HEADROOM_START__/d; /#__HEADROOM_END__/d' <<< "$rendered")"
  else
    rendered="$(sed '/#__HEADROOM_START__/,/#__HEADROOM_END__/d' <<< "$rendered")"
  fi

  echo "$rendered" > "$COMPOSE_FILE"
  echo "✅ docker-compose.yml written to $COMPOSE_FILE"

  docker compose -f "$COMPOSE_FILE" up -d

  if [[ "$ENABLE_HEADROOM" == "true" ]]; then
    echo "🧠 Headroom running. Login to 9Router dashboard -> Endpoint -> Token Saver -> Headroom,"
    echo "   confirm URL is http://headroom:8787, recheck status, then Enable (manual step, once only)."
  fi

fi

echo -n "⏳ Waiting for 9Router to be ready"
ready=false
for _ in $(seq 1 15); do
  curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${PORT}" && { ready=true; break; }
  echo -n "."; sleep 2
done
echo ""
[[ "$ready" == true ]] && echo "🚀 Container running at 127.0.0.1:${PORT}" \
  || echo "⚠️  Not ready within 30 seconds, check container logs."

# --- Setup nginx reverse proxy ---
CERT_DIR="/etc/ssl/${CERT_BASE_DOMAIN}"
if [[ ! -f "$CERT_DIR/cert.pem" || ! -f "$CERT_DIR/privkey.pem" ]]; then
  echo "⚠️  Cert not found at $CERT_DIR (cert.pem/privkey.pem). Skipping nginx setup."
  echo "   Container deploy still succeeded, re-run this script after cert is ready."
  exit 0
fi

CF_AUTH_ORIGIN_PULLS="${CF_AUTH_ORIGIN_PULLS:-false}"
if [[ "$CF_AUTH_ORIGIN_PULLS" == "true" && ! -f "$CERT_DIR/cloudflare_ca.pem" ]]; then
  echo "⚠️  CF_AUTH_ORIGIN_PULLS=true but $CERT_DIR/cloudflare_ca.pem is missing. Continuing without AOP."
  CF_AUTH_ORIGIN_PULLS=false
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "⚠️  nginx not found, skipping reverse proxy setup."
  exit 0
fi

if [[ -d /etc/nginx/sites-enabled ]]; then
  NGINX_CONF="/etc/nginx/sites-available/9router.conf"
  NGINX_LINK="/etc/nginx/sites-enabled/9router.conf"
else
  NGINX_CONF="/etc/nginx/conf.d/9router.conf"
  NGINX_LINK=""
fi

sudo mkdir -p "$(dirname "$NGINX_CONF")"
rendered="$(sed \
  -e "s#__DOMAIN__#${DOMAIN}#g" \
  -e "s#__CERT_BASE_DOMAIN__#${CERT_BASE_DOMAIN}#g" \
  -e "s#__PORT__#${PORT}#g" \
  "$NGINX_TMPL")"

if [[ "$CF_AUTH_ORIGIN_PULLS" == "true" ]]; then
  rendered="$(sed '/#__AOP_START__/d; /#__AOP_END__/d' <<< "$rendered")"
  echo "🔒 Authenticated Origin Pulls enabled (Cloudflare client cert required)"
else
  rendered="$(sed '/#__AOP_START__/,/#__AOP_END__/d' <<< "$rendered")"
  echo "ℹ️  Authenticated Origin Pulls disabled — ensure DNS is proxied (orange cloud) + SSL mode Full/Full strict in Cloudflare"
fi

echo "$rendered" | sudo tee "$NGINX_CONF" >/dev/null

if [[ -n "$NGINX_LINK" ]]; then
  sudo ln -sf "$NGINX_CONF" "$NGINX_LINK"
fi

if sudo nginx -t; then
  sudo systemctl reload nginx
  echo "✅ Reverse proxy active: https://${DOMAIN}"
else
  echo "❌ Invalid nginx config, check $NGINX_CONF manually. Reload cancelled." >&2
  exit 1
fi

echo ""
if [[ "$CONTAINER_CMD" == "podman" ]]; then
  echo "   Status container : systemctl --user status 9router"
  echo "   Log container     : journalctl --user -u 9router -f"
  echo "   Update image      : podman pull docker.io/decolua/9router:latest && systemctl --user restart 9router"
else
  echo "   Status container : docker compose -f $COMPOSE_FILE ps"
  echo "   Log container     : docker compose -f $COMPOSE_FILE logs -f"
  echo "   Update image      : docker compose -f $COMPOSE_FILE pull && docker compose -f $COMPOSE_FILE up -d"
fi
