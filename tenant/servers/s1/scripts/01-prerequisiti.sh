#!/bin/bash
# =============================================================================
# 01-prerequisiti.sh — Preparazione sistema
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Verifica che i record DNS siano configurati (opzionale)
#   - Aggiorna i pacchetti di sistema
#   - Installa i pacchetti base: ca-certificates, curl, apache2-utils, jq
#
# Da eseguire come:  bash 01-prerequisiti.sh
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

echo "=== [01/11] Preparazione sistema ==="

echo ">> Aggiornamento pacchetti di sistema..."
sudo apt update && sudo apt upgrade -y

echo ">> Installazione pacchetti base (ca-certificates, curl, apache2-utils, jq)..."
sudo apt install -y ca-certificates curl apache2-utils jq

echo ""
echo "=== Prerequisiti completati ==="
echo "Pacchetti installati:"
echo "  - ca-certificates  (certificati CA per HTTPS)"
echo "  - curl             (richieste HTTP)"
echo "  - apache2-utils    (htpasswd per basic auth)"
echo "  - jq               (parsing JSON)"
echo ""
echo ">> Prossimo script: 02-installa-docker.sh"
