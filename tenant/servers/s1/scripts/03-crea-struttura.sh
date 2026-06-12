#!/bin/bash
# =============================================================================
# 03-crea-struttura.sh — Creazione struttura directory
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea la struttura directory ~/docker/ per tutti i servizi
#   - Crea le sottocartelle per volumi, config, dati
#
# Da eseguire come:  bash 03-crea-struttura.sh
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

echo "=== [03/11] Creazione struttura directory ==="

DOCKER_DIR="$HOME/docker"

echo ">> Creazione directory base: $DOCKER_DIR"

mkdir -p "$DOCKER_DIR"/{traefik/{config,certificates},portainer,registry/{data,auth},forgejo/{data,runner1,runner2},postgres,netdata/{config,lib,cache}}

echo ""
echo "Struttura creata:"
echo "~/docker/"
echo "├── traefik/"
echo "│   ├── config/"
echo "│   └── certificates/"
echo "├── portainer/"
echo "├── netdata/"
echo "│   ├── config/"
echo "│   ├── lib/"
echo "│   └── cache/"
echo "├── registry/"
echo "│   ├── auth/"
echo "│   └── data/"
echo "├── forgejo/"
echo "│   ├── data/"
echo "│   ├── runner1/"
echo "│   └── runner2/"
echo "└── postgres/"
echo ""
echo ">> Prossimo script: 04-setup-traefik.sh"
