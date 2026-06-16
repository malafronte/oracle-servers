#!/bin/bash
# =============================================================================
# 11-setup-analytics.sh — Deploy Waline + Umami + PostgreSQL su OCI ARM64
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea la struttura ~/docker/analytics/
#   - Genera .env con password casuali (se non esiste)
#   - Crea init-db.sql (database waline e umami)
#   - Genera docker-compose.yml con routing Traefik
#   - Avvia PostgreSQL + Waline + Umami
#
# Prerequisiti:
#   - Traefik attivo su traefik-net (script 04)
#   - DNS configurato: comments.malafronte.dev, analytics.malafronte.dev → IP OCI
#
# Da eseguire come:  bash 11-setup-analytics.sh
# =============================================================================
set -euo pipefail

echo "=== [11] Setup analytics — Waline + Umami + PostgreSQL ==="

ANALYTICS_DIR="$HOME/docker/analytics"

# ── 1. Crea directory e genera .env.example/.env ────────────────────────────
mkdir -p "$ANALYTICS_DIR"

if [ ! -f "$ANALYTICS_DIR/.env" ]; then
  echo ">> Generazione .env con valori casuali..."
  PG_PASS=$(openssl rand -base64 18 2>/dev/null || echo "CambiaQuestaPassword123!")
  APP_SECRET_VAL=$(openssl rand -hex 32 2>/dev/null || echo "cambiaquestohexcasuale1234567890abcdef")

  cat > "$ANALYTICS_DIR/.env" << ENVEOF
# =============================================================================
# Variabili d'ambiente — isola analytics (Waline + Umami + PostgreSQL)
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
# Generato il: $(date +%Y-%m-%d)
# =============================================================================

# ─── Dominio del sito servito ───
SITE_DOMAIN=malafronte.dev

# ─── PostgreSQL ───
POSTGRES_USER=analytics
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=analytics

# ─── Waline (sistema commenti + contatore visite) ───
WALINE_DOMAIN=comments.malafronte.dev
WALINE_DB_NAME=waline
SITE_NAME=malafronte.dev
SITE_URL=https://malafronte.dev
AUTHOR_EMAIL=admin@malafronte.eu
WALINE_LANG=it-IT
COMMENT_RATE_LIMIT=60

# ─── Umami (analytics) ───
UMAMI_DOMAIN=analytics.malafronte.dev
# Default login: admin / umami (cambiare al primo accesso da Settings → Profile)
APP_SECRET=${APP_SECRET_VAL}

# ─── Timezone ───
TZ=Europe/Rome
ENVEOF
  echo "   .env generato con password casuali."
else
  echo ">> .env già esistente, preservo i valori esistenti."
fi

echo ">> Riepilogo password in .env:"
grep -E '^(POSTGRES_PASSWORD|APP_SECRET)=' "$ANALYTICS_DIR/.env" | sed 's/=.*/=****/'

# ── 2. Crea init-db.sql ─────────────────────────────────────────────────────
echo ">> Creazione init-db.sql..."
cat > "$ANALYTICS_DIR/init-db.sql" << 'SQLEOF'
-- Crea database per Waline (sistema commenti + contatore visite)
CREATE DATABASE waline;

-- Crea database per Umami (analytics)
CREATE DATABASE umami;
SQLEOF
echo "   init-db.sql creato."

# ── 3. Crea waline.pgsql (schema tabelle PostgreSQL per Waline) ─────────────
echo ">> Creazione waline.pgsql..."
cat > "$ANALYTICS_DIR/waline.pgsql" << 'PQLEOF'
CREATE SEQUENCE IF NOT EXISTS wl_comment_seq;

CREATE TABLE IF NOT EXISTS wl_comment (
  id int check (id > 0) NOT NULL DEFAULT NEXTVAL ('wl_comment_seq'),
  user_id int DEFAULT NULL,
  comment text,
  insertedAt timestamp(0) without time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ip varchar(100) DEFAULT '',
  link varchar(255) DEFAULT NULL,
  mail varchar(255) DEFAULT NULL,
  nick varchar(255) DEFAULT NULL,
  pid int DEFAULT NULL,
  rid int DEFAULT NULL,
  sticky numeric DEFAULT NULL,
  status varchar(50) NOT NULL DEFAULT '',
  "like" int DEFAULT NULL,
  ua text,
  url varchar(255) DEFAULT NULL,
  createdAt timestamp(0) without time zone NULL DEFAULT CURRENT_TIMESTAMP,
  updatedAt timestamp(0) without time zone NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
);

CREATE SEQUENCE IF NOT EXISTS wl_counter_seq;

CREATE TABLE IF NOT EXISTS wl_counter (
  id int check (id > 0) NOT NULL DEFAULT NEXTVAL ('wl_counter_seq'),
  time int DEFAULT NULL,
  reaction0 int DEFAULT NULL,
  reaction1 int DEFAULT NULL,
  reaction2 int DEFAULT NULL,
  reaction3 int DEFAULT NULL,
  reaction4 int DEFAULT NULL,
  reaction5 int DEFAULT NULL,
  reaction6 int DEFAULT NULL,
  reaction7 int DEFAULT NULL,
  reaction8 int DEFAULT NULL,
  url varchar(255) NOT NULL DEFAULT '',
  createdAt timestamp(0) without time zone NULL DEFAULT CURRENT_TIMESTAMP,
  updatedAt timestamp(0) without time zone NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
);

CREATE SEQUENCE IF NOT EXISTS wl_users_seq;

CREATE TABLE IF NOT EXISTS wl_users (
  id int check (id > 0) NOT NULL DEFAULT NEXTVAL ('wl_users_seq'),
  display_name varchar(255) NOT NULL DEFAULT '',
  email varchar(255) NOT NULL DEFAULT '',
  password varchar(255) NOT NULL DEFAULT '',
  type varchar(50) NOT NULL DEFAULT '',
  label varchar(255) DEFAULT NULL,
  url varchar(255) DEFAULT NULL,
  avatar varchar(255) DEFAULT NULL,
  github varchar(255) DEFAULT NULL,
  twitter varchar(255) DEFAULT NULL,
  facebook varchar(255) DEFAULT NULL,
  google varchar(255) DEFAULT NULL,
  weibo varchar(255) DEFAULT NULL,
  qq varchar(255) DEFAULT NULL,
  oidc varchar(255) DEFAULT NULL,
  huawei varchar(255) DEFAULT NULL,
  "2fa" varchar(32) DEFAULT NULL,
  createdAt timestamp(0) without time zone NULL DEFAULT CURRENT_TIMESTAMP,
  updatedAt timestamp(0) without time zone NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
);
PQLEOF
echo "   waline.pgsql creato."

# ── 4. Genera docker-compose.yml ────────────────────────────────────────────
echo ">> Generazione docker-compose.yml..."

cat > "$ANALYTICS_DIR/docker-compose.yml" << 'COMPOSEEOF'
services:
  # =====================================================================
  # PostgreSQL — database condiviso per Waline e Umami
  # =====================================================================
  postgres:
    image: postgres:16-alpine
    container_name: analytics-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
      - TZ=${TZ}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-db.sql:/docker-entrypoint-initdb.d/init-db.sql:ro
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  # =====================================================================
  # Waline — sistema commenti + contatore visite
  # =====================================================================
  waline:
    image: lizheming/waline:latest
    container_name: analytics-waline
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - TZ=${TZ}
      # Connessione PostgreSQL
      - PG_HOST=postgres
      - PG_PORT=5432
      - PG_DB=${WALINE_DB_NAME}
      - PG_USER=${POSTGRES_USER}
      - PG_PASSWORD=${POSTGRES_PASSWORD}
      # Configurazione sito
      - SITE_NAME=${SITE_NAME}
      - SITE_URL=${SITE_URL}
      - AUTHOR_EMAIL=${AUTHOR_EMAIL}
      - LANG=${WALINE_LANG}
      - SECURE_DOMAINS=${SITE_DOMAIN},${WALINE_DOMAIN}
      # Sicurezza e moderazione
      - COMMENT_RATE_LIMIT=${COMMENT_RATE_LIMIT:-60}
    networks:
      - internal
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.waline.rule=Host(`${WALINE_DOMAIN}`)"
      - "traefik.http.routers.waline.entrypoints=websecure"
      - "traefik.http.routers.waline.tls.certresolver=letsencrypt"
      - "traefik.http.services.waline.loadbalancer.server.port=8360"
    healthcheck:
      test: ["CMD-SHELL", "node -e 'require(\"http\").get(\"http://localhost:8360/ui/\",r=>process.exit(r.statusCode===200?0:1))'"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

  # =====================================================================
  # Umami — web analytics privacy-friendly (senza cookie)
  # =====================================================================
  umami:
    image: ghcr.io/umami-software/umami:postgresql-latest
    container_name: analytics-umami
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/umami
      - DATABASE_TYPE=postgresql
      - APP_SECRET=${APP_SECRET}
      - TZ=${TZ}
    networks:
      - internal
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.umami.rule=Host(`${UMAMI_DOMAIN}`)"
      - "traefik.http.routers.umami.entrypoints=websecure"
      - "traefik.http.routers.umami.tls.certresolver=letsencrypt"
      - "traefik.http.services.umami.loadbalancer.server.port=3000"
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:3000/api/heartbeat"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s

volumes:
  postgres_data:
    driver: local

networks:
  internal:
    driver: bridge
  traefik-net:
    external: true
COMPOSEEOF

echo "   docker-compose.yml generato."

# ── 4. Avvio stack ──────────────────────────────────────────────────────────
cd "$ANALYTICS_DIR"

# Se già in esecuzione, pull e restart
if docker compose ps 2>/dev/null | grep -q 'analytics-'; then
  echo ">> Analytics già in esecuzione. Pull e restart..."
  docker compose pull
  docker compose up -d --remove-orphans
  echo ""
  echo "=== Stack analytics aggiornato ==="
  echo "  Waline:  https://$(grep '^WALINE_DOMAIN=' .env | cut -d= -f2)"
  echo "  Umami:   https://$(grep '^UMAMI_DOMAIN=' .env | cut -d= -f2)"
  exit 0
fi

echo ">> Primo avvio stack analytics (PostgreSQL + Waline + Umami)..."
docker compose up -d

# ── 5. Importa schema Waline in PostgreSQL ───────────────────────────────────
echo ">> Attesa PostgreSQL healthy..."
sleep 5
for i in $(seq 1 12); do
  if docker exec analytics-postgres pg_isready -U analytics -d waline &>/dev/null; then
    echo "   PostgreSQL e database waline pronti."
    break
  fi
  sleep 5
done

echo ">> Importazione schema tabelle Waline..."
if docker exec analytics-postgres psql -U analytics -d waline -c "\dt" 2>/dev/null | grep -q 'wl_users'; then
  echo "   Tabelle Waline già presenti, skip."
else
  docker exec -i analytics-postgres psql -U analytics -d waline < "$ANALYTICS_DIR/waline.pgsql"
  echo "   Tabelle Waline create."
fi

echo ""
echo "=== Stack analytics avviato con successo ==="
echo ""
echo "  Waline:  https://$(grep '^WALINE_DOMAIN=' .env | cut -d= -f2)"
echo "  Umami:   https://$(grep '^UMAMI_DOMAIN=' .env | cut -d= -f2)"
echo ""
echo "  Credenziali Umami (default):"
echo "    Utente:   admin"
echo "    Password: umami"
echo "  ⚠️  Cambia la password al primo accesso (Settings → Profile)"
echo ""
echo "  Post-deploy (da browser):"
echo "    1. Waline: registrati su /ui/register (primo utente = admin)"
echo "    2. Umami:  login, aggiungi sito, copia tracking code"
echo "    3. Inserisci il tracking code nel <head> del sito Astro"
echo ""
echo "  DNS richiesto (record A → IP del server OCI):"
echo "    comments.malafronte.dev"
echo "    analytics.malafronte.dev"
echo ""
echo "  Comandi utili:"
echo "    cd ~/docker/analytics"
echo "    docker compose ps"
echo "    docker compose logs -f --tail=50"
