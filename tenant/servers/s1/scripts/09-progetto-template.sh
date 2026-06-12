#!/bin/bash
# =============================================================================
# 09-progetto-template.sh — Struttura per nuovo progetto docker-compose
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea la cartella per un nuovo progetto sotto ~/docker/
#   - Genera un docker-compose.yml di esempio con Traefik già configurato
#   - Include rete interna isolata + rete Traefik esterna
#
# Uso:  bash 09-progetto-template.sh <nome-progetto> [dominio]
# Esempi:
#   bash 09-progetto-template.sh cinebase cinebase.it
#   bash 09-progetto-template.sh blog        # usa ${DOMAIN} di default (malafronte.eu)
#
# Prerequisito: Traefik già avviato (script 04)
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

echo "=== [09/11] Template nuovo progetto ==="

PROJECT="${1:-}"
PROJECT_DOMAIN="${2:-${DOMAIN}}"

if [ -z "$PROJECT" ]; then
  echo "ERRORE: Specificare il nome del progetto."
  echo "Uso: bash 09-progetto-template.sh <nome-progetto> [dominio]"
  echo "Esempio: bash 09-progetto-template.sh cinebase cinebase.it"
  exit 1
fi

PROJECT_DIR="$HOME/docker/$PROJECT"

if [ -d "$PROJECT_DIR" ]; then
  echo "ERRORE: La cartella $PROJECT_DIR esiste già."
  exit 1
fi

echo ">> Creazione progetto: $PROJECT"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# Genera password casuale per PostgreSQL
DB_PASSWORD=$(openssl rand -base64 18 2>/dev/null || echo "CambiaQuestaPassword123!")

cat > docker-compose.yml << COMPOSEEOF
# Progetto: $PROJECT
# Creato il: $(date +%Y-%m-%d)

services:
  web:
    image: registry.${PROJECT_DOMAIN}/$PROJECT/web:latest
    container_name: $PROJECT-web
    restart: unless-stopped
    networks:
      - internal
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.$PROJECT.rule=Host(\`$PROJECT.${PROJECT_DOMAIN}\`)"
      - "traefik.http.routers.$PROJECT.entrypoints=websecure"
      - "traefik.http.routers.$PROJECT.tls.certresolver=letsencrypt"
      - "traefik.http.services.$PROJECT.loadbalancer.server.port=3000"

  db:
    image: postgres:16-alpine
    container_name: $PROJECT-db
    restart: unless-stopped
    networks:
      - internal
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=$PROJECT
      - POSTGRES_PASSWORD=$DB_PASSWORD
      - POSTGRES_DB=$PROJECT

networks:
  internal:
    driver: bridge
  traefik-net:
    external: true
COMPOSEEOF

# Crea anche un .gitignore per i dati locali
cat > .gitignore << 'GITIGNOREEOF'
# Dati PostgreSQL (non versionare)
pgdata/

# File di ambiente locali
.env
GITIGNOREEOF

echo ""
echo "=== Progetto '$PROJECT' creato ==="
echo ""
echo "Cartella: $PROJECT_DIR"
echo "File creato: docker-compose.yml"
echo ""
echo "Password PostgreSQL generata: $DB_PASSWORD"
echo "  (salvala in un posto sicuro, modificala nel docker-compose.yml se vuoi)"
echo ""
echo "Per avviare il progetto:"
echo "  cd ~/docker/$PROJECT"
echo "  docker compose up -d"
echo ""
echo "Il progetto sarà raggiungibile su: https://$PROJECT.${PROJECT_DOMAIN}"
echo ""
echo "Per usare il registry privato nel workflow CI di Forgejo:"
echo "  docker build -t registry.${PROJECT_DOMAIN}/$PROJECT/web:latest ."
echo "  docker push registry.${PROJECT_DOMAIN}/$PROJECT/web:latest"
echo ""
echo ">> Prossimo script: 10-setup-backup.sh"
