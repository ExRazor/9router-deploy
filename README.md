# 9router-deploy

Deploy & undeploy scripts for [9Router](https://docker.io/decolua/9router:latest) — an AI model router.
Supports **podman** (quadlet + systemd user) and **docker** (compose), auto-detected.
Optionally runs [Headroom](https://github.com/headroomlabs-ai/headroom) as a sidecar (token compression proxy). Enabled by default.

## Prerequisites

- `podman` (>=4.4, recommended) **or** `docker` + `docker compose`
- `openssl` (auto-generates secrets)
- `nginx` (optional, reverse proxy + SSL)
- Cloudflare Origin cert at `/etc/ssl/<base-domain>/{cert.pem,privkey.pem}` (optional, for HTTPS)

### If using docker

Your user must be in the `docker` group. Check:
```bash
groups | grep -qw docker && echo "OK" || echo "missing"
```
If missing, run this then logout/login:
```bash
sudo usermod -aG docker $USER
```

## Quickstart

```bash
git clone git@github.com:ExRazor/9router-deploy.git
cd 9router-deploy
./deploy.sh            # creates .env from .env.example, asks you to fill it in
```

Fill in `.env` at minimum:
- `INITIAL_PASSWORD` — first login password (required, don't keep the placeholder)
- `DOMAIN` — subdomain for 9Router, e.g. `9r.example.com`

Run again:
```bash
./deploy.sh
```

`JWT_SECRET` & `API_KEY_SECRET` are auto-generated if left empty.

## Configuration (`.env`)

See `.env.example` for the full list. Key vars:

| Variable | Default | Description |
|----------|---------|-------------|
| `INITIAL_PASSWORD` | — | Required. First login password. |
| `DOMAIN` | — | Required. 9Router subdomain. |
| `PORT` | `20128` | Container port on host (bound to `127.0.0.1`). |
| `HOST_DATA_DIR` | `./data` | Host data path. |
| `ENABLE_HEADROOM` | `false` | `true` = run Headroom sidecar. |
| `CERT_BASE_DOMAIN` | auto | Base domain where certs live. Auto-detects last 2 labels of `DOMAIN`. Set manually for 2-part TLDs like `.ac.id` / `.co.id`. |
| `CF_AUTH_ORIGIN_PULLS` | `false` | `true` = enable Cloudflare Authenticated Origin Pulls mTLS (needs `cloudflare_ca.pem`). |

## Headroom (sidecar)

Token compression proxy for 9Router. Enabled by default — disable with `ENABLE_HEADROOM=false` in `.env`.

Uses the official `ghcr.io/chopratejas/headroom:latest` image (currently 0.27.x — the last release with the `/v1/compress` endpoint 9Router calls). Newer headroom versions removed that endpoint and switched to a transparent-proxy model; until 9Router supports the new API, we stay on this image.

After it's running, enable it once in the 9Router dashboard → Endpoint → Token Saver → Headroom (URL: `http://headroom:8787`).

Update the headroom image manually:
```bash
# podman
podman pull ghcr.io/chopratejas/headroom:latest && systemctl --user restart headroom
# docker
docker compose -f docker-compose.yml pull headroom && docker compose -f docker-compose.yml up -d headroom
```
(If a newer image drops `/v1/compress` again, 9Router logs `⚠️ [HEADROOM] skipped: proxy returned HTTP 404` — pin to the last working tag.)

## Reverse proxy + SSL

`deploy.sh` renders `9router.nginx.tmpl` to `/etc/nginx/sites-available/9router.conf` (or `conf.d/` if `sites-enabled` doesn't exist) and reloads nginx. Skips automatically if certs are missing or nginx isn't installed.

For HTTPS, place Cloudflare Origin certs at:
```
/etc/ssl/<CERT_BASE_DOMAIN>/cert.pem
/etc/ssl/<CERT_BASE_DOMAIN>/privkey.pem
/etc/ssl/<CERT_BASE_DOMAIN>/cloudflare_ca.pem   # if CF_AUTH_ORIGIN_PULLS=true
```

## Structure

```
.
├── deploy.sh                       # deploy entry point
├── undeploy.sh                     # undeploy entry point
├── 9router.nginx.tmpl              # nginx config template
├── .env.example                    # env template
└── container/
    ├── 9router.container.tmpl      # podman quadlet (9router)
    ├── headroom.container.tmpl     # podman quadlet (headroom)
    ├── 9router.network             # podman quadlet network
    └── docker-compose.yml.tmpl     # docker compose template
```

## Update

**Podman (9router image):**
```bash
podman pull docker.io/decolua/9router:latest && systemctl --user restart 9router
```

**Docker (9router image):**
```bash
docker compose -f docker-compose.yml pull && docker compose -f docker-compose.yml up -d
```

**Headroom**: update manually (see above).

## Undeploy

```bash
./undeploy.sh                    # containers + systemd/quadlet/compose config only
./undeploy.sh --remove-images    # + remove local images
./undeploy.sh --purge-data       # + remove data (DB, providers, combos)
./undeploy.sh --purge-nginx      # + remove nginx config
./undeploy.sh --all              # everything
./undeploy.sh --all -y           # no confirmation prompts
```
