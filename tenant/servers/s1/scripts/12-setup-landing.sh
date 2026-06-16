#!/bin/bash
# =============================================================================
# 12-setup-landing.sh — Landing page per malafronte.eu → www.malafronte.eu
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea ~/docker/landing/ con index.html, docker-compose.yml, nginx.conf
#   - Avvia nginx con routing Traefik su malafronte.eu
#   - Configura redirect www.malafronte.eu → malafronte.eu
#
# Prerequisiti:
#   - Traefik attivo su traefik-net (script 04)
#   - DNS: malafronte.eu, www.malafronte.eu → IP OCI
#
# Da eseguire come:  bash 12-setup-landing.sh
# =============================================================================
set -euo pipefail

echo "=== [12] Setup landing page — malafronte.eu ==="

LANDING_DIR="$HOME/docker/landing"
mkdir -p "$LANDING_DIR"

# ── 1. Pagina HTML ──────────────────────────────────────────────────────────
echo ">> Creazione index.html..."
cat > "$LANDING_DIR/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>malafronte.eu — Infrastruttura DevOps su OCI ARM64</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f172a; color: #e2e8f0;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; padding: 2rem;
    }
    main { max-width: 600px; text-align: center; }
    h1 { font-size: 2rem; font-weight: 700; margin-bottom: 0.5rem; color: #f8fafc; }
    p { font-size: 1.1rem; color: #94a3b8; margin-bottom: 2rem; line-height: 1.6; }
    .badge {
      display: inline-block; background: #1e293b;
      border: 1px solid #334155; border-radius: 0.5rem;
      padding: 0.5rem 1rem; margin: 0.25rem;
      font-size: 0.9rem; color: #cbd5e1;
    }
    .badge::before { content: "▸ "; color: #38bdf8; }
    .link { color: #38bdf8; text-decoration: none; }
    .link:hover { text-decoration: underline; }
    footer { margin-top: 2.5rem; font-size: 0.85rem; color: #64748b; }
  </style>
</head>
<body>
  <main>
    <h1>malafronte.eu</h1>
    <p>
      Questo server Oracle Cloud (ARM64 Ampere A1, Always Free) ospita
      l&rsquo;infrastruttura DevOps per i progetti software di Gennaro Malafronte.
    </p>
    <div>
      <span class="badge">Traefik + Let&rsquo;s Encrypt</span>
      <span class="badge">Forgejo Git + CI/CD</span>
      <span class="badge">Docker Registry</span>
      <span class="badge">PostgreSQL 16</span>
      <span class="badge">Netdata Monitoring</span>
      <span class="badge">Ubuntu 24.04 ARM64</span>
    </div>
    <p style="margin-top:2rem;font-size:1rem;color:#e2e8f0;">
      Visita <a class="link" href="https://malafronte.dev">malafronte.dev</a> per il sito web.
    </p>
    <footer>
      OCI Always Free &middot; Ampere A1 &middot; 4 OCPU &middot; 24 GB RAM
    </footer>
  </main>
</body>
</html>
HTMLEOF
echo "   index.html creato."

# ── 2. nginx.conf ───────────────────────────────────────────────────────────
echo ">> Creazione nginx.conf..."
cat > "$LANDING_DIR/nginx.conf" << 'NGINXEOF'
user  nginx;
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  256;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;
    gzip          on;
    gzip_types    text/html text/css application/javascript image/svg+xml;

    server {
        listen 80;
        server_name malafronte.eu;

        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
NGINXEOF
echo "   nginx.conf creato."

# ── 3. docker-compose.yml ───────────────────────────────────────────────────
echo ">> Generazione docker-compose.yml..."
cat > "$LANDING_DIR/docker-compose.yml" << 'COMPOSEEOF'
services:
  landing:
    image: nginx:alpine
    container_name: landing
    restart: unless-stopped
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - traefik-net
    labels:
      # malafronte.eu → landing page
      - "traefik.enable=true"
      - "traefik.http.routers.landing.rule=Host(`malafronte.eu`)"
      - "traefik.http.routers.landing.entrypoints=websecure"
      - "traefik.http.routers.landing.tls.certresolver=letsencrypt"
      - "traefik.http.services.landing.loadbalancer.server.port=80"
      # www.malafronte.eu → malafronte.eu (301)
      - "traefik.http.routers.landing-www.rule=Host(`www.malafronte.eu`)"
      - "traefik.http.routers.landing-www.entrypoints=websecure"
      - "traefik.http.routers.landing-www.tls.certresolver=letsencrypt"
      - "traefik.http.routers.landing-www.middlewares=landing-redirect-www"
      - "traefik.http.middlewares.landing-redirect-www.redirectregex.regex=^https://www\\.malafronte\\.eu/(.*)"
      - "traefik.http.middlewares.landing-redirect-www.redirectregex.replacement=https://malafronte.eu/$${1}"
      - "traefik.http.middlewares.landing-redirect-www.redirectregex.permanent=true"

networks:
  traefik-net:
    external: true
COMPOSEEOF
echo "   docker-compose.yml generato."

# ── 4. Avvio ────────────────────────────────────────────────────────────────
cd "$LANDING_DIR"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^landing$'; then
  echo ">> Landing page già in esecuzione. Pull e restart..."
  docker compose pull
  docker compose up -d
else
  echo ">> Avvio landing page..."
  docker compose up -d
fi

echo ""
echo "=== Landing page avviata ==="
echo "  https://malafronte.eu          — pagina di benvenuto"
echo "  https://www.malafronte.eu       — redirect → malafronte.eu (301)"
echo ""
echo "DNS richiesto (record A → IP del server OCI):"
echo "  malafronte.eu"
echo "  www.malafronte.eu"
