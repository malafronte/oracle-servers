#!/bin/bash
# =============================================================================
# 07-setup-forgejo.sh — Forgejo 15 + PostgreSQL 16 + Runner CI/CD (ARM64)
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Rimuove installazione Forgejo precedente (container + dati)
#   - Crea docker-compose.yml con PostgreSQL 16, Forgejo 15 e 2 runner v12
#   - Genera i file di configurazione runner (runner-config.yml)
#   - Avvia PostgreSQL e Forgejo (runner vanno registrati dopo)
#
# Prerequisiti:
#   - Traefik già avviato (script 04)
#   - .env nella stessa directory con le variabili necessarie
#
# Da eseguire come:  bash 07-setup-forgejo.sh
#
# Documentazione di riferimento:
#   https://forgejo.org/docs/next/admin/installation/docker/
#   https://forgejo.org/docs/next/admin/actions/installation/docker/
#   https://forgejo.org/docs/next/admin/actions/registration/
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

echo "=== [07/11] Setup Forgejo 15 — Git + CI/CD ==="

FORGEJO_DIR="$HOME/docker/forgejo"
RUNNER1_DATA="$FORGEJO_DIR/runner1/data"
RUNNER2_DATA="$FORGEJO_DIR/runner2/data"

# ── 0. Verifica installazione esistente (idempotenza) ─────────────────────
if [ -f "$FORGEJO_DIR/docker-compose.yml" ]; then
  RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^forgejo$' || true)
  if [ "$RUNNING" -gt 0 ]; then
    echo ">> Forgejo già installato e in esecuzione. Nessuna azione necessaria."
    echo "   Per reinstallare da zero, rimuovi manualmente:"
    echo "     cd $FORGEJO_DIR && docker compose down -v"
    echo "     sudo rm -rf $FORGEJO_DIR $HOME/docker/postgres"
    echo "   Poi riesegui questo script."
    exit 0
  fi
  # Container fermi ma dati esistenti: rialza e basta
  echo ">> Forgejo già installato ma fermo. Riavvio..."
  cd "$FORGEJO_DIR"
  docker compose up -d postgres forgejo
  echo "   Riavvio completato. Visita https://git.${DOMAIN}"
  exit 0
fi

# ── 1. Creazione directory ────────────────────────────────────────────────
echo ">> Creazione struttura directory..."
mkdir -p "$FORGEJO_DIR/data"
mkdir -p "$HOME/docker/postgres/data"
mkdir -p "$RUNNER1_DATA"
mkdir -p "$RUNNER2_DATA"

# Rileva GID del gruppo docker sull'host (necessario per accesso al socket)
DOCKER_GID=$(getent group docker | cut -d: -f3)
if [ -z "$DOCKER_GID" ]; then
  echo "ERRORE: gruppo docker non trovato. Docker è installato?"
  exit 1
fi
echo "   Gruppo docker GID=$DOCKER_GID"

# Il runner v12 usa UID 1001 (da documentazione ufficiale)
# Le directory dati devono appartenere a quell'utente
RUNNER_UID=1001
sudo chown -R ${RUNNER_UID}:${RUNNER_UID} "$RUNNER1_DATA" "$RUNNER2_DATA"
chmod 775 "$RUNNER1_DATA" "$RUNNER2_DATA"
chmod g+s "$RUNNER1_DATA" "$RUNNER2_DATA"

cd "$FORGEJO_DIR"

# ── 2. Genera configurazioni runner ───────────────────────────────────────
echo ">> Generazione configurazioni runner (v12)..."
docker run --rm \
  -v "$RUNNER1_DATA:/data" \
  data.forgejo.org/forgejo/runner:12 \
  forgejo-runner generate-config > "$RUNNER1_DATA/runner-config.yml"

cp "$RUNNER1_DATA/runner-config.yml" "$RUNNER2_DATA/runner-config.yml"
echo "   runner1/data/runner-config.yml e runner2/data/runner-config.yml generati."

# ── 3. Docker Compose ─────────────────────────────────────────────────────
echo ">> Creazione docker-compose.yml..."
cat > docker-compose.yml << COMPOSEEOF
services:
  postgres:
    image: postgres:16-alpine
    container_name: forgejo-db
    restart: unless-stopped
    networks:
      - forgejo-internal
    environment:
      - POSTGRES_USER=forgejo
      - POSTGRES_PASSWORD=${FORGEJO_DB_PASSWORD}
      - POSTGRES_DB=forgejo
    volumes:
      - ../postgres/data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U forgejo"]
      interval: 10s
      timeout: 5s
      retries: 5

  forgejo:
    image: codeberg.org/forgejo/forgejo:15
    container_name: forgejo
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - forgejo-internal
      - traefik-net
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - FORGEJO__database__DB_TYPE=postgres
      - FORGEJO__database__HOST=postgres:5432
      - FORGEJO__database__NAME=forgejo
      - FORGEJO__database__USER=forgejo
      - FORGEJO__database__PASSWD=${FORGEJO_DB_PASSWORD}
      - FORGEJO__server__DOMAIN=git.${DOMAIN}
      - FORGEJO__server__ROOT_URL=https://git.${DOMAIN}
      - FORGEJO__server__SSH_DOMAIN=git.${DOMAIN}
      - FORGEJO__server__SSH_PORT=2222
      - FORGEJO__actions__ENABLED=true
      - FORGEJO__service__DISABLE_REGISTRATION=true
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "2222:22"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.forgejo.rule=Host(\`git.${DOMAIN}\`)"
      - "traefik.http.routers.forgejo.entrypoints=websecure"
      - "traefik.http.routers.forgejo.tls.certresolver=letsencrypt"
      - "traefik.http.services.forgejo.loadbalancer.server.port=3000"

  runner1:
    image: data.forgejo.org/forgejo/runner:12
    container_name: forgejo-runner1
    restart: unless-stopped
    depends_on:
      - forgejo
    networks:
      - forgejo-internal
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./runner1/data:/data
    user: "1001:1001"
    group_add:
      - "${DOCKER_GID}"
    command: 'forgejo-runner daemon --config /data/runner-config.yml'

  runner2:
    image: data.forgejo.org/forgejo/runner:12
    container_name: forgejo-runner2
    restart: unless-stopped
    depends_on:
      - forgejo
    networks:
      - forgejo-internal
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./runner2/data:/data
    user: "1001:1001"
    group_add:
      - "${DOCKER_GID}"
    command: 'forgejo-runner daemon --config /data/runner-config.yml'

networks:
  forgejo-internal:
    driver: bridge
  traefik-net:
    external: true
COMPOSEEOF

# ── 4. Avvio PostgreSQL + Forgejo (runner partono dopo registrazione) ────
echo ">> Avvio PostgreSQL + Forgejo 15..."
docker compose up -d postgres forgejo

echo ""
echo "=== Forgejo 15 avviato ==="
echo ""
echo "Prossimi passi:"
echo "  1. Visita https://git.${DOMAIN}"
echo "  2. Togli la spunta a 'Disable Self-Registration' e clicca 'Installa Forgejo'"
echo "  3. Registra il primo utente (sarà automaticamente admin)"
echo "  4. Esegui lo script di registrazione runner:"
echo "     bash 07b-setup-forgejo-runners.sh"
echo ""
echo "Clone via SSH (porta 2222):"
echo "  git clone ssh://git@git.${DOMAIN}:2222/utente/repo.git"
echo ""
echo ">> Prossimo script: 07b-setup-forgejo-runners.sh"
