#!/bin/bash
# =============================================================================
# backup.sh — Backup giornaliero su OCI Object Storage
# Da copiare sul server in ~/docker/backup.sh
#
# Cosa backuppa:
#   - Immagini Docker Registry (registry/data/)
#   - Credenziali htpasswd (registry/auth/)
#   - Database PostgreSQL Forgejo (postgres/)
#   - Dati aggiuntivi Forgejo (forgejo/data/)
#
# Prerequisiti:
#   - OCI CLI installata (sudo snap install oci-cli --classic)
#   - Dynamic Group e Policy IAM configurati (vedi oci-setup/README.md)
#   - Bucket s1-backup creato su OCI Object Storage
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  source <(sed 's/\r$//' "$SCRIPT_DIR/.env")
else
  echo "ERRORE: File .env non trovato in $SCRIPT_DIR"
  echo "Copia .env.example in .env e inserisci i valori reali."
  exit 1
fi

BACKUP_FILE="/tmp/s1-backup-$(date +%Y-%m-%d).tar.gz"
LOG_FILE="$HOME/docker/backup.log"
RETENTION_DAYS=7

echo "[$(date)] Inizio backup..." | tee -a "$LOG_FILE"

# Backup dei dati critici:
# - Immagini Docker Registry (registry/data/)
# - Credenziali htpasswd (registry/auth/)
# - Database PostgreSQL Forgejo (postgres/)
# - Dati aggiuntivi Forgejo (forgejo/data/)
tar czf "$BACKUP_FILE" \
  -C "$HOME/docker" \
  registry/data/ \
  registry/auth/ \
  postgres/ \
  forgejo/data/ \
  2>/dev/null || true

# Carica su OCI Object Storage
if command -v oci &> /dev/null; then
  echo "[$(date)] Caricamento backup su OCI..." | tee -a "$LOG_FILE"
  oci os object put \
    --bucket-name "${BACKUP_BUCKET_NAME}" \
    --file "$BACKUP_FILE" \
    --name "s1-backup-$(date +%Y-%m-%d).tar.gz" \
    --auth instance_principal \
    --force \
    2>&1 | tee -a "$LOG_FILE"
else
  echo "[$(date)] OCI CLI non disponibile, backup salvato solo localmente: $BACKUP_FILE" | tee -a "$LOG_FILE"
fi

# Pulisci backup locali vecchi (oltre RETENTION_DAYS giorni)
find /tmp -name "s1-backup-*" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true

echo "[$(date)] Backup completato: $(du -h "$BACKUP_FILE" | cut -f1)" | tee -a "$LOG_FILE"
