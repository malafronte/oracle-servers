# Waline — Guida all'autenticazione e ai provider OAuth

> Guida operativa per comprendere il meccanismo di autenticazione di Waline in produzione e per implementare un set personalizzato di provider di login social (GitHub, Facebook, Google, X, Microsoft).

**Server**: `malafronte-oci-s1` (OCI ARM64 Ampere A1)
**Dominio Waline**: `comments.malafronte.dev`
**Dominio auth (futuro)**: `auth.malafronte.dev`
**Directory**: `~/docker/analytics/`
**Script di riferimento**: [`11-setup-analytics.sh`](../servers/s1/scripts/11-setup-analytics.sh)

---

## 1. Panoramica

Waline supporta due meccanismi di accesso indipendenti:

1. **Login nativo email/username** — gestito interamente dal server Waline, senza dipendenze esterne.
2. **Login social (OAuth)** — delegato a un **servizio esterno separato**, non implementato dentro Waline.

La gran parte degli equivoci sull'autenticazione di Waline nasce da questo: non esistono variabili tipo `GITHUB_CLIENT_ID` da mettere nel server Waline. Gli OAuth provider sono gestiti da un componente a sé stante, il progetto [`walinejs/auth`](https://github.com/walinejs/auth), che il server Waline contatta via URL.

Questa guida spiega:

- lo stato attuale dell'autenticazione su `comments.malafronte.dev`;
- perché i provider cinesi (Weibo, QQ) compaiono nella pagina di login e perché Google non compare;
- come sostituire il servizio OAuth pubblico di default con una propria istanza, scegliendo esattamente quali provider esporre (GitHub, Facebook, Google, X, Microsoft).

---

## 2. Come funziona l'autenticazione in Waline

### 2.1 Due meccanismi distinti

| Meccanismo | Dove è implementato | Variabili coinvolte | Stato attuale |
|---|---|---|---|
| Login email/username | Server Waline (`analytics-waline`) | `LOGIN=force`, `SMTP_*` (opzionali) | Attivo |
| Login social OAuth | Servizio esterno `walinejs/auth` | `OAUTH_URL` (server Waline) + `*_ID`/`*_SECRET` (servizio auth) | Attivo via servizio pubblico |

Il server Waline **non conosce** GitHub, Google, ecc. Conosce solo un URL (`OAUTH_URL`) a cui inoltra l'utente quando clicca su un bottone social. Quel servizio esterno fa la vera OAuth dance con la piattaforma (GitHub, Google, …) e rimanda l'utente a Waline con i dati di profilo.

### 2.2 Il ruolo di `OAUTH_URL`

Variabile d'ambiente del server Waline:

```
OAUTH_URL=https://oauth.lithub.cc        # default
```

Documentazione ufficiale: <https://waline.js.org/reference/server/env.html> (sezione "高级配置 / Advanced").

Quando l'utente clicca "Login with GitHub":

1. Waline costruisce un redirect verso `${OAUTH_URL}/github?redirect=...&state=...`
2. Il browser va su `oauth.lithub.cc/github`
3. Quel servizio avvia il flusso OAuth verso GitHub
4. A flusso completato, il servizio risponde a Waline con i dati utente (nick, email, avatar)
5. Waline crea la sessione

La lista dei bottoni social mostrati nella UI di login è decisa da **cosa il servizio puntato da `OAUTH_URL` espone**, non da Waline.

### 2.3 Il servizio `walinejs/auth`

Repo: <https://github.com/walinejs/auth>

È una piccola applicazione Node.js/Express che fa da "OAuth broker". Espone un endpoint per ciascun provider:

- `/github`, `/facebook`, `/google`, `/twitter`, `/weibo`, `/qq`, `/huawei`, `/oidc`

Un provider viene esposto **solo se** il servizio ha le relative credenziali configurate via variabili d'ambiente (es. `GITHUB_ID` + `GITHUB_SECRET`). Se non configurato, il provider non compare e l'endpoint resta inattivo.

Provider supportati (elenco ufficiale):

| Provider | Variabili richieste | Note |
|---|---|---|
| GitHub | `GITHUB_ID`, `GITHUB_SECRET` | — |
| Facebook | `FACEBOOK_ID`, `FACEBOOK_SECRET` | — |
| Google | `GOOGLE_ID`, `GOOGLE_SECRET` | — |
| Twitter / X | `TWITTER_ID`, `TWITTER_SECRET`, `LEAN_ID`, `LEAN_KEY` | Usa OAuth 1.0a; richiede account [LeanCloud](https://leancloud.app) per stoccare i token temporanei |
| Weibo | `WEIBO_ID`, `WEIBO_SECRET` | Social cinese |
| QQ | `QQ_ID`, `QQ_SECRET` | Social cinese |
| Huawei | `HUAWEI_ID`, `HUAWEI_SECRET` | Social cinese |
| OIDC generico | `OIDC_ID`, `OIDC_SECRET`, `OIDC_ISSUER` (oppure `OIDC_AUTH_URL`/`OIDC_TOKEN_URL`/`OIDC_USERINFO_URL`) | Per qualsiasi provider OIDC: Microsoft Azure AD, Google, Apple, Keycloak, ecc. |

**Non supportati**: Instagram, TikTok, LinkedIn, Discord (quest'ultimo è supportato dal client Waline ma non dal servizio auth ufficiale), Telegram.

---

## 3. Implementazione attuale

### 3.1 Cosa c'è in produzione

Sul server s1 lo script `11-setup-analytics.sh` configura Waline senza alcun riferimento a OAuth. In particolare nel blocco `environment` del servizio `waline` (righe `11-setup-analytics.sh:196-212`) **non compare `OAUTH_URL`**: Waline usa quindi il default `https://oauth.lithub.cc`.

```yaml
# Estratto di 11-setup-analytics.sh — servizio waline
environment:
  - PG_HOST=postgres
  - PG_PORT=5432
  - PG_DB=${WALINE_DB_NAME}
  - PG_USER=${POSTGRES_USER}
  - PG_PASSWORD=${POSTGRES_PASSWORD}
  - SITE_NAME=${SITE_NAME}
  - SITE_URL=${SITE_URL}
  - AUTHOR_EMAIL=${AUTHOR_EMAIL}
  - LANG=${WALINE_LANG}
  - SECURE_DOMAINS=${SITE_DOMAIN},${WALINE_DOMAIN}
  - LOGIN=force
  - COMMENT_RATE_LIMIT=${COMMENT_RATE_LIMIT:-60}
  # NOTA: nessuna variabile OAUTH_URL → usa il default oauth.lithub.cc
```

### 3.2 Provider attualmente visibili

Dal servizio pubblico `oauth.lithub.cc` (gestito dall'autore di Waline, lizheming) la pagina di login mostra:

- GitHub ✅
- X / Twitter ✅
- Facebook ✅
- Weibo ⚠️ (cinese)
- QQ ⚠️ (cinese)

Google, Microsoft, Apple, Instagram **non compaiono**.

### 3.3 Limiti dell'implementazione attuale

1. **Provider cinesi non rimovibili**: fintanto che si usa `oauth.lithub.cc`, Weibo e QQ rimangono esposti. Non esiste variabile per nasconderli lato Waline.
2. **Google / Microsoft / Apple non disponibili**: il servizio pubblico non li espone (o non in modo affidabile).
3. **Dipendenza operativa**: `oauth.lithub.cc` è un servizio gratuito gestito da una sola persona. Se va down, tutti i login social si bloccano all'improvviso. Il login email/username continua a funzionare perché indipendente.
4. **Privacy**: il flusso OAuth transita per infrastrutture di terzi. I dati di profilo dei commentatori passano per `oauth.lithub.cc`.

---

## 4. Obiettivo: GitHub, Facebook, Google, X, Microsoft

### 4.1 Mappatura provider → supporto

| Provider desiderato | Supporto in `walinejs/auth` | Strategia |
|---|---|---|
| GitHub | ✅ Nativo | Variabili `GITHUB_*` |
| Facebook | ✅ Nativo | Variabili `FACEBOOK_*` |
| Google | ✅ Nativo | Variabili `GOOGLE_*` |
| X (Twitter) | ✅ Nativo (OAuth 1.0a) | Variabili `TWITTER_*` + `LEAN_*` |
| Microsoft | ✅ Via OIDC | Variabili `OIDC_*` puntate ad Azure AD v2.0 |

Tutti e cinque i provider sono raggiungibili. Microsoft non ha un connettore dedicato ma Azure AD è pienamente OIDC-compliant, quindi si configura tramite il provider OIDC generico.

### 4.2 Cosa serve

1. **Credenziali OAuth** su ciascuna delle 5 piattaforme (v. sezione 5).
2. **Una propria istanza di `walinejs/auth`** che abbia configurate le variabili d'ambiente dei 5 provider (v. sezione 6).
3. **Un sottodominio** per la propria istanza auth (es. `auth.malafronte.dev`) con HTTPS.
4. **Una modifica al server Waline**: impostare `OAUTH_URL` per puntare alla propria istanza (v. sezione 7).

Weibo e QQ spariscono automaticamente perché non vengono configurati.

---

## 5. Creazione delle credenziali OAuth su ogni piattaforma

Per ogni piattaforma devi registrare una "app" e ottenere un `CLIENT_ID` (o equivalente) e un `CLIENT_SECRET`. Il **redirect URL** da registrare è sempre verso la **propria istanza auth** (`https://auth.malafronte.dev/<provider>`), mai verso `comments.malafronte.dev`.

### 5.1 GitHub

1. Vai su <https://github.com/settings/developers> → **OAuth Apps** → **New OAuth App**.
2. Compila:
   - Application name: `Malafronte Blog Comments`
   - Homepage URL: `https://malafronte.dev`
   - Authorization callback URL: `https://auth.malafronte.dev/github`
3. Salva, ottieni **Client ID** (visibile) e genera **Client Secret** (Generate).
4. Variabili per auth: `GITHUB_ID`, `GITHUB_SECRET`.

Tempo: ~5 minuti. Nessuna review.

### 5.2 Facebook

1. Vai su <https://developers.facebook.com> → **My Apps** → **Create App**.
2. Tipo: **Consumer**, aggiungi prodotto **Facebook Login**.
3. In Facebook Login → Settings, imposta **Valid OAuth Redirect URIs**:
   ```
   https://auth.malafronte.dev/facebook
   ```
4. Settings → Basic: copia **App ID** e **App Secret**.
5. Per rendere i login utilizzabili da chiunque, imposta l'app in modalità **Live** (interruttore in alto). La review di Facebook è obbligatoria per permessi estesi, ma per `email`/`public_profile` di base solitamente basta la documentazione della privacy policy.
5. Variabili per auth: `FACEBOOK_ID` (App ID), `FACEBOOK_SECRET` (App Secret).

Tempo: ~15 minuti (più eventuale attesa review).

### 5.3 Google

1. Vai su <https://console.cloud.google.com> → crea o seleziona un progetto.
2. **APIs & Services** → **OAuth consent screen**: configura (tipo External), aggiungi scope `email`, `profile`, `openid`. Aggiungi te stesso come test user se resti in modalità Testing.
3. **APIs & Services** → **Credentials** → **Create Credentials** → **OAuth client ID**.
4. Tipo: **Web application**.
   - Authorized JavaScript origins: (vuoto — il flusso è server-side)
   - Authorized redirect URIs: `https://auth.malafronte.dev/google`
5. Copia **Client ID** e **Client Secret**.
6. Variabili per auth: `GOOGLE_ID`, `GOOGLE_SECRET`.

Tempo: ~10 minuti. Per utenti oltre il tuo dominio (oltre 100) serve la verification di Google.

### 5.4 X (Twitter)

1. Vai su <https://developer.twitter.com> → **Portal** → crea un Project e un App.
2. App **User authentication settings**:
   - Type of App: **Web App, Automated App or Bot**
   - App permissions: **Read**
   - Callback URI / Redirect URL: `https://auth.malafronte.dev/twitter`
   - Website URL: `https://malafronte.dev`
3. In **Keys and tokens** copia **API Key** e **API Key Secret**.
4. Crea un'app su <https://leancloud.app> (free tier). Dal dashboard: **Settings → App keys** copia **App ID** e **App Key**. LeanCloud serve perché il servizio auth usa OAuth 1.0a per Twitter e ha bisogno di un key-value store temporaneo per i token di richiesta.
5. Variabili per auth: `TWITTER_ID` (API Key), `TWITTER_SECRET` (API Key Secret), `LEAN_ID` (LeanCloud App ID), `LEAN_KEY` (LeanCloud App Key).

Tempo: ~20 minuti. Twitter (X) a volte richiede descrizione dell'uso dell'API ed elevator pitch prima di attivare le chiavi.

### 5.5 Microsoft (via Azure AD / OIDC)

Microsoft non ha un connettore dedicato, ma Azure AD v2.0 è OIDC-compliant. Si usa il provider OIDC generico.

1. Vai su <https://entra.microsoft.com> (Azure Active Directory) → **App registrations** → **New registration**.
2. Supported account types: **Accounts in any organizational directory and personal Microsoft accounts** (per consentire login sia aziendali sia @outlook.com / @hotmail.com / @live.com).
3. Redirect URI (Web): `https://auth.malafronte.dev/oidc`
4. Salva. In **Certificates & secrets** → **New client secret** → copia **Value** (non Secret ID).
5. In **Overview** copia **Application (client) ID**.
6. **Endpoints** → copia "OpenID Connect metadata document", di solito:
   ```
   https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration
   ```
   Da cui si ricava l'issuer `https://login.microsoftonline.com/common/v2.0`.
7. Variabili per auth:

   ```
   OIDC_ID=<Application client ID>
   OIDC_SECRET=<Client secret Value>
   OIDC_ISSUER=https://login.microsoftonline.com/common/v2.0
   OIDC_SCOPES=openid profile email
   ```

   In alternativa, invece di `OIDC_ISSUER`, si possono dare gli endpoint espliciti:

   ```
   OIDC_AUTH_URL=https://login.microsoftonline.com/common/oauth2/v2.0/authorize
   OIDC_TOKEN_URL=https://login.microsoftonline.com/common/oauth2/v2.0/token
   OIDC_USERINFO_URL=https://graph.microsoft.com/oidc/userinfo
   ```

Tempo: ~15 minuti. Nessuna review per uso personale.

> **Nota importante sul multi-tenant**: usando `/common` come endpoint accetti login da qualsiasi tenant Azure AD + account personali Microsoft. Per limitarti ai soli account personali (@outlook.com / @hotmail.com) usa `consumers` al posto di `common`. Per un tenant specifico (es. solo la tua azienda), usa il tenant ID.

---

## 6. Deploy dell'istanza auth self-hosted

Due opzioni. **Vercel** è più semplice e coerente con il principio "Always Free" del server; **Docker dietro Traefik** mantiene tutto sul proprio server, in linea con la filosofia del repo.

### 6.1 Opzione A — Vercel (consigliata)

Il progetto `walinejs/auth` è nativamente pensato per Vercel.

1. Fork di <https://github.com/walinejs/auth> sul tuo GitHub.
2. Vai su <https://vercel.com> → **Add New Project** → importa il fork.
3. Framework Preset: Vercel lo rileva automaticamente (Node.js). Nessun build setting da toccare.
4. **Environment Variables** (sezione Settings → Environment Variables): inserisci tutte quelle della sezione 5:

   ```
   GITHUB_ID=...
   GITHUB_SECRET=...
   FACEBOOK_ID=...
   FACEBOOK_SECRET=...
   GOOGLE_ID=...
   GOOGLE_SECRET=...
   TWITTER_ID=...
   TWITTER_SECRET=...
   LEAN_ID=...
   LEAN_KEY=...
   OIDC_ID=...
   OIDC_SECRET=...
   OIDC_ISSUER=https://login.microsoftonline.com/common/v2.0
   OIDC_SCOPES=openid profile email
   ```

5. Deploy. Vercel assegna un dominio tipo `malafronte-auth.vercel.app`.
6. (Consigliato) Aggiungi un dominio personalizzato: Settings → Domains → `auth.malafronte.dev`. Su Cloudflare/Aruba crea record A/CNAME come indicato da Vercel. Vercel gestisce i certificati HTTPS.

Tempo totale: ~10 minuti dopo aver ottenuto le credenziali.

Vantaggi:

- zero manutenzione, zero backup, zero monitoraggio;
- gratis nel piano hobby;
- HTTPS automatico;
- coerente con il principio "Always Free".

Svantaggi:

- i dati di profilo dei commentatori transitano per infrastrutture Vercel;
- una dipendenza in più (Vercel).

### 6.2 Opzione B — Docker dietro Traefik su s1

Per mantenere tutto sul server s1. Non esiste un'immagine Docker ufficiale del progetto auth, va buildata dal repo.

1. Sul server s1:

   ```bash
   mkdir -p ~/docker/waline-auth
   cd ~/docker/waline-auth
   git clone https://github.com/walinejs/auth.git src
   ```

2. Crea un `Dockerfile` in `~/docker/waline-auth/`:

   ```dockerfile
   FROM node:20-alpine
   WORKDIR /app
   COPY src/package.json src/package-lock.json ./
   RUN npm ci --omit=dev
   COPY src/ ./
   EXPOSE 3000
   CMD ["node", "index.js"]
   ```

   > **Da verificare**: il progetto usa `index.js` come entrypoint e l'app ascolta sulla porta configurata da `PORT` (default 3000). Verificare il comportamento reale con `docker logs` dopo il primo avvio: l'app su Vercel gira come serverless, in container potrebbe richiedere piccoli adattamenti (es. `app.listen`). Se non parte, sostituire il CMD con `CMD ["node", "-e", "..."]` o aggiungere un piccolo wrapper che chiami `app.listen(process.env.PORT || 3000)`.

3. Crea `.env` con tutte le credenziali della sezione 5 (gitignora questo file come gli altri `.env`).

4. Crea `docker-compose.yml`:

   ```yaml
   services:
     waline-auth:
       build: .
       container_name: waline-auth
       restart: unless-stopped
       env_file: .env
       environment:
         - PORT=3000
         - TZ=Europe/Rome
       networks:
         - traefik-net
       labels:
         - "traefik.enable=true"
         - "traefik.http.routers.waline-auth.rule=Host(`auth.malafronte.dev`)"
         - "traefik.http.routers.waline-auth.entrypoints=websecure"
         - "traefik.http.routers.waline-auth.tls.certresolver=letsencrypt"
         - "traefik.http.services.waline-auth.loadbalancer.server.port=3000"
       healthcheck:
         test: ["CMD-SHELL", "node -e 'require(\"http\").get(\"http://localhost:3000/\",r=>process.exit(r.statusCode<500?0:1))'"]
         interval: 30s
         timeout: 10s
         retries: 3

   networks:
     traefik-net:
       external: true
   ```

5. Avvia:

   ```bash
   cd ~/docker/waline-auth
   docker compose up -d --build
   docker compose logs -f
   ```

6. DNS: crea record A `auth.malafronte.dev` → IP del server s1 (come già fatto per `comments.malafronte.dev`).

Vantaggi: full self-host, nessun dato esce dal server.
Svantaggi: manutenzione, build dell'immagine, possibile adattamento del codice (Vercel → container).

---

## 7. Collegamento Waline → auth self-hosted

Una volta che la propria istanza auth risponde su `https://auth.malafronte.dev`, modifica il servizio `waline` nel `docker-compose.yml` di analytics:

```yaml
# ~/docker/analytics/docker-compose.yml — servizio waline
  waline:
    image: lizheming/waline:latest
    # ...
    environment:
      # ... (tutte le variabili esistenti restano) ...
      - LOGIN=force
      - COMMENT_RATE_LIMIT=${COMMENT_RATE_LIMIT:-60}
      # NUOVO: punta alla propria istanza auth
      - OAUTH_URL=https://auth.malafronte.dev
```

Applica:

```bash
cd ~/docker/analytics
docker compose up -d waline
docker compose logs --tail=50 waline
```

A differenza della maggior parte delle variabili di Waline, `OAUTH_URL` viene letta a runtime e dovrebbe applicarsi con un semplice `up -d`. In caso di dubbi, riavvia completamente il container con `docker compose restart waline`.

Aggiornamento permanente: dato che lo script `11-setup-analytics.sh` rigenera il `docker-compose.yml` da zero se riavviato, **modificare anche lo script** in [`11-setup-analytics.sh`](../servers/s1/scripts/11-setup-analytics.sh) (blocco `environment` del servizio `waline`, righe 196-212) aggiungendo la riga `- OAUTH_URL=https://auth.malafronte.dev`, in modo che un eventuale ri-esecuzione dello script preservi la configurazione.

---

## 8. Verifica e test

### 8.1 Smoke test dell'istanza auth

```bash
# L'istanza auth risponde?
curl -sI https://auth.malafronte.dev/ | head -1

# L'endpoint GitHub risponde? (deve dare redirect, non 404/500)
curl -sI "https://auth.malafronte.dev/github?redirect=https://comments.malafronte.dev&state=test" | head -1
```

### 8.2 Test di login end-to-end

Per ciascun provider (in incognito per evitare cache/sessioni vecchie):

1. Apri `https://comments.malafronte.dev/ui/login`
2. Clicca il bottone del provider
3. Completa il consenso sulla piattaforma
4. Verifica il redirect di ritorno a Waline e la sessione attiva

### 8.3 Cosa deve risultare

Nella pagina di login devono comparire **solo** i 5 provider configurati: GitHub, Facebook, Google, X, Microsoft. Weibo e QQ non devono più apparire. Devono essere presenti anche i campi email/password (login nativo Waline).

### 8.4 Verifica persistenza utente

Dopo il primo login OAuth, in PostgreSQL deve comparire una riga in `wl_users` con la colonna del provider compilata:

```bash
docker exec -it analytics-postgres psql -U analytics -d waline \
  -c "SELECT id, display_name, email, github, google, facebook, twitter, oidc FROM wl_users;"
```

Lo schema `wl_users` (vedi `11-setup-analytics.sh:132-153`) ha già le colonne per tutti i provider: `github`, `twitter`, `facebook`, `google`, `weibo`, `qq`, `oidc`, `huawei`. **Nessuna modifica allo schema è necessaria**: i login Microsoft (via OIDC) finiscono nella colonna `oidc`.

---

## 9. Provider non inclusi e perché

### 9.1 Apple

Sign in with Apple tecnicamente parla OIDC, quindi in linea di principio configurabile via `OIDC_*`. In pratica il flusso Apple ha vincoli atipici che il provider OIDC generico di `walinejs/auth` non gestisce bene:

- richiede autenticazione del client via **JWT firmato con private key** (non `client_secret` semplice);
- il `client_secret` va generato di volta in volta come JWT breve;
- la redirect URI deve essere uno dei domini registrati e il dominio va verificato con un file `.well-known/apple-app-site-association`.

Per l'uso tipico di un blog personale il costo/beneficio non vale. Se davvero necessario, l'unica via realistica è forkare `walinejs/auth` e aggiungere un connettore Apple dedicato, oppure usare un proxy OIDC come [Keycloak](https://www.keycloak.org) davanti ad Apple e puntare `OIDC_ISSUER` a Keycloak.

### 9.2 Instagram

**Non supportato**. `walinejs/auth` non ha un connettore Instagram. Instagram richiede:

- un'app su [Meta for Developers](https://developers.facebook.com);
- approvazione di `instagram_basic` e `instagram_graph_user_profile`;
- flusso OAuth 2.0 con caratteristiche specifiche di Meta.

Per aggiungerlo servirebbe forkare il progetto e scrivere un nuovo provider. Sconsigliato per il valore che porta a un sistema di commenti (Instagram non è un'identità tipica per chi commenta su un blog tech).

### 9.3 Weibo e QQ

Rimossi automaticamente dalla UI semplicemente **non configurandoli** nell'istanza auth self-hosted. Nessuna azione aggiuntiva: il servizio auth espone solo i provider per cui ha credenziali valide.

---

## 10. Sicurezza e operatività

### 10.1 Segreti

Tutte le variabili `*_SECRET` (e `LEAN_KEY`, `OIDC_SECRET`) sono credenziali sensibili. Regole:

- mai committarle nel repo (il `.gitignore` di oracle-servers già esclude `**/.env`);
- in Vercel, impostarle come Environment Variables con tipo **Secret** (criptate, non visibili dopo l'inserimento);
- su s1, mantenerle solo in `~/docker/waline-auth/.env` con permessi `chmod 600`.

### 10.2 Rotazione

Per ciascuna piattaforma, pianificare rotazione periodica dei secret (almeno annuale, o in caso di sospetta compromissione). Dopo la rotazione, aggiornare le env var dell'istanza auth e riavviare/redistribuire.

### 10.3 Rate limit e abusi

- I limiti di OAuth sono quelli imposti da ciascuna piattaforma sulla tua app. GitHub: 5000 richieste/ora per token. Google: quota generosa. Facebook: soglie per app. Microsoft: dipende dal tenant.
- Per i commenti, il rate limit è già gestito da Waline via `COMMENT_RATE_LIMIT=60` (1 commento ogni 60 secondi per IP).

### 10.4 Dipendenza dal servizio auth

Con self-hosting, la dipendenza da `oauth.lithub.cc` sparisce. Resta una dipendenza dalla propria istanza auth: se questa va down (Vercel o container s1), i login social si bloccano, ma il login email/username continua a funzionare. Monitorare con Netdata (HTTP check su `auth.malafronte.dev`).

### 10.5 Log

- Istanza auth su Vercel: log disponibili nel dashboard Vercel ( Functions → Logs).
- Istanza auth in container su s1: `docker compose logs -f waline-auth`.
- Nessun dato sensibile (password/token) viene loggato dal servizio auth in condizioni normali, ma verificare prima di esporre i log a terzi.

---

## 11. Troubleshooting

### "Login with GitHub" non compare

L'istanza auth non ha `GITHUB_ID`/`GITHUB_SECRET` configurati. Verifica:

```bash
# In Vercel: Settings → Environment Variables
# Su s1: cat ~/docker/waline-auth/.env | grep GITHUB
```

### Redirect URI mismatch dopo il click

Il redirect URL registrato sulla piattaforma OAuth non coincide con quello atteso dal servizio auth. Verifica che sia esattamente `https://auth.malafronte.dev/<provider>` (slash finale niente, protocollo HTTPS, dominio corretto). Per OIDC/Microsoft il path è `/oidc`.

### Twitter: errore "Couldn't find request token"

LeanCloud non è configurato o le credenziali sono errate. Il servizio auth usa LeanCloud per stoccare l'OAuth request token tra il primo e il secondo step del flusso OAuth 1.0a. Senza LeanCloud, Twitter non funziona.

### Microsoft: errore "AADSTS7000216" o "invalid_client"

Il `client_secret` è errato o scaduto. Azure AD secret hanno durata massima 24 mesi: rigenerarli dal portale Azure prima della scadenza. Verificare di usare il **Value** e non il **Secret ID**.

### Microsoft: errore "AADSTS700016" (application not found)

Il `OIDC_ID` non corrisponde a nessuna app nel tenant specificato dall'issuer. Se si usa `/common/` l'app deve essere multi-tenant; se `/consumers/` deve supportare account personali.

### Google: errore "redirect_uri_mismatch"

In Google Cloud Console → Credentials → OAuth client ID, la voce **Authorized redirect URIs** deve contenere esattamente `https://auth.malafronte.dev/google`. Non va in **Authorized JavaScript origins** (quello è per flussi client-side).

### Facebook: i login funzionano solo per me come sviluppatore

L'app è in modalità **Development**. Portarla in **Live** dall'interruttore in alto a destra nel dashboard developers.facebook.com. Per i permessi base (`email`, `public_profile`) non serve review.

### Dopo aver cambiato `OAUTH_URL`, i bottoni non cambiano

Waline potrebbe cachare la lista provider. Forza restart:

```bash
cd ~/docker/analytics
docker compose restart waline
```

Svuota cache browser o usa finestra in incognito.

### Dopo aver ri-eseguito lo script `11-setup-analytics.sh`, `OAUTH_URL` sparisce

Lo script rigenera il `docker-compose.yml` da zero sovrascrivendo le modifiche manuali. Per rendere la modifica permanente, editare lo script [`11-setup-analytics.sh`](../servers/s1/scripts/11-setup-analytics.sh) nel blocco `environment` del servizio `waline` (riga 212, subito dopo `COMMENT_RATE_LIMIT`) aggiungendo:

```
      - OAUTH_URL=https://auth.malafronte.dev
```

---

## 12. Roadmap di implementazione (riepilogo)

Ordine consigliato dei passi, con tempo stimato:

1. **Decisionale**: scegliere tra Vercel (sezione 6.1) e Docker su s1 (sezione 6.2). [5 min]
2. **DNS**: creare record A `auth.malafronte.dev`. [5 min]
3. **Credenziali provider** (sezione 5), in parallelo:
   - GitHub [5 min]
   - Google [10 min]
   - Facebook [15 min]
   - X/Twitter + LeanCloud [20 min]
   - Microsoft Azure AD [15 min]
4. **Deploy istanza auth** (Vercel o Docker). [10–30 min]
5. **Smoke test** istanza auth (sezione 8.1). [5 min]
6. **Modifica `OAUTH_URL`** in `docker-compose.yml` e in `11-setup-analytics.sh`. [5 min]
7. **Test end-to-end** per ogni provider (sezione 8.2). [20 min]
8. **Documentazione**: annotare in questo file le scelte definitive e gli URL dei redirect.

Totale: circa 2 ore, di cui ~1 ora sui portali dei provider.

---

## 13. Riferimenti

- [Documentazione ufficiale Waline — variabili d'ambiente server](https://waline.js.org/reference/server/env.html) (sezione Advanced / `OAUTH_URL`)
- [Repo `walinejs/auth`](https://github.com/walinejs/auth) — servizio OAuth broker
- [Guida alle funzionalità di Waline](waline-guida-funzionalita.md) — configurazione generale, moderazione, anti-spam
- [Guida deploy Waline + Umami](guida-deploy-waline-umami.md) — installazione iniziale
- [Script `11-setup-analytics.sh`](../servers/s1/scripts/11-setup-analytics.sh) — deploy di Waline, Umami e PostgreSQL
- Portali sviluppatori: [GitHub](https://github.com/settings/developers), [Facebook](https://developers.facebook.com), [Google Cloud](https://console.cloud.google.com), [Twitter/X](https://developer.twitter.com), [Azure AD / Entra](https://entra.microsoft.com), [LeanCloud](https://leancloud.app)

---

*Questa guida integra [`waline-guida-funzionalita.md`](waline-guida-funzionalita.md) approfondendo esclusivamente il meccanismo di autenticazione social. Per la configurazione generale di Waline (moderazione, anti-spam, SMTP, contatore visite) fare riferimento a quel documento.*
