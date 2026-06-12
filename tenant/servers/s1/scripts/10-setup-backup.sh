#!/bin/bash
# =============================================================================
# 10-setup-backup.sh — Configurazione backup automatico su OCI Object Storage
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea lo script di backup giornaliero (~/docker/backup.sh)
#   - Crea lo script di deploy rapido (~/docker/deploy.sh)
#   - Configura il cron job per backup notturno alle 3:00
#
# Prerequisito:
#   1. OCI CLI già installata sul server (sudo snap install oci-cli --classic)
#   2. Bucket OCI già creato (vedi oci-setup/README.md)
#   3. Dynamic Group e Policy IAM già configurati per Instance Principal
#
# Da eseguire come:  bash 10-setup-backup.sh
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

echo "=== [10/11] Setup Backup automatico su OCI ==="

DOCKER_DIR="$HOME/docker"

# ── 1. Verifica OCI CLI ────────────────────────────────────────────────────
echo ">> Verifica OCI CLI..."
if ! command -v oci &> /dev/null; then
  echo "ATTENZIONE: OCI CLI non trovata. Installala con:"
  echo "  sudo snap install oci-cli --classic"
  echo ""
  echo "Poi verifica l'Instance Principal:"
  echo "  oci os object list --bucket-name ${BACKUP_BUCKET_NAME} --auth instance_principal"
  echo ""
  echo "Proseguo comunque con la creazione degli script..."
else
  echo "   OCI CLI trovata: $(oci --version)"

  # Verifica accesso al bucket
  echo ">> Verifica accesso al bucket '${BACKUP_BUCKET_NAME}' via Instance Principal..."
  if oci os object list --bucket-name "${BACKUP_BUCKET_NAME}" --auth instance_principal &>/dev/null; then
    echo "   Accesso al bucket OK."
  else
    echo "   ATTENZIONE: Accesso al bucket fallito."
    echo "   Assicurati di aver configurato Dynamic Group e Policy IAM (vedi oci-setup/README.md)"
  fi
fi

# ── 2. Script di backup ────────────────────────────────────────────────────
echo ">> Creazione script backup.sh..."
cat > "$DOCKER_DIR/backup.sh" << BACKUPEOF
#!/bin/bash
# =============================================================================
# backup.sh — Backup giornaliero su OCI Object Storage
# Esegue il backup di: registry, postgres, forgejo
# =============================================================================
set -e

BUCKET="${BACKUP_BUCKET_NAME}"
BACKUP_FILE="/tmp/s1-backup-\$(date +%Y-%m-%d).tar.gz"
LOG_FILE="$HOME/docker/backup.log"
RETENTION_DAYS=7

echo "[\$(date)] Inizio backup..." | tee -a "\$LOG_FILE"

# Backup dei dati critici:
# - Immagini Docker Registry (registry/data/)
# - Credenziali htpasswd (registry/auth/)
# - Database PostgreSQL Forgejo (postgres/)
# - Dati aggiuntivi Forgejo (forgejo/data/)
tar czf "\$BACKUP_FILE" \
  -C "$HOME/docker" \
  registry/data/ \
  registry/auth/ \
  postgres/ \
  forgejo/data/ \
  2>/dev/null || true

# Se OCI CLI è disponibile, carica il backup
if command -v oci &> /dev/null; then
  echo "[\$(date)] Caricamento backup su OCI..." | tee -a "\$LOG_FILE"
  oci os object put \
    --bucket-name "\$BUCKET" \
    --file "\$BACKUP_FILE" \
    --name "s1-backup-\$(date +%Y-%m-%d).tar.gz" \
    --auth instance_principal \
    --force \
    2>&1 | tee -a "\$LOG_FILE"
else
  echo "[\$(date)] OCI CLI non disponibile, backup salvato solo localmente: \$BACKUP_FILE" | tee -a "\$LOG_FILE"
fi

# Pulisci backup locali vecchi (oltre RETENTION_DAYS giorni)
find /tmp -name "s1-backup-*" -mtime +\$RETENTION_DAYS -delete 2>/dev/null || true

echo "[\$(date)] Backup completato: \$(du -h "\$BACKUP_FILE" | cut -f1)" | tee -a "\$LOG_FILE"
BACKUPEOF

chmod +x "$DOCKER_DIR/backup.sh"
echo "   ~/docker/backup.sh creato."

# ── 3. Script di deploy ────────────────────────────────────────────────────
echo ">> Creazione script deploy.sh..."
cat > "$DOCKER_DIR/deploy.sh" << 'DEPLOYEOF'
#!/bin/bash
# =============================================================================
# deploy.sh — Deploy rapido di un progetto docker-compose
# Uso: ./deploy.sh <nome-progetto>
# =============================================================================
set -euo pipefail

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
DEPLOYEOF

chmod +x "$DOCKER_DIR/deploy.sh"
echo "   ~/docker/deploy.sh creato."

# ── 4. Cron job per backup notturno ────────────────────────────────────────
echo ">> Configurazione cron job (backup ogni giorno alle 3:00)..."
(crontab -l 2>/dev/null | grep -v "$DOCKER_DIR/backup.sh" || true; \
 echo "0 3 * * * $DOCKER_DIR/backup.sh") | crontab -

echo "   Cron job configurato."

echo ""
echo "=== Backup configurato con successo ==="
echo ""
echo "Script creati:"
echo "  ~/docker/backup.sh   — backup manuale o automatico (cron)"
echo "  ~/docker/deploy.sh   — deploy rapido di un progetto"
echo ""
echo "Test manuale:"
echo "  ~/docker/backup.sh"
echo ""
echo "Verifica cron:"
echo "  crontab -l"
echo ""
echo "Ripristino da backup (vedi README.md per la procedura completa):"
echo "  oci os object get --bucket-name ${BACKUP_BUCKET_NAME} --name s1-backup-YYYY-MM-DD.tar.gz --file /tmp/restore.tar.gz --auth instance_principal"
