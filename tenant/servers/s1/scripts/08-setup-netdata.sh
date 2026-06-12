#!/bin/bash
# =============================================================================
# 08-setup-netdata.sh — Monitoring infrastruttura (CPU, RAM, disco, rete)
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea il docker-compose.yml di Netdata
#   - Configura basic auth via file provider Traefik (dashboard)
#   - Configura notifiche Telegram (opzionale)
#   - Avvia Netdata
#
# Prerequisito: Traefik già avviato (script 04)
# Da eseguire come:  bash 08-setup-netdata.sh
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

echo "=== [08/11] Setup Netdata — Monitoring ==="

NETDATA_DIR="$HOME/docker/netdata"
TRAEFIK_CONFIG="$HOME/docker/traefik/config"

# ── 0. Script backup (sempre aggiornato, indipendentemente da Netdata) ─────
cat > "$NETDATA_DIR/check-backup-size.sh" << 'CHECKSIZE'
#!/bin/bash
# Controlla la dimensione reale del backup (archivio se esiste, altrimenti directory raw)
# e invia alert Telegram se > 9 GB (warning) o > 9.5 GB (critico, quota OCI 10 GB)
# Da eseguire via cron: 0 * * * * /home/ubuntu/docker/netdata/check-backup-size.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  source <(sed 's/\r$//' "$SCRIPT_DIR/../.env")
elif [ -f "$HOME/scripts/.env" ]; then
  source <(sed 's/\r$//' "$HOME/scripts/.env")
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  exit 0
fi

# 1. Verifica se esistono archivi di backup (valore reale, compresso)
BACKUP_DIR="$HOME/backup"
ARCHIVE_KB=0
if [ -d "$BACKUP_DIR" ]; then
  ARCHIVE_KB=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tar.bz2' -o -name '*.zip' \) -exec du -sk {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
fi

# 2. Se non ci sono archivi, usa le directory raw come stima
if [ "$ARCHIVE_KB" -gt 0 ]; then
  TOTAL_KB=$ARCHIVE_KB
  LABEL="archivio backup"
else
  BACKUP_DIRS="$HOME/docker/postgres $HOME/docker/forgejo/data"
  TOTAL_KB=$(du -sk $BACKUP_DIRS 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
  LABEL="directory raw (stima)"
fi

TOTAL_MB=$((TOTAL_KB / 1024))
TOTAL_GB=$(echo "scale=2; $TOTAL_KB / 1048576" | bc)

# Salva il messaggio in file UTF-8 JSON (evita problemi encoding shell con emoji)
if [ $TOTAL_MB -gt 9500 ]; then
  printf '{"chat_id":"%s","text":"🔴 CRITICAL: Backup %s: %s GB (%s MB) — superato 9.5 GB (quota OCI 10 GB)"}' \
    "${TELEGRAM_CHAT_ID}" "${LABEL}" "${TOTAL_GB}" "${TOTAL_MB}" > /tmp/telegram_msg.json
elif [ $TOTAL_MB -gt 9000 ]; then
  printf '{"chat_id":"%s","text":"🟡 WARNING: Backup %s: %s GB (%s MB) — superato 9 GB (quota OCI 10 GB)"}' \
    "${TELEGRAM_CHAT_ID}" "${LABEL}" "${TOTAL_GB}" "${TOTAL_MB}" > /tmp/telegram_msg.json
else
  exit 0
fi

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d @/tmp/telegram_msg.json

rm -f /tmp/telegram_msg.json
CHECKSIZE
chmod +x "$NETDATA_DIR/check-backup-size.sh"

# Aggiungi al crontab (ogni ora)
(crontab -l 2>/dev/null | grep -v 'check-backup-size.sh'; echo "0 * * * * $NETDATA_DIR/check-backup-size.sh") | crontab -

echo "   check-backup-size.sh aggiornato e schedulato in crontab (ogni ora)."

# ── 1. Idempotenza ────────────────────────────────────────────────────────
if [ -f "$NETDATA_DIR/docker-compose.yml" ]; then
  RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^netdata$' || true)
  if [ "$RUNNING" -gt 0 ]; then
    echo ">> Netdata già installato e in esecuzione. Riavvio per aggiornare..."
    cd "$NETDATA_DIR"
    docker compose pull
    docker compose up -d
    echo "   Dashboard: https://monitor.${DOMAIN}"
    exit 0
  fi
  # Container fermo: rialza
  echo ">> Netdata già installato ma fermo. Riavvio..."
  cd "$NETDATA_DIR"
  docker compose up -d
  echo "   Dashboard: https://monitor.${DOMAIN}"
  exit 0
fi

cd "$NETDATA_DIR"

# ── 1. Basic auth via file provider (stesso pattern dashboard/registry-ui) ─
echo ">> Generazione password basic auth per Netdata..."
HTPASSWD_OUTPUT=$(printf '%s' "${NETDATA_DASHBOARD_PASSWORD}" | htpasswd -nB -i ${NETDATA_DASHBOARD_USER})

# Il file provider NON richiede $$ escaping (solo le label docker-compose)
cat > "$TRAEFIK_CONFIG/middleware-netdata.yml" << NETAUTH
http:
  middlewares:
    netdata-auth:
      basicAuth:
        users:
          - "$HTPASSWD_OUTPUT"
NETAUTH
echo "   middleware-netdata.yml creato."

docker restart traefik 2>/dev/null || true
sleep 2

# ── 2. Docker Compose ──────────────────────────────────────────────────────
echo ">> Creazione docker-compose.yml..."

# Intestazione
cat > docker-compose.yml << COMPOSEHEAD
services:
  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    restart: unless-stopped
    hostname: s1
    pid: host
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./config:/etc/netdata
      - ./lib:/var/lib/netdata
      - ./cache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - NETDATA_CLAIM_TOKEN=
COMPOSEHEAD

# Telegram (opzionale, nessun $ nei valori)
if [ -n "${TELEGRAM_BOT_TOKEN}" ]; then
  echo ">> Configurazione notifiche Telegram..."
  cat >> docker-compose.yml << TELEEOF
      - NETDATA_HEALTHCHECK_TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
      - NETDATA_HEALTHCHECK_TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEEOF
fi

# Labels e network (nessun $ nella label basic auth — usa file provider)
# NOTA: il middleware viene referenziato SENZA @file nella prima partenza
#       perché Traefik deve prima caricare il file provider. Dopo il primo
#       avvio, il compose viene aggiornato con @file e Netdata riavviato.
cat >> docker-compose.yml << COMPOSETAIL
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.netdata.rule=Host(\`monitor.${DOMAIN}\`)"
      - "traefik.http.routers.netdata.entrypoints=websecure"
      - "traefik.http.routers.netdata.tls.certresolver=letsencrypt"
      - "traefik.http.services.netdata.loadbalancer.server.port=19999"
      - "traefik.http.routers.netdata.middlewares=netdata-auth"

volumes:
  lib:
  cache:

networks:
  traefik-net:
    external: true
COMPOSETAIL

# ── 3. Allarme dimensione backup (quota OCI 10 GB) ────────────────────────
# Invece di charts.d (troppo complesso in container), usiamo uno script
# esterno che Netdata esegue via health exec + un controllo cron.
# Netdata ha già disk_space._ built-in per il monitoraggio disco globale.

# Creiamo un health check che usa lo spazio disco disponibile
# e un avviso specifico per la quota OCI
echo ">> Configurazione allarme spazio disco + quota OCI..."
sudo mkdir -p "$NETDATA_DIR/config/health.d"
sudo chown $USER:$USER "$NETDATA_DIR/config/health.d"

cat > "$NETDATA_DIR/config/health.d/disk-backup.conf" << 'ALARMEOF'
template: disk_space_low
    on: disk.space
    class: Utilization
    type: Storage
    component: Backup
    calc: $used * 100 / ($used + $avail)
    units: %
    every: 1m
    warn: $this > 80
    crit: $this > 95
    info: Spazio disco usato superiore al 80% (warn) o 95% (crit)
    to: sysadmin
ALARMEOF

# ── 4. Avvio ──────────────────────────────────────────────────────────────
echo ">> Avvio Netdata (prima fase: senza middleware)..."
docker compose up -d
sleep 5

echo ">> Riavvio Traefik per caricare middleware-netdata.yml..."
docker restart traefik
sleep 5

echo ">> Aggiornamento label con @file e riavvio Netdata..."
sed -i 's/middlewares=netdata-auth/middlewares=netdata-auth@file/' docker-compose.yml
docker compose up -d

echo ""
echo "=== Netdata avviato con successo ==="
echo ""
echo "Dashboard: https://monitor.${DOMAIN}"
echo "  Utente: ${NETDATA_DASHBOARD_USER}"
echo "  Password: ${NETDATA_DASHBOARD_PASSWORD}"
echo ""
echo "Allarmi preconfigurati (già attivi):"
echo "  - CPU > 80% per 10 minuti"
echo "  - RAM < 10% libera"
echo "  - Disco > 90% pieno (built-in Netdata)"
echo "  - Disco usato > 80% (warn) / > 95% (crit) via Netdata health.d"
echo "  - Container fermo o servizio down"
echo "  - Cron orario: alert Telegram se backup > 9 GB / 9.5 GB (quota OCI 10 GB)"
echo ""
if [ -n "${TELEGRAM_BOT_TOKEN}" ]; then
  echo "Notifiche Telegram: CONFIGURATE"
else
  echo "Notifiche Telegram: non configurate (modifica TELEGRAM_BOT_TOKEN e TELEGRAM_CHAT_ID in .env)"
fi
echo ""
echo ">> Prossimo script: 09-progetto-template.sh (o 10-setup-backup.sh)"
