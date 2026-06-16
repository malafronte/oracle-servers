# Waline — Guida alle funzionalità e configurazione

> Guida operativa per Waline in produzione su OCI ARM64 con Docker + PostgreSQL, dietro Traefik.

**Server**: `<NOME_SERVER>` (OCI ARM64 Ampere A1)  
**Dominio**: `comments.<SITO_WEB>`  
**Directory**: `~/docker/analytics/`

---

## 1. Architettura

```
comments.<SITO_WEB> (HTTPS)
        │
        ▼
    Traefik (certificato Let's Encrypt)
        │
        ▼
    waline (container Docker, porta 8360)
        │
        ▼
    PostgreSQL 16 (stesso host, database `waline`)
```

- Waline è in ascolto su `http://127.0.0.1:8360`
- Traefik gestisce il certificato SSL e inoltra le richieste HTTPS
- PostgreSQL condiviso con Umami nello stesso stack Docker Compose
- Rete interna `internal` per Waline ↔ PostgreSQL, rete `traefik-net` per l'ingresso

---

## 2. Configurazione attuale

### 2.1 Variabili d'ambiente (in `~/docker/analytics/.env`)

| Variabile | Valore | Descrizione |
|---|---|---|
| `WALINE_DOMAIN` | `comments.<SITO_WEB>` | Dominio pubblico di Waline |
| `WALINE_DB_NAME` | `waline` | Nome database PostgreSQL |
| `POSTGRES_USER` | `analytics` | Utente PostgreSQL |
| `POSTGRES_PASSWORD` | *(generata)* | Password PostgreSQL |
| `SITE_NAME` | `<SITO_WEB>` | Nome del sito |
| `SITE_URL` | `https://<SITO_WEB>` | URL completo del sito |
| `AUTHOR_EMAIL` | `admin@<SITO_WEB>` | Email per notifiche nuovi commenti |
| `WALINE_LANG` | `it-IT` | Lingua dell'interfaccia |
| `COMMENT_RATE_LIMIT` | `60` | Secondi minimi tra commenti (stesso IP) |

### 2.2 Variabili Docker Compose (hardcodate nel servizio `waline`)

| Variabile | Valore | Descrizione |
|---|---|---|
| `PG_HOST` | `postgres` | Hostname PostgreSQL (nome container) |
| `PG_PORT` | `5432` | Porta PostgreSQL |
| `PG_DB` | `${WALINE_DB_NAME}` | Database Waline |
| `PG_USER` | `${POSTGRES_USER}` | Utente DB |
| `PG_PASSWORD` | `${POSTGRES_PASSWORD}` | Password DB |
| `SECURE_DOMAINS` | `<SITO_WEB>,comments.<SITO_WEB>` | Domini autorizzati (senza `https://`) |
| `LOGIN` | `force` | Login obbligatorio per commentare |

### 2.3 Configurazione lato client (`site.config.ts`)

```ts
waline: {
  enable: true,
  server: 'https://comments.<SITO_WEB>',
  showMeta: true,                    // mostra metadati (visite, commenti)
  emoji: ['bmoji', 'weibo'],         // preset emoji per i commenti
  additionalConfigs: {
    pageview: true,                  // contatore visite
    comment: true,                   // commenti abilitati
    imageUploader: false,            // upload immagini disabilitato
    login: 'force',                  // login obbligatorio
    lang: 'it-IT',                   // lingua interfaccia
    locale: {
      reaction0: 'Mi piace',
      placeholder: 'Effettua il login per commentare'
    }
  }
}
```

---

## 3. Moderazione

### 3.1 Pannello di amministrazione

Accessibile da `https://comments.<SITO_WEB>/ui/` dopo il login admin. Il primo utente registrato è automaticamente amministratore.

**Azioni disponibili:**

| Azione | Come |
|---|---|
| Approvare commento | Clicca ✓ |
| Eliminare commento | Clicca 🗑 |
| Segnare come spam | Clicca 🚩 |
| Modificare commento | Clicca ✏️ |
| Vedere IP commentatore | Hover sul commento |

### 3.2 Audit mode (approvazione preventiva)

I commenti restano nascosti finché non approvati dall'admin.

**Attivare:**

```bash
cd ~/docker/analytics
# Aggiungi al docker-compose.yml nel servizio waline, sezione environment:
#   - COMMENT_AUDIT=true
# Poi:
docker compose up -d waline
```

**Disattivare:**

```bash
sed -i '/COMMENT_AUDIT=true/d' docker-compose.yml
docker compose up -d waline
```

### 3.3 IP Block

Dalla dashboard admin puoi bloccare singoli IP. I commenti da IP bloccati vengono automaticamente rifiutati.

---

## 4. Anti-spam

### 4.1 Rate limiting IP (già attivo)

```bash
COMMENT_RATE_LIMIT=60
```

Limite di 1 commento ogni 60 secondi per lo stesso IP. Impostato a livello di server via variabile d'ambiente.

### 4.2 Akismet (anti-spam automatico)

Servizio cloud che analizza i commenti e li classifica come spam/ham. Richiede API key gratuita da [akismet.com](https://akismet.com).

```bash
# Aggiungi al docker-compose.yml:
#   - AKISMET_KEY=la-tua-api-key
docker compose up -d waline
```

### 4.3 reCAPTCHA v3 (Google)

Richiede una chiave da [google.com/recaptcha](https://www.google.com/recaptcha).

```bash
# Server (docker-compose.yml):
#   - RECAPTCHA_V3_KEY=...
#   - RECAPTCHA_V3_SECRET=...

# Client (site.config.ts, in additionalConfigs):
#   recaptchaV3Key: '...'
```

### 4.4 Turnstile (Cloudflare)

Alternativa a reCAPTCHA, più rispettosa della privacy. Richiede chiave da [cloudflare.com/products/turnstile](https://www.cloudflare.com/products/turnstile).

```bash
# Server (docker-compose.yml):
#   - TURNSTILE_KEY=...
#   - TURNSTILE_SECRET=...

# Client (site.config.ts, in additionalConfigs):
#   turnstileKey: '...'
```

---

## 5. Notifiche email

### 5.1 Notifiche admin (nuovi commenti)

Waline può inviare una email all'admin quando un utente pubblica un nuovo commento. Richiede configurazione SMTP.

### 5.2 Configurazione SMTP

Aggiungi al `docker-compose.yml` nel servizio `waline`:

```yaml
environment:
  - SMTP_SERVICE=SendGrid          # oppure SMTP_HOST / SMTP_PORT manuali
  - SMTP_HOST=smtp.sendgrid.net
  - SMTP_PORT=587
  - SMTP_SECURE=false
  - SMTP_USER=apikey
  - SMTP_PASS=SG.la-tua-api-key
  - SENDER_NAME=Malafronte Blog
  - SENDER_EMAIL=noreply@<SITO_WEB>
```

**Provider SMTP gratuiti:**

| Provider | Limite | Note |
|---|---|---|
| SendGrid | 100 email/giorno | Piano free |
| Brevo | 300 email/giorno | Piano free |
| Gmail | 500 email/giorno | Richiede App Password |
| Aruba | Illimitato | Se hai casella Aruba |

### 5.3 Notifiche utenti

Con SMTP configurato, Waline invia automaticamente email a:
- Utenti che ricevono risposte ai loro commenti
- Admin per ogni nuovo commento
- Email di verifica per nuovi account registrati

---

## 6. Gestione utenti

### 6.1 Registrazione

Gli utenti si registrano su `https://comments.<SITO_WEB>/ui/register`. Con `LOGIN=force` la registrazione è obbligatoria per commentare.

### 6.2 Ruoli

| Ruolo | Permessi |
|---|---|
| **Admin** | Moderazione completa, accesso dashboard, gestione utenti |
| **Utente** | Scrivere commenti, ricevere notifiche |

Il primo utente registrato è automaticamente amministratore. Admin aggiuntivi possono essere promossi dalla dashboard.

### 6.3 Bloccare un utente

Dalla dashboard admin: clicca sul commento dell'utente → azioni → blocca.

---

## 7. Reazioni ai post

Le reazioni (emoji) appaiono in fondo a ogni articolo del blog. Attualmente configurata solo la reazione "Mi piace" (cuore).

### 7.1 Personalizzare le reazioni

Nel `site.config.ts`, in `additionalConfigs.reaction`:

```ts
// Reazioni multiple
reaction: ['/icons/heart-item.svg', '/icons/thumbs-up.svg', '/icons/star.svg']

// Disabilitare reazioni
reaction: false
```

---

## 8. Contatore visite

Il contatore visite è attivato via `pageview: true` e viene mostrato nell'header dei post blog (via componente `PageInfo.astro`).

**Copertura automatica:**

| Sezione | Contatore | Note |
|---|---|---|
| Blog (post) | Attivo | Layout `BlogPost.astro` |
| Docs | Attivo | Layout docs |
| Progetti | Possibile | Richiede `<Comment waline={false} pageview={true} />` |
| Chi sono | Possibile | Richiede `<Comment waline={false} pageview={true} />` |
| Home page | Disattivo | Senza contatore |

---

## 9. Manutenzione

```bash
cd ~/docker/analytics

# Stato
docker compose ps

# Log in tempo reale
docker compose logs -f --tail=50

# Riavviare Waline
docker compose restart waline

# Aggiornare immagine
docker compose pull waline
docker compose up -d waline
```

---

## 10. Troubleshooting

### "403 Forbidden" su registrazione o commenti

`SECURE_DOMAINS` contiene il protocollo `https://`. Deve contenere solo i domini puri:
```
SECURE_DOMAINS=<SITO_WEB>,comments.<SITO_WEB>
```

### "500: relation wl_users does not exist"

Le tabelle PostgreSQL non sono state create. Waline non fa auto-migrazione per PostgreSQL:

```bash
docker exec -i analytics-postgres psql -U analytics -d waline < ~/docker/analytics/waline.pgsql
docker compose restart waline
```

### Container unhealthy

L'immagine Waline non include `wget`. L'healthcheck usa `CMD-SHELL` con Node.js invece di `CMD` con `wget`. Lo script `11-setup-analytics.sh` applica già questa correzione.

### Contatore visite non incrementa

1. Controlla la console browser per errori CORS
2. Verifica che `SECURE_DOMAINS` includa il dominio del sito
3. Controlla che Waline sia healthy

---

## 11. Riferimenti

- [Documentazione ufficiale Waline](https://waline.js.org)
- [Waline GitHub](https://github.com/walinejs/waline)
- [Guida deploy OCI](guida-deploy-waline-umami.md)
- [Script di setup di Waline e Umami](../../tenant/servers/s1/scripts/11-setup-analytics.sh)
