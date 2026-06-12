#!/bin/bash
# =============================================================================
# 06b-setup-registry-ui.sh — Autenticazione per Registry UI (middleware Traefik)
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea il file provider Traefik con basic auth per la registry UI
#   - Riavvia Traefik e la UI
#
# Prerequisiti: Registry già avviato (script 06)
# Da eseguire come:  bash 06b-setup-registry-ui.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  source <(sed 's/\r$//' "$SCRIPT_DIR/.env")
else
  echo "ERRORE: File .env non trovato in $SCRIPT_DIR"
  exit 1
fi

echo "=== [06b] Setup auth Registry UI ==="

REGISTRY_DIR="$HOME/docker/registry"
TRAEFIK_CONFIG="$HOME/docker/traefik/config"

# Legge l'hash htpasswd esistente del registry (stesse credenziali, hash garantito identico)
HTPASSWD_HASH=$(cat "$REGISTRY_DIR/auth/htpasswd")
if [ -z "$HTPASSWD_HASH" ]; then
  echo "ERRORE: file htpasswd del registry vuoto. Esegui prima 06-setup-registry.sh"
  exit 1
fi

echo ">> Creazione middleware Traefik per registry-ui..."
# Il file provider NON richiede $$ escaping (solo le label docker-compose)
cat > "$TRAEFIK_CONFIG/middleware-registry-ui.yml" << UIAUTH
http:
  middlewares:
    registry-ui-auth:
      basicAuth:
        users:
          - "$HTPASSWD_HASH"
UIAUTH

echo ">> Riavvio Traefik (ricarica file provider)..."
docker restart traefik
sleep 2

echo ">> Riavvio Registry UI (profilo ui)..."
cd "$REGISTRY_DIR"
docker compose --profile ui up -d registry-ui

echo ""
echo "=== Registry UI pronta ==="
echo "  https://registry-ui.${DOMAIN}"
echo "  Login con le stesse credenziali del registry (${REGISTRY_USER})"
