# Esempio pratico: due progetti multi-container con Traefik e Portainer

Scenario reale con due progetti indipendenti sullo stesso server, ciascuno con il proprio `docker-compose.yml`.

---

## Progetto 1 – CineBase (piattaforma ticketing cinema)

Architettura: 4 container (frontend, API, database, seeder one-shot).

```yaml
# /home/ubuntu/docker/cinebase/docker-compose.yml

services:
  # ── Frontend: pagine statiche + JS, esposto via Traefik ──
  cinebase-web:
    image: ghcr.io/<UTENTE>/cinebase-web:latest
    container_name: cinebase-web
    restart: unless-stopped
    networks:
      - internal
      - traefik-net                    # ← aggancio a Traefik
    environment:
      - API_BASE_URL=https://api.cinebase.miodominio.com
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.cinebase-web.rule=Host(`cinebase.miodominio.com`)"
      - "traefik.http.routers.cinebase-web.entrypoints=websecure"
      - "traefik.http.routers.cinebase-web.tls.certresolver=letsencrypt"
      - "traefik.http.services.cinebase-web.loadbalancer.server.port=8080"

  # ── API backend: CORS + JWT + Stripe, esposto su sottodominio separato ──
  cinebase-api:
    image: ghcr.io/<UTENTE>/cinebase-api:latest
    container_name: cinebase-api
    restart: unless-stopped
    depends_on:
      cinebase-db:
        condition: service_healthy
    networks:
      - internal
      - traefik-net                    # ← aggancio a Traefik
    environment:
      - ConnectionStrings__Default=Server=cinebase-db;Database=cinebase;User=root;Password=DbP4ssw0rd!
      - Jwt__SecretKey=il-tuo-secret-jwt-lungo-almeno-256-bit
      - Stripe__SecretKey=sk_test_...
      - CORS__AllowedOrigins=https://cinebase.miodominio.com
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.cinebase-api.rule=Host(`api.cinebase.miodominio.com`)"
      - "traefik.http.routers.cinebase-api.entrypoints=websecure"
      - "traefik.http.routers.cinebase-api.tls.certresolver=letsencrypt"
      - "traefik.http.services.cinebase-api.loadbalancer.server.port=8080"
      # Rate limiting sull'API (100 richieste/min in media)
      - "traefik.http.routers.cinebase-api.middlewares=cinebase-ratelimit"
      - "traefik.http.middlewares.cinebase-ratelimit.ratelimit.average=100"
      - "traefik.http.middlewares.cinebase-ratelimit.ratelimit.period=1m"
      - "traefik.http.middlewares.cinebase-ratelimit.ratelimit.burst=30"

  # ── Database: MariaDB, solo rete interna, mai esposto ──
  cinebase-db:
    image: mariadb:10.11
    container_name: cinebase-db
    restart: unless-stopped
    networks:
      - internal                      # ← solo rete interna, NO Traefik
    environment:
      - MARIADB_ROOT_PASSWORD=DbP4ssw0rd!
    volumes:
      - ./mariadb-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  # ── Seeder: popola il DB con dati iniziali, gira una volta sola ──
  cinebase-seeder:
    image: ghcr.io/<UTENTE>/cinebase-seeder:latest
    container_name: cinebase-seeder
    networks:
      - internal                      # ← solo rete interna
    depends_on:
      cinebase-db:
        condition: service_healthy
    environment:
      - ConnectionStrings__Default=Server=cinebase-db;Database=cinebase;User=root;Password=DbP4ssw0rd!
    # Nessuna label Traefik: non è un servizio HTTP

# ── Reti ──
networks:
  internal:                           # rete isolata interna al progetto
    driver: bridge
  traefik-net:                        # rete condivisa per l'accesso HTTP
    external: true
```

---

## Progetto 2 – Blog Personale (inventato, 3 container)

Un blog con frontend Hugo servito da Nginx, API headless CMS (Strapi), e PostgreSQL.

```yaml
# /home/ubuntu/docker/blog-personale/docker-compose.yml

services:
  # ── Frontend: sito statico servito da Nginx ──
  blog-web:
    image: nginx:alpine
    container_name: blog-web
    restart: unless-stopped
    networks:
      - internal
      - traefik-net
    volumes:
      - ./public:/usr/share/nginx/html:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.blog-web.rule=Host(`blog.miodominio.com`)"
      - "traefik.http.routers.blog-web.entrypoints=websecure"
      - "traefik.http.routers.blog-web.tls.certresolver=letsencrypt"
      - "traefik.http.services.blog-web.loadbalancer.server.port=80"

  # ── API CMS: Strapi headless, accessibile da frontend e admin ──
  blog-strapi:
    image: strapi/strapi:latest
    container_name: blog-strapi
    restart: unless-stopped
    depends_on:
      blog-db:
        condition: service_healthy
    networks:
      - internal
      - traefik-net
    environment:
      - DATABASE_CLIENT=postgres
      - DATABASE_HOST=blog-db
      - DATABASE_NAME=blog
      - DATABASE_USERNAME=blog
      - DATABASE_PASSWORD=BlogP4ss!
      - APP_KEYS=chiave1,chiave2,chiave3,chiave4
    volumes:
      - ./uploads:/srv/app/public/uploads
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.blog-strapi.rule=Host(`admin.blog.miodominio.com`)"
      - "traefik.http.routers.blog-strapi.entrypoints=websecure"
      - "traefik.http.routers.blog-strapi.tls.certresolver=letsencrypt"
      - "traefik.http.services.blog-strapi.loadbalancer.server.port=1337"
      # Admin panel protetto da basic auth
      - "traefik.http.routers.blog-strapi.middlewares=blog-admin-auth"
      - "traefik.http.middlewares.blog-admin-auth.basicauth.users=admin:$$2y$$05$$ZVxH..."

  # ── Database: PostgreSQL, solo rete interna ──
  blog-db:
    image: postgres:16-alpine
    container_name: blog-db
    restart: unless-stopped
    networks:
      - internal
    environment:
      - POSTGRES_USER=blog
      - POSTGRES_PASSWORD=BlogP4ss!
      - POSTGRES_DB=blog
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U blog"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  internal:
    driver: bridge
  traefik-net:
    external: true
```

---

## Cosa succede quando avvii entrambi

```bash
cd ~/docker/cinebase && docker compose up -d
cd ~/docker/blog-personale && docker compose up -d
```

### Vista da terminale

```bash
$ docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Networks}}\t{{.Status}}"

NAMES              IMAGE                             NETWORKS                    STATUS
traefik            traefik:v3.6                      traefik-net                 Up 2 hours
portainer          portainer/portainer-ce:2.39.3       traefik-net                 Up 2 hours
cinebase-web       cinebase-web:latest               cinebase_internal,traefik-net  Up 10 min
cinebase-api       cinebase-api:latest               cinebase_internal,traefik-net  Up 10 min
cinebase-db        mariadb:10.11                     cinebase_internal           Up 10 min
blog-web           nginx:alpine                      blog_internal,traefik-net   Up 5 min
blog-strapi        strapi/strapi:latest              blog_internal,traefik-net   Up 5 min
blog-db            postgres:16-alpine                blog_internal               Up 5 min
```

> Nota: le reti `internal` hanno prefisso diverso (`cinebase_internal`, `blog_internal`) perché Docker Compose le namespace col nome della directory. Isolamento garantito.

### Tabella domini e container

| Dominio | Container | Porta |
|---------|-----------|-------|
| `cinebase.miodominio.com` | cinebase-web | 8080 |
| `api.cinebase.miodominio.com` | cinebase-api | 8080 |
| `blog.miodominio.com` | blog-web | 80 |
| `admin.blog.miodominio.com` | blog-strapi | 1337 |

Tutti con HTTPS e certificato Let's Encrypt generato automaticamente.

### DNS richiesto

```
cinebase.miodominio.com     A   129.152.30.86
api.cinebase.miodominio.com A   129.152.30.86
blog.miodominio.com         A   129.152.30.86
admin.blog.miodominio.com   A   129.152.30.86
```

---

## Come appare in Portainer

Dopo aver avviato tutto, apri `https://portainer.miodominio.com`:

### Dashboard Home
Vedi **8 container** in esecuzione (Traefik, Portainer, 4 CineBase, 3 Blog). Il grafico CPU/RAM mostra il consumo aggregato.

### Containers
Lista completa con stato (running), stack di appartenenza se deployati via Stacks, e reti connesse. Cliccando su `cinebase-api`:

- **Logs**: vedi le richieste HTTP in arrivo con IP, path, status code
- **Stats**: CPU, RAM, rete del solo backend CineBase
- **Console**: shell dentro il container per debug (es. `curl cinebase-db:3306` per testare connettività DB)
- **Inspect**: tutte le variabili d'ambiente, label Traefik, volumi montati

### Networks
Due reti `traefik-net` (condivisa, con 6 container attaccati), più `cinebase_internal` e `blog_internal` (isolate). Ogni rete interna ha solo i container del suo progetto — impossibile che blog-web comunichi col database di CineBase.

### Stacks (se deployato via Portainer)
Se hai incollato i docker-compose via Portainer Stacks, vedi due stack: `cinebase` e `blog-personale`. Puoi:

- **Stop** / **Start** l'intero stack con un click
- **Edit** il docker-compose e **Re-deploy**
- Vedere lo storico dei deploy

### Volumes
Vedi `cinebase_mariadb-data` (~200 MB) e `blog-personale_pgdata` (~50 MB). Volumi namespace e isolati, nessun rischio di sovrascrittura.

---

## Confronto: prima e dopo Traefik

| | Senza Traefik | Con Traefik |
|---|---|---|
| Porte esposte su host | `:3000`, `:8080`, `:1337`, `:80`... conflitti continui | Solo `:80` e `:443` su Traefik |
| HTTPS | Da configurare manualmente per ogni app | Automatico, Let's Encrypt |
| Nuovo progetto | Scegli una porta libera, configura Nginx a mano | 5 label nel docker-compose, avvii e funziona |
| Due app sulla stessa porta | Impossibile | Nessun problema |
| Certificati | Rinnovo manuale | Rinnovo automatico |

---

## Comandi per gestire i due progetti

```bash
# Avviare/fermare solo CineBase (il blog continua a funzionare)
cd ~/docker/cinebase && docker compose down
cd ~/docker/cinebase && docker compose up -d

# Aggiornare solo il blog
cd ~/docker/blog-personale && docker compose pull && docker compose up -d

# Log di un container specifico
docker logs -f --tail 100 cinebase-api
docker logs -f --tail 100 blog-strapi

# Entrare nella shell di un container
docker exec -it cinebase-db mariadb -u root -p
docker exec -it blog-db psql -U blog

# Verificare che i certificati siano stati generati
docker exec traefik ls -la /certificates/
```
