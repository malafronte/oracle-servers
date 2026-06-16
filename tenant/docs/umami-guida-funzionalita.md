# Umami — Guida alle funzionalità e configurazione

> Guida operativa per Umami in produzione su OCI ARM64 con Docker + PostgreSQL, dietro Traefik.

**Server**: `<NOME_SERVER>` (OCI ARM64 Ampere A1)  
**Dominio**: `analytics.<SITO_WEB>`  
**Directory**: `~/docker/analytics/`

---

## 1. Cosa è Umami

Umami è un sistema di web analytics open-source, privacy-friendly e privo di cookie persistenti. A differenza di Google Analytics:

- **Nessun cookie tracciante**: usa una sessione anonima temporanea
- **Nessun fingerprinting**: non identifica l'utente tra siti diversi
- **GDPR-compliant**: non richiede banner cookie
- **Self-hosted**: i dati restano sul tuo server PostgreSQL
- **Open-source**: codice pubblico su [GitHub](https://github.com/umami-software/umami)
- **Leggero**: script tracker ~2 KB

**Dati raccolti**: pageview, referrer, browser, OS, paese (tramite MaxMind GeoIP), lingua, dimensioni schermo, eventi custom.

**Dati NON raccolti**: IP (non memorizzato), cookie persistenti, fingerprint del dispositivo, dati personali.

---

## 2. Architettura

```
analytics.<SITO_WEB> (HTTPS)
        │
        ▼
    Traefik (certificato Let's Encrypt)
        │
        ▼
    umami (container Docker, Next.js app, porta 3000)
        │
        ▼
    PostgreSQL 16 (stesso host, database `umami`)
```

```
Browser visitatore
        │
        ▼ <script> tracker (~2 KB) caricato da analytics.<SITO_WEB>/script.js
        │
        ▼ POST /api/send  →  Umami  →  PostgreSQL
```

- La dashboard Umami è accessibile solo via `https://analytics.<SITO_WEB>`
- Lo script tracker è pubblico e viene caricato dal sito `<SITO_WEB>`
- I dati sono inviati via POST anonima al server Umami

---

## 3. Configurazione attuale

### 3.1 Variabili d'ambiente (in `~/docker/analytics/.env`)

| Variabile | Valore | Descrizione |
|---|---|---|
| `UMAMI_DOMAIN` | `analytics.<SITO_WEB>` | Dominio pubblico di Umami |
| `POSTGRES_USER` | `analytics` | Utente PostgreSQL (condiviso) |
| `POSTGRES_PASSWORD` | *(generata)* | Password PostgreSQL |
| `APP_SECRET` | *(generata, 64 hex)* | Secret per hashing token di sessione |
| `TZ` | `Europe/Rome` | Timezone |

### 3.2 Variabili Docker Compose (hardcodate nel servizio `umami`)

| Variabile | Valore | Descrizione |
|---|---|---|
| `DATABASE_URL` | `postgresql://analytics:...@postgres:5432/umami` | Stringa connessione PostgreSQL |
| `DATABASE_TYPE` | `postgresql` | Tipo database |
| `APP_SECRET` | `${APP_SECRET}` | Secret sessioni |

### 3.3 Script tracker (nel `<head>` del sito)

```html
<script defer src="https://analytics.<SITO_WEB>/script.js"
        data-website-id="TUO-WEBSITE-ID"></script>
```

Posizionato in `BaseHead.astro`, solo in produzione (`{prod && ...}`).

---

## 4. Dashboard e metriche

Accessibile da `https://analytics.<SITO_WEB>` con credenziali default `admin` / `umami`.

### 4.1 Metriche principali

| Metrica | Cosa misura |
|---|---|
| **Views** | Numero di pageview nel periodo |
| **Visitors** | Visitatori unici (per sessione) |
| **Bounce rate** | % visite con una sola pagina |
| **Avg visit time** | Tempo medio di permanenza |
| **Events** | Eventi custom tracciati |

### 4.2 Dati raccolti per ogni visita

| Dato | Esempio |
|---|---|
| Pagina | `/blog/maui-101/` |
| Referrer | `https://google.com` |
| Browser | Chrome 131, Firefox 134 |
| OS | Windows 11, macOS 15 |
| Paese | IT (Italia), US, DE |
| Lingua | `it-IT` |
| Schermo | `1920x1080` |
| Dispositivo | Desktop, Tablet, Mobile |

### 4.3 Sezioni della dashboard

| Sezione | Descrizione |
|---|---|
| **Realtime** | Visitatori attivi in questo momento |
| **Pages** | Pagine più visitate |
| **Referrers** | Siti di provenienza |
| **Browsers** | Browser usati |
| **OS** | Sistemi operativi |
| **Devices** | Desktop / Mobile / Tablet |
| **Countries** | Paesi di provenienza |
| **Events** | Eventi custom |
| **Sessions** | Sessioni con replay |
| **UTM** | Parametri campagna UTM |

---

## 5. Tracker configuration

### 5.1 Opzioni script tracker

Puoi aggiungere attributi `data-*` al tag `<script>` per personalizzare il comportamento:

| Attributo | Default | Descrizione |
|---|---|---|
| `data-website-id` | *(obbligatorio)* | ID del sito nella dashboard |
| `data-host-url` | automatico | URL alternativo per invio dati |
| `data-auto-track` | `true` | Tracciamento automatico pageview |
| `data-domains` | nessuno | Limita a domini specifici (es. `<SITO_WEB>,www.<SITO_WEB>`) |
| `data-exclude-search` | `false` | Escludi parametri query dall'URL |
| `data-do-not-track` | `false` | Rispetta impostazione DNT del browser |
| `data-performance` | `false` | Raccogli Core Web Vitals (LCP, FCP, CLS) |
| `data-tag` | nessuno | Tag per A/B testing |

### 5.2 Esempi di configurazione estesa

```html
<!-- Tracciamento completo con performance e DNT -->
<script defer src="https://analytics.<SITO_WEB>/script.js"
  data-website-id="TUO-ID"
  data-domains="<SITO_WEB>,www.<SITO_WEB>"
  data-do-not-track="true"
  data-performance="true"
  data-exclude-search="true">
</script>
```

---

## 6. Tracker functions (JavaScript API)

Sul tuo sito puoi chiamare `umami.track()` per eventi custom.

### 6.1 Pageview manuale

```js
// Traccia la pagina corrente
umami.track();

// Con payload custom
umami.track({ website: 'TUO-ID', url: '/custom-page', title: 'Titolo' });

// Modifica payload automatico
umami.track(props => ({ ...props, url: '/custom-page' }));
```

### 6.2 Eventi custom

```js
// Semplice
umami.track('signup-button');

// Con dati
umami.track('signup-button', { plan: 'newsletter', id: 123 });

// Con timestamp override
umami.track(props => ({ ...props, name: 'signup-button', timestamp: 1771523787 }));
```

### 6.3 Identificazione sessioni

```js
// Assegna ID alla sessione corrente
umami.identify('utente-univoco');

// Con dati aggiuntivi
umami.identify('utente-univoco', { name: 'Mario', email: '...' });

// Solo dati, senza ID
umami.identify({ role: 'premium' });
```

### 6.4 Limiti dati eventi

| Tipo | Limite |
|---|---|
| Numeri | Precisione max 4 decimali |
| Stringhe | Max 500 caratteri |
| Array | Convertiti a stringa, max 500 caratteri |
| Oggetti | Max 50 proprietà |

---

## 7. Analisi avanzate

### 7.1 Session replay

`v3.2.0` — Registra e riproduce le sessioni dei visitatori (click, scroll, movimento mouse). Abilitato di default.

### 7.2 Heatmap

`v3.2.0` — Mappa di calore dei click sulle pagine.

### 7.3 Performance (Core Web Vitals)

Aggiungi `data-performance="true"` al tracker per raccogliere:

| Metrica | Cosa misura |
|---|---|
| **LCP** (Largest Contentful Paint) | Velocità caricamento contenuto principale |
| **FCP** (First Contentful Paint) | Primo contenuto visibile |
| **CLS** (Cumulative Layout Shift) | Stabilità visiva del layout |

### 7.4 Goals e Funnel

Definisci obiettivi di conversione e funnel per tracciare percorsi utente:
- **Goals**: conta eventi specifici come conversioni
- **Funnel**: sequenza di passaggi (es. landing → prodotto → checkout → acquisto)

### 7.5 UTM tracking

Umami traccia automaticamente i parametri UTM (`utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`) per analizzare le campagne di marketing.

### 7.6 Compare e Breakdown

- **Compare**: confronta due periodi temporali
- **Breakdown**: segmenta i dati per dimensione (paese, browser, dispositivo)

---

## 8. Dashboard sharing e teams

### 8.1 Share URL

`https://analytics.<SITO_WEB>/settings/websites/TUO-ID`

Nelle impostazioni del sito, abilita **"Enable share URL"** per generare un link pubblico con le statistiche in sola lettura, senza esporre la dashboard admin.

### 8.2 Teams (versione 3.2+)

Puoi creare team e invitare altri utenti per gestire più siti con permessi differenziati.

---

## 9. Gestione del database

### 9.1 Credenziali default

- **Username**: `admin`
- **Password**: `umami`

**Cambia la password** al primo accesso: Settings → Profile → Change password.

### 9.2 Backup

```bash
# Backup database umami
docker exec analytics-postgres pg_dump -U analytics umami > ~/backups/umami-$(date +%Y%m%d).sql

# Ripristino
docker exec -i analytics-postgres psql -U analytics -d umami < ~/backups/umami-YYYYMMDD.sql
```

### 9.3 Reset password admin

Se perdi la password admin, genera un nuovo hash e aggiorna il database:

```bash
cd ~/docker/analytics && source .env
docker exec analytics-postgres psql -U analytics -d umami -c \
  "UPDATE umami_user SET password = '\$2b\$12\$...' WHERE username = 'admin';"
```

> L'hash bcrypt va generato esternamente o ricreando il database da zero.

---

## 10. Bypass ad blockers

Alcuni ad blocker bloccano `script.js` perché il nome è riconoscibile. Soluzioni:

### 10.1 Rinominare lo script

Imposta la variabile d'ambiente `TRACKER_SCRIPT_NAME` nel `docker-compose.yml`:

```yaml
environment:
  - TRACKER_SCRIPT_NAME=custom-tracker
```

Poi nel `<head>` del sito:

```html
<script defer src="https://analytics.<SITO_WEB>/custom-tracker.js" ...></script>
```

### 10.2 Endpoint raccolta custom

Imposta `COLLECT_API_ENDPOINT` nel `docker-compose.yml` per cambiare il percorso API:

```yaml
environment:
  - COLLECT_API_ENDPOINT=/my-collect-endpoint
```

### 10.3 Proxy inverso

Configura un proxy nel tuo sito (es. `/stats/script.js` → `analytics.<SITO_WEB>/script.js`) per evitare che il dominio venga bloccato.

---

## 11. Manutenzione

```bash
cd ~/docker/analytics

# Stato
docker compose ps

# Log
docker compose logs umami --tail 50 -f

# Riavviare
docker compose restart umami

# Aggiornare immagine
docker compose pull umami
docker compose up -d umami
```

---

## 12. Troubleshooting

### Dati non compaiono nella dashboard

1. Apri strumenti sviluppatore (F12) → Network
2. Ricarica il sito e cerca richieste a `analytics.<SITO_WEB>`
3. Verifica che lo script tracker sia caricato senza errori 404
4. Verifica che `data-website-id` sia corretto
5. Controlla che il sito sia stato aggiunto nella dashboard Umami

### Ad blocker blocca il tracker

Vedi §10 (Bypass ad blockers). Il sintomo: visitatori reali ma zero dati.

### Container unhealthy

L'healthcheck Umami usa `wget` su `http://127.0.0.1:3000/api/heartbeat`. Se il container è unhealthy:

```bash
docker logs analytics-umami --tail 20
```

Verifica che PostgreSQL sia raggiungibile e che le tabelle esistano:

```bash
docker exec analytics-postgres psql -U analytics -d umami -c "\dt"
```

---

## 13. Riferimenti

- [Documentazione ufficiale Umami](https://umami.is/docs)
- [Umami GitHub](https://github.com/umami-software/umami)
- [Guida deploy OCI](guida-deploy-waline-umami.md) (in `oracle-servers`)
- [Script di setup](../../tenant/servers/s1/scripts/11-setup-analytics.sh) (in `oracle-servers`)
