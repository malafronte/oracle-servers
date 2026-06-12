#!/bin/bash
# =============================================================================
# 04-setup-traefik.sh — Reverse proxy + certificati SSL (Let's Encrypt)
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea la configurazione statica Traefik (traefik.yml)
#   - Crea la configurazione dashboard con basic auth (dashboard.yml)
#   - Genera la password htpasswd per la dashboard
#   - Crea il docker-compose.yml di Traefik
#   - Crea la rete docker traefik-net
#   - Avvia Traefik
#
# Da eseguire come:  bash 04-setup-traefik.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  source <(sed 's/\r$//' "$SCRIPT_DIR/.env")
else
  echo "ERRORE: File .env non trovato in $SCRIPT_DIR"
  echo "Copia .env.example in .env e inserisci i valori reali."
  exit 1
fi

echo "=== [04/11] Setup Traefik — Reverse Proxy + SSL ==="

TRAEFIK_DIR="$HOME/docker/traefik"
CONFIG_DIR="$TRAEFIK_DIR/config"
CERT_DIR="$TRAEFIK_DIR/certificates"

cd "$TRAEFIK_DIR"

# ── 1. Configurazione statica Traefik ──────────────────────────────────────
echo ">> Creazione traefik.yml..."
cat > traefik.yml << TRAEFIKEOF
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${LETSENCRYPT_EMAIL}
      storage: /certificates/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-net
  file:
    directory: /config
    watch: true
TRAEFIKEOF
echo "   traefik.yml creato."

# ── 2. Password basic auth per dashboard ───────────────────────────────────
echo ">> Generazione password htpasswd per dashboard Traefik..."
# Usa printf per evitare newline spuri; htpasswd -i legge da stdin
HTPASSWD_OUTPUT=$(printf '%s' "${TRAEFIK_DASHBOARD_PASSWORD}" | htpasswd -nB -i ${TRAEFIK_DASHBOARD_USER})

echo ">> Creazione dashboard.yml..."
# Il file provider NON richiede $$ escaping (solo le label docker-compose lo fanno)
cat > "$CONFIG_DIR/dashboard.yml" << DASHEOF
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - "$HTPASSWD_OUTPUT"
  routers:
    dashboard:
      rule: "Host(\`traefik.${DOMAIN}\`)"
      service: api@internal
      middlewares:
        - dashboard-auth
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
DASHEOF
echo "   dashboard.yml creato."

# ── 3. Docker Compose ──────────────────────────────────────────────────────
echo ">> Creazione docker-compose.yml..."
cat > docker-compose.yml << 'COMPOSEEOF'
services:
  traefik:
    image: traefik:v3.7.4
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./config:/config
      - ./certificates:/certificates
    networks:
      - traefik-net

networks:
  traefik-net:
    name: traefik-net
    external: false
COMPOSEEOF
echo "   docker-compose.yml creato."

# ── 4. Avvio Traefik ───────────────────────────────────────────────────────
echo ">> Avvio Traefik..."
docker compose up -d

echo ""
echo "=== Traefik avviato con successo ==="
echo ""
echo "Verifica:"
echo "  docker ps | grep traefik"
echo "  curl -s https://traefik.${DOMAIN} | head -5"
echo ""
echo "Dashboard: https://traefik.${DOMAIN}"
echo "  Utente: ${TRAEFIK_DASHBOARD_USER}"
echo "  Password: ${TRAEFIK_DASHBOARD_PASSWORD}"
echo ""
echo ">> Prossimo script: 05-setup-portainer.sh"
