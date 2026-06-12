#!/bin/bash
# =============================================================================
# 07b-setup-forgejo-runners.sh — Registra e avvia i runner CI/CD
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Registra runner1 e runner2 su Forgejo via CLI (offline registration)
#   - Crea i file runner-config.yml con UUID, token, label e automount
#   - Avvia i container runner
#
# Prerequisiti:
#   - 07-setup-forgejo.sh già eseguito con successo
#   - Forgejo già installato (utente admin creato)
#
# Documentazione: https://forgejo.org/docs/next/admin/actions/registration/
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  source <(sed 's/\r$//' "$SCRIPT_DIR/.env")
else
  echo "ERRORE: File .env non trovato in $SCRIPT_DIR"
  exit 1
fi

echo "=== [07b] Registrazione e avvio runner CI/CD ==="

FORGEJO_DIR="$HOME/docker/forgejo"
FORGEJO_URL="https://git.${DOMAIN}"

cd "$FORGEJO_DIR"

# ── 1. Verifica che Forgejo sia in esecuzione ────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -q '^forgejo$'; then
  echo "ERRORE: Forgejo non è in esecuzione. Esegui prima 07-setup-forgejo.sh"
  exit 1
fi

echo ">> Verifica connessione a Forgejo..."
if ! curl -sk "$FORGEJO_URL" > /dev/null 2>&1; then
  echo "ERRORE: Forgejo non risponde su $FORGEJO_URL"
  exit 1
fi
echo "   Forgejo raggiungibile."

# ── 2. Registrazione runner via CLI (offline registration) ───────────────
# Ogni runner ha il proprio secret da 40 caratteri hex (16 id + 24 token)
# Docs: https://forgejo.org/docs/next/admin/actions/registration/#offline-registration

echo ">> Registrazione runner1..."
RUNNER1_SECRET="$(openssl rand -hex 20)"
RUNNER1_UUID=$(docker exec -u 1000:1000 forgejo forgejo forgejo-cli actions register \
  --name runner1 \
  --secret "$RUNNER1_SECRET")
echo "   runner1 UUID: $RUNNER1_UUID"

echo ">> Registrazione runner2..."
RUNNER2_SECRET="$(openssl rand -hex 20)"
RUNNER2_UUID=$(docker exec -u 1000:1000 forgejo forgejo forgejo-cli actions register \
  --name runner2 \
  --secret "$RUNNER2_SECRET")
echo "   runner2 UUID: $RUNNER2_UUID"

# ── 3. Crea runner-config.yml con UUID, token, label e automount ─────────
# La label usa :docker://node:22-bookworm per eseguire i job in container
# Debian con Node.js 22. Docker socket accessibile via automount.
# Docs: https://forgejo.org/docs/next/admin/actions/docker-access/
# Why not :host? L'host mode esegue i job nel container runner (Alpine) che
# non ha Node.js, docker CLI, apt-get. Meglio container Debian con install
# pacchetti a runtime (docker.io + openssh-client nel workflow).

echo ">> Scrittura runner-config.yml..."
for RUNNER_NUM in 1 2; do
  if [ "$RUNNER_NUM" = "1" ]; then
    UUID="$RUNNER1_UUID"
    SECRET="$RUNNER1_SECRET"
  else
    UUID="$RUNNER2_UUID"
    SECRET="$RUNNER2_SECRET"
  fi

  cat > "runner${RUNNER_NUM}/data/runner-config.yml" << RUNNERCONF
# Configurazione Forgejo Runner v12
# Generata da 07b-setup-forgejo-runners.sh

log:
  level: info

runner:
  file: .runner
  capacity: 1
  labels:
    - ubuntu-latest:docker://node:22-bookworm

container:
  docker_host: "automount"

host:
  workdir_parent: /tmp

server:
  connections:
    forgejo:
      url: ${FORGEJO_URL}
      uuid: ${UUID}
      token: ${SECRET}
RUNNERCONF

  sudo chown 1001:1001 "runner${RUNNER_NUM}/data/runner-config.yml"
  echo "   runner${RUNNER_NUM}/data/runner-config.yml scritto."
done

# ── 4. Avvio runner ──────────────────────────────────────────────────────
echo ">> Avvio runner..."
docker compose up -d runner1 runner2

# ── 5. Verifica ──────────────────────────────────────────────────────────
sleep 3
echo ""
echo "=== Stato runner ==="
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'runner|forgejo$'
echo ""
echo "Verifica su Forgejo: Site Administration → Actions → Runners"
echo "Entrambi i runner dovrebbero apparire con pallino verde (online)."
echo ""
echo ">> Prossimo script: 08-setup-netdata.sh"
