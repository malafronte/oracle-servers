#!/bin/bash
# =============================================================================
# 02-installa-docker.sh — Installazione Docker su ARM64
# Server: malafronte-oci-s1 (ARM Ampere A1, Ubuntu 24.04)
#
# Cosa fa:
#   - Rimuove vecchie versioni di Docker
#   - Aggiunge il repository ufficiale Docker
#   - Installa Docker CE, containerd, buildx, compose plugin
#   - Aggiunge l'utente corrente al gruppo docker
#
# NOTA BENE: Dopo l'esecuzione, DEVI uscire e rientrare dalla sessione SSH
#             per applicare i permessi del gruppo docker.
#
# Da eseguire come:  bash 02-installa-docker.sh
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

echo "=== [02/11] Installazione Docker su ARM64 ==="

# 1. Rimuovi eventuali vecchie versioni
echo ">> Rimozione vecchie versioni Docker..."
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# 2. Aggiungi la GPG key e il repository Docker
echo ">> Aggiunta repository Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 3. Installa Docker CE + compose plugin
echo ">> Installazione Docker CE, CLI, containerd, buildx, compose..."
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# 4. Aggiungi l'utente al gruppo docker (per usare docker senza sudo)
echo ">> Aggiunta utente '$USER' al gruppo docker..."
sudo usermod -aG docker "$USER"

echo ""
echo "=== Docker installato con successo ==="
docker --version
docker compose version

echo ""
echo "============================================================"
echo "  IMPORTANTE: Esci e rientra dalla sessione SSH per usare"
echo "  docker senza sudo.  Poi esegui:  docker run --rm hello-world"
echo "============================================================"
echo ""
echo ">> Dopo il re-login, esegui:  bash 03-crea-struttura.sh"
