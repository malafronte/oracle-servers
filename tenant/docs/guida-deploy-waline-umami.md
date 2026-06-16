# Guida deploy Waline + Umami su OCI ARM64

> Deploy di Waline (sistema commenti) e Umami (analytics) con PostgreSQL condiviso, dietro Traefik, su server OCI Always Free ARM64.

**Server**: `<NOME_SERVER>` (ARM Ampere A1, Ubuntu 24.04)
**Script**: `11-setup-analytics.sh` in `tenant/servers/s1/scripts/`

---

## 1. Panoramica

Lo script `11-setup-analytics.sh` crea un'isola Docker Compose `~/docker/analytics/` che contiene:

- **PostgreSQL 16** — database condiviso con due database: `waline` e `umami`
- **Waline** — sistema commenti + contatore visite per siti statici
- **Umami** — web analytics privacy-friendly (senza cookie)

Tutti i servizi sono raggiungibili via HTTPS grazie a Traefik, che gestisce automaticamente i certificati Let's Encrypt.

### Dominio infrastrutturale vs dominio gestito

Il server ha un **dominio infrastrutturale** (es. `<DOMINIO>`) usato per i servizi di sistema: Traefik, Portainer, Forgejo, Netdata. L'isola analytics può servire un **dominio diverso** (es. `<SITO_WEB>`) — tipicamente il dominio del sito statico ospitato altrove (GitHub Pages, Netlify, ecc.).

| Tipo | Esempio | Uso |
|---|---|---|
| Dominio infrastrutturale | `<DOMINIO>` | `traefik.<DOMINIO>`, `git.<DOMINIO>` |
| Dominio gestito (sito) | `<SITO_WEB>` | `comments.<SITO_WEB>`, `analytics.<SITO_WEB>` |

I record DNS per `comments.<SITO_WEB>` e `analytics.<SITO_WEB>` devono puntare all'IP del server OCI (record A), **non** al provider che ospita il sito.

---

## 2. Architettura

```
comments.<SITO_WEB>     analytics.<SITO_WEB>
        │                       │
        ▼                       ▼
    Traefik (esistente, traefik-net, porta 443)
        │  entrypoints: websecure
        │  tls: letsencrypt
        │                       │
        ▼                       ▼
     waline                    umami
     porta 8360                porta 3000
        │                       │
        └──────────┬────────────┘
                   │
              postgres (container dedicato, porta 5432)
              ├── db: waline
              └── db: umami
```

**Reti Docker:**
- `internal` (bridge): comunicazione tra postgres, waline e umami. PostgreSQL non è esposto all'esterno.
- `traefik-net` (external): solo waline e umami. Traefik vi accede per il routing HTTPS.

---

## 3. Cosa fa lo script

### 3.1 Creazione file

Eseguendo `bash 11-setup-analytics.sh` sul server, lo script crea nella directory `~/docker/analytics/`:

| File | Contenuto |
|---|---|
| `.env` | Variabili d'ambiente con password generate automaticamente |
| `init-db.sql` | Script SQL per creare i database `waline` e `umami` |
| `waline.pgsql` | Schema tabelle PostgreSQL per Waline (importato automaticamente) |
| `docker-compose.yml` | Definizione dei 3 servizi con label Traefik |

### 3.2 Generazione idempotente delle password

Lo script è **idempotente**: può essere eseguito più volte senza perdere dati o configurazioni.

- Se `.env` **non esiste**, lo script lo crea e genera 3 segreti casuali con `openssl rand`:
  - `POSTGRES_PASSWORD` (base64, 24 caratteri)
  - `UMAMI_ADMIN_PASSWORD` (base64, 16 caratteri)
  - `APP_SECRET` (hex, 64 caratteri) — secret per sessioni Umami
- Se `.env` **esiste già**, lo script preserva i valori esistenti e non li sovrascrive.
- Se i container sono già in esecuzione, esegue `docker compose pull && docker compose up -d` (aggiornamento).

### 3.3 Variabili d'ambiente

Lo script imposta queste variabili nel file `~/docker/analytics/.env`:

| Variabile | Default | Descrizione |
|---|---|---|
| `SITE_DOMAIN` | `<SITO_WEB>` | Dominio del sito servito (es. per CORS) |
| `POSTGRES_USER` | `analytics` | Utente PostgreSQL |
| `POSTGRES_PASSWORD` | *generata* | Password PostgreSQL |
| `POSTGRES_DB` | `analytics` | Database PostgreSQL predefinito |
| `WALINE_DOMAIN` | `comments.<SITO_WEB>` | Dominio per Waline |
| `WALINE_DB_NAME` | `waline` | Nome database Waline |
| `SITE_NAME` | `<SITO_WEB>` | Nome del sito (Waline) |
| `SITE_URL` | `https://<SITO_WEB>` | URL completo del sito (Waline) |
| `AUTHOR_EMAIL` | `admin@<SITO_WEB>` | Email amministratore Waline |
| `WALINE_LANG` | `it-IT` | Lingua interfaccia Waline |
| `ALLOW_REGISTER` | `true` | Registrazione utenti aperta |
| `COMMENT_RATE_LIMIT` | `60` | Secondi tra un commento e l'altro (stesso IP) |
| `UMAMI_DOMAIN` | `analytics.<SITO_WEB>` | Dominio per Umami |
| `APP_SECRET` | *generato* | Secret per hashing sessioni Umami |
| `TZ` | `Europe/Rome` | Timezone |

> **Nota**: Umami crea un account admin di default con credenziali `admin` / `umami`. Cambia la password al primo accesso da **Settings → Profile**. Le variabili `UMAMI_ADMIN_USER` e `UMAMI_ADMIN_PASSWORD` non esistono nella documentazione ufficiale Umami.

> **Nota**: se il `.env` esiste già, puoi modificare manualmente qualsiasi variabile (es. `AUTHOR_EMAIL`, `WALINE_LANG`) e rieseguire lo script — le modifiche vengono preservate.

---

## 4. DNS

Prima di eseguire lo script, configura due record A nel provider DNS:

| Host | Type | Value |
|---|---|---|
| `comments` | A | `<IP_SERVER>` |
| `analytics` | A | `<IP_SERVER>` |

**Perché record A e non CNAME?** Se `<SITO_WEB>` è ospitato su GitHub Pages (o altro provider), un CNAME verso `<SITO_WEB>` risolverebbe agli IP di quel provider, non al server OCI. I record A puntano direttamente al VPS.

Verifica:

```bash
nslookup comments.<SITO_WEB>
nslookup analytics.<SITO_WEB>
# Entrambi devono restituire <IP_SERVER>
```

---

## 5. Esecuzione

### 5.1 Prerequisiti

- Traefik attivo con rete `traefik-net` (script `04-setup-traefik.sh`)
- DNS configurato (§4)

### 5.2 Comandi

```bash
# Da locale: copia lo script sul server
scp -i <CHIAVE_SSH> tenant/servers/s1/scripts/11-setup-analytics.sh <UTENTE>@<IP_SERVER>:~/scripts/

# Sul server: esegui lo script
ssh -i <CHIAVE_SSH> <UTENTE>@<IP_SERVER>
cd ~/scripts
bash 11-setup-analytics.sh
```

Lo script mostra a video le password generate (oscurate) e le credenziali Umami.

### 5.3 Verifica

```bash
# Stato container (tutti e 3 devono essere "healthy")
cd ~/docker/analytics && docker compose ps

# I container sono registrati in Traefik?
curl -s -u <TRAEFIK_USER>:<TRAEFIK_PASSWORD> https://traefik.<DOMINIO>/api/http/routers | jq '.[] | select(.rule | contains("comments") or contains("analytics")) | {name, rule, status}'

# I domini rispondono?
curl -sI https://comments.<SITO_WEB>/ui/
curl -sI https://analytics.<SITO_WEB>/
# Entrambi devono restituire HTTP 200
```

---

## 6. Configurazione post-deploy

### 6.1 Waline — registrazione admin

1. Vai su `https://comments.<SITO_WEB>/ui/register`
2. Registrati con email e password
3. Il primo utente è automaticamente amministratore
4. Accedi a `https://comments.<SITO_WEB>/ui/` per il pannello di controllo

### 6.2 Umami — primo accesso

1. Vai su `https://analytics.<SITO_WEB>/`
2. Login con credenziali di default: **`admin`** / **`umami`**
3. **Cambia subito la password**: Settings → Profile → Change password
4. Clicca **Add website**: Name e Domain = `<SITO_WEB>`
5. Copia il **tracking code** generato (tag `<script>`)
6. Incollalo nel `<head>` del sito (es. `BaseHead.astro` per Astro)

### 6.3 Integrazione con sito statico

**Waline** (in `site.config.ts` o equivalente):

```ts
waline: {
  enable: true,
  server: 'https://comments.<SITO_WEB>',
  pageview: true,
  comment: true,
  lang: 'it-IT'
}
```

**Umami** (in `<head>` del layout base):

```html
<script defer src="https://analytics.<SITO_WEB>/script.js" data-website-id="IL-TUO-WEBSITE-ID"></script>
```

---

## 7. Manutenzione

```bash
cd ~/docker/analytics

# Stato
docker compose ps

# Log
docker compose logs -f --tail=50

# Aggiornare tutte le immagini
docker compose pull
docker compose up -d

# Riavviare un singolo servizio
docker compose restart waline
docker compose restart umami
```

---

## 8. Backup

### 8.1 Backup manuale PostgreSQL

```bash
# Backup di entrambi i database
docker exec analytics-postgres pg_dumpall -U analytics > ~/backups/analytics-$(date +%Y%m%d-%H%M).sql

# O backup separati
docker exec analytics-postgres pg_dump -U analytics waline > ~/backups/waline-$(date +%Y%m%d).sql
docker exec analytics-postgres pg_dump -U analytics umami > ~/backups/umami-$(date +%Y%m%d).sql
```

### 8.2 Ripristino

```bash
# Ripristina tutto
docker exec -i analytics-postgres psql -U analytics < ~/backups/analytics-YYYYMMDD.sql

# O un database singolo
docker exec -i analytics-postgres psql -U analytics -d waline < ~/backups/waline-YYYYMMDD.sql
```

### 8.3 Integrazione con backup OCI

Per includere l'isola analytics nel backup notturno su OCI Object Storage (script `10-setup-backup.sh`), aggiungi a `~/docker/backup.sh`:

```bash
docker exec analytics-postgres pg_dumpall -U analytics > /tmp/analytics-$(date +%Y%m%d).sql

oci os object put \
  --bucket-name <BUCKET_NAME> \
  --file /tmp/analytics-$(date +%Y%m%d).sql \
  --name "analytics/$(date +%Y%m%d).sql" \
  --auth instance_principal \
  --force

rm /tmp/analytics-$(date +%Y%m%d).sql
```

---

## 9. Troubleshooting

### "502 Bad Gateway"

I container non sono sulla rete `traefik-net` o non sono healthy. Verifica:

```bash
docker network inspect traefik-net | grep -E "waline|umami"
docker compose ps  # tutti devono essere "healthy"
```

### "Waline non si connette a PostgreSQL"

```bash
docker exec analytics-postgres psql -U analytics -c "\l" | grep waline
# Se non esiste, crealo:
docker exec analytics-postgres psql -U analytics -c "CREATE DATABASE waline;"
docker compose restart waline
```

### "500: relation wl_users does not exist"

Waline **non crea automaticamente le tabelle** per PostgreSQL (né per MySQL). Lo schema va importato manualmente. Lo script `11-setup-analytics.sh` lo fa in automatico dopo l'avvio di PostgreSQL. Se l'import non è avvenuto:

```bash
docker exec -i analytics-postgres psql -U analytics -d waline < ~/docker/analytics/waline.pgsql
docker compose restart waline
```

### "ERR_CERT_AUTHORITY_INVALID" nel browser

Il certificato Let's Encrypt non è ancora stato generato. Traefik lo crea alla prima richiesta HTTPS (30-60 secondi). Se persiste:

```bash
# Verifica che Traefik abbia i router
docker logs traefik --tail 20 | grep -E "waline|umami"
# Forza rinnovo
docker restart traefik
```

### Container unhealthy dopo il deploy

L'immagine Waline non include `wget`. Lo script usa un healthcheck basato su Node.js (`CMD-SHELL` con `node -e`). L'immagine Umami include `wget` ma richiede `127.0.0.1` invece di `localhost` (evita risoluzione IPv6 `::1`). Entrambi i workaround sono già applicati nello script.

### "403 Forbidden" durante registrazione o chiamate API Waline

`SECURE_DOMAINS` deve contenere i domini **senza** protocollo (es. `<SITO_WEB>,comments.<SITO_WEB>`). L'uso di `https://` nel valore causa il rifiuto delle richieste. Lo script ora imposta correttamente `SECURE_DOMAINS=${SITE_DOMAIN},${WALINE_DOMAIN}`.

---

## 10. Riepilogo

| Step | Dove | Azione |
|---|---|---|
| 1 | DNS | Record A per `comments` e `analytics` → `<IP_SERVER>` |
| 2 | Server | `bash 11-setup-analytics.sh` |
| 3 | Browser | Waline: registrati admin su `/ui/register` |
| 4 | Browser | Umami: login admin, aggiungi sito, copia tracking code |
| 5 | Sito | Integra Waline in `site.config.ts` |
| 6 | Sito | Integra Umami in `<head>` |
| 7 | Server | (Opzionale) Backup PostgreSQL su OCI Object Storage |
