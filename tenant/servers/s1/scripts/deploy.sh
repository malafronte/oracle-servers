#!/bin/bash
# =============================================================================
# deploy.sh — Deploy rapido di un progetto docker-compose
# Da copiare sul server in ~/docker/deploy.sh
#
# Uso: ./deploy.sh <nome-progetto>
# Esempio: ./deploy.sh cinebase
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

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  echo "Uso: ./deploy.sh <nome-progetto>"
  echo "Esempio: ./deploy.sh cinebase"
  exit 1
fi

if [ ! -d "$HOME/docker/$PROJECT" ]; then
  echo "ERRORE: Cartella ~/docker/$PROJECT non trovata."
  exit 1
fi

cd "$HOME/docker/$PROJECT" || exit 1

echo ">> Deploy di '$PROJECT'..."
docker compose pull
docker compose up -d
docker image prune -f

echo ">> Deploy completato: $PROJECT"
