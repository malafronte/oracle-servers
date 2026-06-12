#!/bin/bash
# =============================================================================
# 06-setup-registry.sh — Docker Registry privato
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea utente/password htpasswd per il registry
#   - Crea il docker-compose.yml del Registry
#   - Avvia il Registry (con proxy verso Docker Hub per immagini pubbliche)
#
# Prerequisito: Traefik già avviato (script 04)
# Da eseguire come:  bash 06-setup-registry.sh
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

echo "=== [06/11] Setup Docker Registry privato ==="

REGISTRY_DIR="$HOME/docker/registry"
AUTH_DIR="$REGISTRY_DIR/auth"

cd "$REGISTRY_DIR"

# ── 1. Autenticazione htpasswd ─────────────────────────────────────────────
echo ">> Creazione credenziali htpasswd per il registry..."
echo "   Utente: ${REGISTRY_USER}"
htpasswd -Bc "$AUTH_DIR/htpasswd" "${REGISTRY_USER}" <<< "${REGISTRY_PASSWORD}" 2>/dev/null || \
  htpasswd -Bc "$AUTH_DIR/htpasswd" "${REGISTRY_USER}"

echo "   htpasswd creato."

# ── 2. Docker Compose ──────────────────────────────────────────────────────
echo ">> Creazione docker-compose.yml..."
cat > docker-compose.yml << COMPOSEEOF
services:
  registry:
    image: registry:3.1.1
    container_name: registry
    restart: unless-stopped
    networks:
      - traefik-net
    volumes:
      - ./data:/var/lib/registry
      - ./auth/htpasswd:/auth/htpasswd:ro
    environment:
      - REGISTRY_AUTH=htpasswd
      - REGISTRY_AUTH_HTPASSWD_REALM=Registry
      - REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
      - REGISTRY_HTTP_ADDR=0.0.0.0:5000
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry.rule=Host(\`registry.${DOMAIN}\`)"
      - "traefik.http.routers.registry.entrypoints=websecure"
      - "traefik.http.routers.registry.tls.certresolver=letsencrypt"
      - "traefik.http.services.registry.loadbalancer.server.port=5000"

  registry-ui:
    image: joxit/docker-registry-ui:2.6.0
    container_name: registry-ui
    restart: unless-stopped
    profiles:
      - ui
    networks:
      - traefik-net
    environment:
      - REGISTRY_TITLE=Docker Registry
      - DELETE_IMAGES=true
      - SINGLE_REGISTRY=true
      - NGINX_PROXY_PASS_URL=http://registry:5000
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry-ui.rule=Host(\`registry-ui.${DOMAIN}\`)"
      - "traefik.http.routers.registry-ui.entrypoints=websecure"
      - "traefik.http.routers.registry-ui.tls.certresolver=letsencrypt"
      - "traefik.http.routers.registry-ui.middlewares=registry-ui-auth@file"
      - "traefik.http.services.registry-ui.loadbalancer.server.port=80"

networks:
  traefik-net:
    external: true
COMPOSEEOF

echo ">> Avvio Registry..."
docker compose up -d

echo ""
echo "=== Registry avviato con successo ==="
echo ""
echo "Login (da qualsiasi macchina con accesso di rete):"
echo "  docker login registry.${DOMAIN}"
echo "  Username: ${REGISTRY_USER}"
echo "  Password: ${REGISTRY_PASSWORD}"
echo ""
echo "Push di un'immagine di prova:"
echo "  docker tag hello-world registry.${DOMAIN}/test/hello:latest"
echo "  docker push registry.${DOMAIN}/test/hello:latest"
echo ""
echo ">> Prossimo script: 07-setup-forgejo.sh"
