#!/bin/bash
# =============================================================================
# 05-setup-portainer.sh — Interfaccia grafica Docker
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea il docker-compose.yml di Portainer
#   - Avvia Portainer collegato a Traefik
#
# Prerequisito: Traefik già avviato (script 04)
# Da eseguire come:  bash 05-setup-portainer.sh
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

echo "=== [05/11] Setup Portainer — GUI Docker ==="

PORTAINER_DIR="$HOME/docker/portainer"
cd "$PORTAINER_DIR"

echo ">> Creazione docker-compose.yml..."
cat > docker-compose.yml << COMPOSEEOF
services:
  portainer:
    image: portainer/portainer-ce:2.39.3-alpine
    container_name: portainer
    restart: unless-stopped
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`portainer.${DOMAIN}\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  traefik-net:
    external: true
COMPOSEEOF

echo ">> Avvio Portainer..."
docker compose up -d

echo ""
echo "=== Portainer avviato con successo ==="
echo ""
echo "Prima visita su https://portainer.${DOMAIN}:"
echo "  1. Crea un utente admin (scegli tu username e password)"
echo "  2. Clicca 'Get Started' per connetterti all'ambiente Docker locale"
echo ""
echo ">> Prossimo script: 06-setup-registry.sh"
