#!/bin/bash
# =============================================================================
# 09-setup-cinebase.sh — Deploy stack CineBase su OCI ARM64 dietro Traefik
# Server: malafronte-oci-s1 (ARM Ubuntu 24.04)
#
# Cosa fa:
#   - Crea la struttura ~/docker/cinebase/
#   - Genera docker-compose.yml con routing Traefik
#   - Copia .env.example in .env (se non esiste)
#   - Avvia MariaDB + FilmAPI + Seeder + CineBase.Web
#
# Prerequisiti:
#   - Traefik attivo su traefik-net (script 04)
#   - Registry attivo su registry.malafronte.eu (script 06)
#   - DNS configurato: www.cinebase.it, api.cinebase.it, cinebase.it → 129.152.30.86
#   - Immagini buildate e pushate su registry (prima esecuzione) o CI/CD attivo
#
# Da eseguire come:  bash 09-setup-cinebase.sh
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

echo "=== [09] Setup CineBase stack ==="

CINEBASE_DIR="$HOME/docker/cinebase"
TEMPLATE_DIR="$SCRIPT_DIR/../cinebase"

# ── 1. Crea directory e copia .env ──────────────────────────────────────────
mkdir -p "$CINEBASE_DIR"

if [ ! -f "$CINEBASE_DIR/.env" ]; then
  if [ -f "$TEMPLATE_DIR/.env.example" ]; then
    cp "$TEMPLATE_DIR/.env.example" "$CINEBASE_DIR/.env"
    echo ">> .env creato da template. MODIFICALO con i valori reali prima di continuare."
    echo "   File: $CINEBASE_DIR/.env"
    exit 0
  else
    echo "ERRORE: Template .env.example non trovato in $TEMPLATE_DIR"
    exit 1
  fi
fi

# ── 2. Genera docker-compose.yml ────────────────────────────────────────────
echo ">> Generazione docker-compose.yml..."

cat > "$CINEBASE_DIR/docker-compose.yml" << 'COMPOSE'
services:
  mariadb:
    image: mariadb:10.11
    container_name: cinebase-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - mariadb-data:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h 127.0.0.1 -uroot -p${MYSQL_ROOT_PASSWORD} --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 25s
    networks:
      - cinebase-net

  filmapi:
    image: registry.malafronte.eu/cinebase/filmapi:latest
    container_name: cinebase-filmapi
    restart: unless-stopped
    depends_on:
      mariadb:
        condition: service_healthy
    environment:
      ASPNETCORE_ENVIRONMENT: ${ASPNETCORE_ENVIRONMENT:-Production}
      ASPNETCORE_URLS: http://+:8080
      DB_HOST: ${DB_HOST:-mariadb}
      DB_PORT: "${DB_PORT:-3306}"
      DB_NAME: ${DB_NAME:-film-api-db}
      DB_USER: ${DB_USER:-cinebase}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_USE_AUTODETECT: "${DB_USE_AUTODETECT:-false}"
      DB_SERVER_VERSION: ${DB_SERVER_VERSION:-10.11.0-mariadb}
      DB_STARTUP_MAX_RETRIES: "${DB_STARTUP_MAX_RETRIES:-10}"
      DB_STARTUP_RETRY_DELAY_SECONDS: "${DB_STARTUP_RETRY_DELAY_SECONDS:-3}"
      JWT_SECRET: ${JWT_SECRET}
      JWT_ISSUER: ${JWT_ISSUER:-CineBaseAPI}
      JWT_AUDIENCE: ${JWT_AUDIENCE:-CineBaseWeb}
      ADMIN_SEED_EMAIL: ${ADMIN_SEED_EMAIL:-admin@cinebase.it}
      ADMIN_SEED_PASSWORD: ${ADMIN_SEED_PASSWORD}
      DEFAULT_TICKET_PRICE: ${DEFAULT_TICKET_PRICE:-8.50}
      DEFAULT_COVER_IMAGE_PATH: ${DEFAULT_COVER_IMAGE_PATH:-/media/defaults/cover-default.jpg}
      FRONTEND_PUBLIC_BASE_URL: ${FRONTEND_PUBLIC_BASE_URL:-https://www.cinebase.it}
      CORS_ALLOWED_ORIGINS: ${CORS_ALLOWED_ORIGINS:-https://www.cinebase.it}
      TICKET_VALIDATION_BASE_URL: ${TICKET_VALIDATION_BASE_URL:-/admin/biglietti/validazione}
      LOCAL_EMAIL_VERIFICATION_ENFORCED_SINCE_UTC: ${LOCAL_EMAIL_VERIFICATION_ENFORCED_SINCE_UTC:-2026-05-19T00:00:00Z}
      SMTP_HOST: ${SMTP_HOST}
      SMTP_PORT: ${SMTP_PORT:-465}
      SMTP_USER: ${SMTP_USER}
      SMTP_PASSWORD: ${SMTP_PASSWORD}
      SMTP_FROM_EMAIL: ${SMTP_FROM_EMAIL}
      SMTP_FROM_NAME: ${SMTP_FROM_NAME:-CineBase}
      SMTP_REQUIRE_AUTH: ${SMTP_REQUIRE_AUTH:-true}
      SMTP_SECURE_SOCKET_OPTIONS: ${SMTP_SECURE_SOCKET_OPTIONS:-SslOnConnect}
      TMDB_BEARER_TOKEN: ${TMDB_BEARER_TOKEN:-}
      STRIPE_SECRET_API_KEY: ${STRIPE_SECRET_API_KEY:-}
      STRIPE_PUBLISHABLE_API_KEY: ${STRIPE_PUBLISHABLE_API_KEY:-}
      STRIPE_WEBHOOK_SECRET: ${STRIPE_WEBHOOK_SECRET:-}
      GOOGLE_OAUTH_CLIENT_ID: ${GOOGLE_OAUTH_CLIENT_ID:-}
      GOOGLE_OAUTH_CLIENT_SECRET: ${GOOGLE_OAUTH_CLIENT_SECRET:-}
      GOOGLE_OAUTH_REDIRECT_URI: ${GOOGLE_OAUTH_REDIRECT_URI:-}
      MICROSOFT_OAUTH_CLIENT_ID: ${MICROSOFT_OAUTH_CLIENT_ID:-}
      MICROSOFT_OAUTH_CLIENT_SECRET: ${MICROSOFT_OAUTH_CLIENT_SECRET:-}
      MICROSOFT_OAUTH_REDIRECT_URI: ${MICROSOFT_OAUTH_REDIRECT_URI:-}
      MICROSOFT_AUTHORITY: ${MICROSOFT_AUTHORITY:-}
      GOOGLE_REQUIRE_EMAIL_VERIFIED: ${GOOGLE_REQUIRE_EMAIL_VERIFIED:-true}
      MICROSOFT_REQUIRE_EMAIL_CLAIM: ${MICROSOFT_REQUIRE_EMAIL_CLAIM:-true}
      JWT_ACCESS_TOKEN_EXPIRY_MINUTES: "${JWT_ACCESS_TOKEN_EXPIRY_MINUTES:-15}"
      JWT_REFRESH_TOKEN_EXPIRY_DAYS: "${JWT_REFRESH_TOKEN_EXPIRY_DAYS:-7}"
      HOLD_TTL_MINUTES: "${HOLD_TTL_MINUTES:-10}"
      LOGIN_RATE_LIMIT_PERMITS: "${LOGIN_RATE_LIMIT_PERMITS:-10}"
      LOGIN_RATE_LIMIT_WINDOW_SECONDS: "${LOGIN_RATE_LIMIT_WINDOW_SECONDS:-60}"
      FORGOT_PASSWORD_RATE_LIMIT_PERMITS: "${FORGOT_PASSWORD_RATE_LIMIT_PERMITS:-3}"
      FORGOT_PASSWORD_RATE_LIMIT_WINDOW_SECONDS: "${FORGOT_PASSWORD_RATE_LIMIT_WINDOW_SECONDS:-300}"
      PRIVACY_POLICY_VERSION: ${PRIVACY_POLICY_VERSION:-2026-05-10-draft-01}
      TERMS_CONDITIONS_VERSION: ${TERMS_CONDITIONS_VERSION:-2026-05-10-draft-01}
      COOKIE_POLICY_VERSION: ${COOKIE_POLICY_VERSION:-2026-05-10-draft-01}
      LEGAL_DPO_ENABLED: ${LEGAL_DPO_ENABLED:-false}
      EMAIL_VERIFICATION_TOKEN_TTL_MINUTES: "${EMAIL_VERIFICATION_TOKEN_TTL_MINUTES:-1440}"
      PASSWORD_RESET_TOKEN_TTL_MINUTES: "${PASSWORD_RESET_TOKEN_TTL_MINUTES:-30}"
      SET_PASSWORD_TOKEN_TTL_MINUTES: "${SET_PASSWORD_TOKEN_TTL_MINUTES:-60}"
      ADMIN_INVITE_TOKEN_TTL_HOURS: "${ADMIN_INVITE_TOKEN_TTL_HOURS:-24}"
      AUTH_EXTERNAL_STATE_TTL_MINUTES: "${AUTH_EXTERNAL_STATE_TTL_MINUTES:-10}"
      AUTH_EXTERNAL_EXCHANGE_TTL_MINUTES: "${AUTH_EXTERNAL_EXCHANGE_TTL_MINUTES:-2}"
      ACCOUNT_DELETION_TOKEN_TTL_MINUTES: "${ACCOUNT_DELETION_TOKEN_TTL_MINUTES:-60}"
      REFRESH_TOKEN_CLEANUP_INTERVAL_MINUTES: "${REFRESH_TOKEN_CLEANUP_INTERVAL_MINUTES:-30}"
      HOLD_CLEANUP_INTERVAL_MINUTES: "${HOLD_CLEANUP_INTERVAL_MINUTES:-5}"
      PENDING_ORDER_MAX_AGE_MINUTES: "${PENDING_ORDER_MAX_AGE_MINUTES:-30}"
    volumes:
      - media-uploads:/app/wwwroot/media/covers
    networks:
      - cinebase-net
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.cinebase-api.rule=Host(`api.cinebase.it`)"
      - "traefik.http.routers.cinebase-api.entrypoints=websecure"
      - "traefik.http.routers.cinebase-api.tls.certresolver=letsencrypt"
      - "traefik.http.services.cinebase-api.loadbalancer.server.port=8080"

  seeder:
    image: registry.malafronte.eu/cinebase/seeder:latest
    container_name: cinebase-seeder
    restart: "no"
    depends_on:
      mariadb:
        condition: service_healthy
      filmapi:
        condition: service_healthy
    environment:
      DB_HOST: ${DB_HOST:-mariadb}
      DB_PORT: "${DB_PORT:-3306}"
      DB_NAME: ${DB_NAME:-film-api-db}
      DB_USER: ${DB_USER:-cinebase}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_USE_AUTODETECT: "${DB_USE_AUTODETECT:-false}"
      DB_SERVER_VERSION: ${DB_SERVER_VERSION:-10.11.0-mariadb}
      DB_STARTUP_MAX_RETRIES: "${DB_STARTUP_MAX_RETRIES:-10}"
      DB_STARTUP_RETRY_DELAY_SECONDS: "${DB_STARTUP_RETRY_DELAY_SECONDS:-3}"
      DEFAULT_TICKET_PRICE: ${DEFAULT_TICKET_PRICE:-8.50}
      SEED_SOURCE_MODE: ${SEED_SOURCE_MODE:-snapshot}
      SEED_SNAPSHOT_FILE: ${SEED_SNAPSHOT_FILE:-/app/data/catalog-snapshot.json}
      TMDB_BEARER_TOKEN: ${TMDB_BEARER_TOKEN:-}
    networks:
      - cinebase-net

  cinebase-web:
    image: registry.malafronte.eu/cinebase/web:latest
    container_name: cinebase-web
    restart: unless-stopped
    depends_on:
      filmapi:
        condition: service_healthy
      seeder:
        condition: service_completed_successfully
    environment:
      ASPNETCORE_ENVIRONMENT: ${ASPNETCORE_ENVIRONMENT:-Production}
      ASPNETCORE_URLS: http://+:8080
      API_BASE_URL: ${API_BASE_URL:-https://api.cinebase.it/api}
      MEDIA_BASE_URL: ${MEDIA_BASE_URL:-https://api.cinebase.it/media}
      DEPLOYMENT_MODE: ${DEPLOYMENT_MODE:-direct-backend}
      SHOW_DISCLAIMER: ${SHOW_DISCLAIMER:-false}
    networks:
      - cinebase-net
      - traefik-net
    labels:
      # Sito principale: www.cinebase.it
      - "traefik.enable=true"
      - "traefik.http.routers.cinebase-web.rule=Host(`www.cinebase.it`)"
      - "traefik.http.routers.cinebase-web.entrypoints=websecure"
      - "traefik.http.routers.cinebase-web.tls.certresolver=letsencrypt"
      - "traefik.http.services.cinebase-web.loadbalancer.server.port=8080"
      # Redirect cinebase.it → www.cinebase.it (301 permanente)
      - "traefik.http.routers.cinebase-redirect.rule=Host(`cinebase.it`)"
      - "traefik.http.routers.cinebase-redirect.entrypoints=websecure"
      - "traefik.http.routers.cinebase-redirect.tls.certresolver=letsencrypt"
      - "traefik.http.routers.cinebase-redirect.middlewares=cinebase-redirect-www"
      - "traefik.http.middlewares.cinebase-redirect-www.redirectregex.regex=^https://cinebase\\.it/(.*)"
      - "traefik.http.middlewares.cinebase-redirect-www.redirectregex.replacement=https://www.cinebase.it/$${1}"
      - "traefik.http.middlewares.cinebase-redirect-www.redirectregex.permanent=true"

volumes:
  mariadb-data:
  media-uploads:

networks:
  cinebase-net:
    driver: bridge
  traefik-net:
    external: true
COMPOSE

echo "   docker-compose.yml generato."

# ── 3. Avvio stack ──────────────────────────────────────────────────────────
cd "$CINEBASE_DIR"

# Se già in esecuzione, pull e restart
if [ -f "$CINEBASE_DIR/docker-compose.yml" ]; then
  RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^cinebase-web$' || true)
  if [ "$RUNNING" -gt 0 ]; then
    echo ">> CineBase già in esecuzione. Pull e restart..."
    docker compose pull
    docker compose up -d --remove-orphans
    echo ""
    echo "=== CineBase aggiornato ==="
    echo "  Frontend: https://www.cinebase.it"
    echo "  API:      https://api.cinebase.it"
    exit 0
  fi
fi

echo ">> Primo avvio CineBase (incluso seeding database)..."
echo "   Il seeder popola il database con 80+ film, 20 cinema e ~9000 show."
echo "   Attendi qualche minuto..."

docker compose up -d

echo ""
echo "=== CineBase avviato con successo ==="
echo ""
echo "  Frontend: https://www.cinebase.it"
echo "  API:      https://api.cinebase.it"
echo "  Redirect: cinebase.it → https://www.cinebase.it (301)"
echo ""
echo "  Database:  mariadb:10.11 (container cinebase-mariadb)"
echo "  SMTP:      Aruba (smtps.aruba.it:465)"
echo ""
echo "Prossimo passo: verifica che il DNS punti a 129.152.30.86:"
echo "  www.cinebase.it  A  129.152.30.86"
echo "  api.cinebase.it  A  129.152.30.86"
echo "  cinebase.it       A  129.152.30.86"
echo ""
echo "Per i deploy successivi, il workflow Forgejo CI/CD (.forgejo/workflows/deploy.yml)"
echo "builda le immagini e fa docker compose up -d automaticamente a ogni push su main."
