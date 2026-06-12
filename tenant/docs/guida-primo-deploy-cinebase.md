# Guida primo deployment CineBase su OCI ARM64

**Server**: <NOME_SERVER> (ARM Ampere A1, Ubuntu 24.04)
**Data**: Giugno 2026
**Contesto**: deployment manuale eseguito PRIMA di attivare il CI/CD automatico

---

## 1. Panoramica

Il primo deployment di CineBase ha richiesto 5 fasi:

1. Preparazione file di setup nel repository `oracle-servers`
2. Push iniziale su Forgejo e configurazione secrets
3. Merge dei file `.env` sul server
4. Build manuale delle 3 immagini
5. Avvio stack e fix post-deploy

---

## 2. File creati per il setup

### 2.1 Script `09-setup-cinebase.sh`

In `oracle-servers/tenant/servers/s1/scripts/09-setup-cinebase.sh`. Questo script:

- Crea la directory `~/docker/cinebase/`
- Genera `docker-compose.yml` con tutti i servizi CineBase
- Copia `.env.example` se `.env` non esiste
- Avvia lo stack (MariaDB, FilmAPI, Seeder, CineBase.Web)

### 2.2 Template `.env.example`

In `oracle-servers/tenant/servers/s1/cinebase/.env.example`. Contiene tutte le variabili d'ambiente pronte per la produzione con URL corretti:

```env
FRONTEND_PUBLIC_BASE_URL=https://www.<DOMINIO_APP>
CORS_ALLOWED_ORIGINS=https://www.<DOMINIO_APP>
API_BASE_URL=https://api.<DOMINIO_APP>/api
MEDIA_BASE_URL=https://api.<DOMINIO_APP>/media
ASPNETCORE_ENVIRONMENT=Production
SMTP_HOST=smtps.aruba.it
SMTP_PORT=465
```

### 2.3 DNS (già configurato)

```text
www.<DOMINIO_APP>   A   <IP_SERVER>
api.<DOMINIO_APP>   A   <IP_SERVER>
<DOMINIO_APP>       A   <IP_SERVER>
```

---

## 3. Merge dei file `.env`

CineBase ha due file di configurazione:

| File | Contenuto | Nel repo CineBase |
|---|---|---|
| `.env.docker.example` | Tutte le variabili con default (compresi URL localhost) | Versionato |
| `.env.docker` | Solo i **segreti** (SMTP password, Stripe, OAuth, TMDB) | Gitignorato |

Il `.env.docker.example` ha URL di sviluppo (`http://localhost:5000`), mentre il nostro `.env.example` ha gli URL di produzione (`https://www.<DOMINIO_APP>`).

### Procedura merge

```bash
# 1. Copia il template production (ha già gli URL corretti per *.<DOMINIO_APP>)
scp -i ${S1_SSH_KEY} tenant/servers/s1/cinebase/.env.example ${S1_SSH_USER}@${S1_IP}:/tmp/.env.base

# 2. Copia i segreti da .env.docker (password reali)
scp -i ${S1_SSH_KEY} ~/source/repos/5IA/CineBase/.env.docker ${S1_SSH_USER}@${S1_IP}:/tmp/.env.secrets

# 3. Merge sul server: .env.docker sovrascrive le variabili corrispondenti in .env.base
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP} '
  cp /tmp/.env.base ~/docker/cinebase/.env
  while IFS="=" read -r line; do
    line=$(echo "$line" | tr -d "\r")
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key=$(echo "$key" | xargs)
    [[ -z "$key" ]] && continue
    sed -i "s|^${key}=.*|${key}=${val}|" ~/docker/cinebase/.env
  done < /tmp/.env.secrets
  rm /tmp/.env.base /tmp/.env.secrets
'
```

### Modifiche manuali post-merge

Alcune variabili **non** sono in `.env.docker` (password, JWT, admin). Vanno impostate manualmente:

```bash
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP}
nano ~/docker/cinebase/.env
```

Valori da personalizzare:
```env
MYSQL_ROOT_PASSWORD=<password-senza-caratteri-speciali>
JWT_SECRET=<stringa-lunga-casuale>
ADMIN_SEED_EMAIL=admin@<DOMINIO_APP>
ADMIN_SEED_PASSWORD=<password-admin>
```

> **⚠️ Attenzione al `$` nella password**: Docker Compose interpreta `$LK` come variabile `${LK}`. Se la password contiene `$`, va escapato come `$$` o rimosso del tutto. L'errore appare come warning `The "LK" variable is not set`.

---

## 4. Build manuale delle immagini

Il CI/CD non era ancora attivo, quindi le immagini vanno buildate a mano la prima volta.

### 4.1 Login al registry

```bash
docker login registry.<DOMINIO> -u <UTENTE>
# Inserire la password quando richiesto
```

> **Nota**: la password contiene caratteri speciali (`è`). Usare `-u` e inserire interattivamente funziona. Usare `-p` dalla shell fallisce per problemi di encoding.

### 4.2 Clonare il repo e buildare

```bash
cd /tmp
git clone https://git.<DOMINIO>/<UTENTE>/cinebase.git
cd cinebase

# Builda le 3 immagini (ARM64 nativo)
docker build -t registry.<DOMINIO>/cinebase/filmapi:latest -f backend/FilmAPI/Dockerfile .
docker build -t registry.<DOMINIO>/cinebase/seeder:latest -f backend/scripts/FilmApiSeeder/Dockerfile .
docker build -t registry.<DOMINIO>/cinebase/web:latest -f frontend/CineBase.Web/Dockerfile .

# Push sul registry
docker push registry.<DOMINIO>/cinebase/filmapi:latest
docker push registry.<DOMINIO>/cinebase/seeder:latest
docker push registry.<DOMINIO>/cinebase/web:latest
```

### 4.3 Tempi di build

- `filmapi` (backend .NET 10): ~2-3 minuti
- `seeder` (job one-shot): ~2-3 minuti
- `cinebase-web` (frontend .NET 10 + Tailwind CSS): ~3-4 minuti
- Totale: ~7-10 minuti su ARM64 con 4 OCPU

---

## 5. Avvio stack

### 5.1 Esecuzione script 09

```bash
scp -i ${S1_SSH_KEY} tenant/servers/s1/scripts/09-setup-cinebase.sh ${S1_SSH_USER}@${S1_IP}:~/scripts/
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP} "bash ~/scripts/09-setup-cinebase.sh"
```

### 5.2 Sequenza di avvio

```
1. mariadb    → attende healthy (mariadb-admin ping)
2. filmapi    → attende mariadb healthy + self-bootstrap (migrazioni + seed admin)
3. seeder     → attende mariadb + filmapi healthy → popola 80 film, 20 cinema, ~9000 show
4. cinebase-web → attende filmapi healthy + seeder completato → frontend online
```

Il seeder è idempotente (usa UPSERT, non INSERT). Se rieseguito, non duplica dati.

### 5.3 Output atteso

```
=== CineBase avviato con successo ===

  Frontend: https://www.<DOMINIO_APP>
  API:      https://api.<DOMINIO_APP>
  Redirect: <DOMINIO_APP> → https://www.<DOMINIO_APP> (301)

  Database:  mariadb:10.11 (container cinebase-mariadb)
  SMTP:      Aruba (smtps.aruba.it:465)
```

---

## 6. Verifica post-deploy

### 6.1 Containers

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep cinebase
```

Output atteso:
```
cinebase-web       Up (healthy)
cinebase-filmapi   Up (healthy)
cinebase-mariadb   Up (healthy)
```

### 6.2 Routing HTTP

```bash
curl -s -o /dev/null -w '%{http_code}' https://www.<DOMINIO_APP>
# Atteso: 200

curl -s -o /dev/null -w '%{http_code}' https://api.<DOMINIO_APP>/api/health/ready
# Atteso: 200

curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://<DOMINIO_APP>
# Atteso: 301 https://www.<DOMINIO_APP>/
```

### 6.3 Immagini nel registry

```bash
curl -s -u <utente>:<password> https://registry.<DOMINIO>/v2/_catalog
```

Output atteso:
```json
{"repositories":["cinebase/filmapi","cinebase/seeder","cinebase/web", ...]}
```

---

## 7. Fix applicati dopo il primo avvio

### 7.1 Warning `LK` in Docker Compose

**Errore**: `WARN[0000] The "LK" variable is not set. Defaulting to a blank string.`

**Causa**: `MYSQL_ROOT_PASSWORD=<PASSWORD_CON_$>` — Docker Compose interpreta `$LK` come variabile.

**Fix**: rimuovere il `$` dalla password:
```bash
sed -i "s/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=<MYSQL_ROOT_PASSWORD_SENZA_DOLLARO>/" ~/docker/cinebase/.env
```

### 7.2 Ricostruzione volume MariaDB

Dopo il cambio password, MariaDB aveva già inizializzato il volume con la password vecchia:

```bash
cd ~/docker/cinebase
docker compose down -v mariadb
docker compose up -d mariadb filmapi seeder cinebase-web
```

> **⚠️** `docker compose down -v` **cancella** il database. Dopo il riavvio, il seeder ripopola automaticamente tutti i dati.

### 7.3 Variabili OAuth e disclaimer

Aggiunte manualmente in `.env` dopo il primo avvio:
```env
GOOGLE_OAUTH_REDIRECT_URI=https://api.<DOMINIO_APP>/auth/external/google/callback
MICROSOFT_OAUTH_REDIRECT_URI=https://api.<DOMINIO_APP>/auth/external/microsoft/callback
SHOW_DISCLAIMER=true
```

> **Nota**: queste variabili sono a runtime, non richiedono rebuild delle immagini. Basta `docker compose up -d`.

---

## 8. Riepilogo comandi (primo deployment completo)

```bash
# === DAL PC LOCALE ===

# 1. Copia i file di setup
scp -i ${S1_SSH_KEY} tenant/servers/s1/scripts/09-setup-cinebase.sh ${S1_SSH_USER}@${S1_IP}:~/scripts/

# 2. Copia i file .env e fa merge
scp -i ${S1_SSH_KEY} tenant/servers/s1/cinebase/.env.example ${S1_SSH_USER}@${S1_IP}:/tmp/.env.base
scp -i ${S1_SSH_KEY} ~/source/repos/5IA/CineBase/.env.docker ${S1_SSH_USER}@${S1_IP}:/tmp/.env.secrets
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP} '
  cp /tmp/.env.base ~/docker/cinebase/.env
  while IFS="=" read -r line; do
    line=$(echo "$line" | tr -d "\r")
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key=$(echo "$key" | xargs)
    [[ -z "$key" ]] && continue
    sed -i "s|^${key}=.*|${key}=${val}|" ~/docker/cinebase/.env
  done < /tmp/.env.secrets
  rm /tmp/.env.base /tmp/.env.secrets
'

# === SUL SERVER ===

# 3. Modifica manuale .env (password, JWT, admin)
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP}
# nano ~/docker/cinebase/.env  → imposta MYSQL_ROOT_PASSWORD, JWT_SECRET, ADMIN_SEED_*

# 4. Build immagini (primo deploy, prima volta)
docker login registry.<DOMINIO> -u <UTENTE>
cd /tmp && git clone https://git.<DOMINIO>/<UTENTE>/cinebase.git && cd cinebase
docker build -t registry.<DOMINIO>/cinebase/filmapi:latest -f backend/FilmAPI/Dockerfile .
docker build -t registry.<DOMINIO>/cinebase/seeder:latest -f backend/scripts/FilmApiSeeder/Dockerfile .
docker build -t registry.<DOMINIO>/cinebase/web:latest -f frontend/CineBase.Web/Dockerfile .
docker push registry.<DOMINIO>/cinebase/filmapi:latest
docker push registry.<DOMINIO>/cinebase/seeder:latest
docker push registry.<DOMINIO>/cinebase/web:latest

# 5. Avvia stack
bash ~/scripts/09-setup-cinebase.sh

# 6. Verifica
docker ps | grep cinebase
curl -s -o /dev/null -w '%{http_code}' https://www.<DOMINIO_APP>
```

---

## 9. Dopo il primo deploy

Da questo punto in poi, i deploy successivi sono gestiti dal **CI/CD** (`.forgejo/workflows/deploy.yml`). Per la guida completa su CI/CD, vedi **[Guida CI/CD Forgejo Actions](guida-cicd-forgejo-actions.md)**.

Il workflow fa automaticamente:
1. Build delle 3 immagini
2. Push su registry
3. Deploy via SSH sul server
