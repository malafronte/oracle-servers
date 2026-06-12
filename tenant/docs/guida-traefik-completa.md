# Guida Traefik — Reverse Proxy HTTPS su Docker ARM64

Guida dal livello principiante all'uso avanzato, basata sull'esperienza reale del server `<NOME_SERVER>`. Traefik v3.7.4 su ARM64.

---

## 1. Cos'è Traefik e perché usarlo

Traefik è un **reverse proxy** che si mette tra Internet e i tuoi container. Riceve le richieste HTTPS e le inoltra al container giusto.

```
Internet → Traefik (:80/:443) → container web (porta interna)
```

Fa automaticamente tre cose:
1. **Scopre i container** Docker in tempo reale, senza toccare file di config
2. **Genera certificati HTTPS** via Let's Encrypt (gratis, automatici)
3. **Protegge i servizi** con basic auth, redirect, rate limiting

Sul nostro server, Traefik gestisce 9+ sottodomini con zero configurazione manuale per ogni nuovo progetto.

---

## 2. Architettura di Traefik

### 2.1 I quattro pilastri

Ogni richiesta HTTP segue questo percorso:

```
         Internet
            │
            ▼
     ┌─ entryPoint ─┐     "Da dove entra?"
     │  web (:80)    │
     │  websecure(:443)
     └───────┬───────┘
             │
             ▼
     ┌─── Router ────┐     "A chi lo mando?"
     │ regole Host()  │
     │ priotità       │
     │ TLS on/off     │
     └───────┬───────┘
             │
             ▼
     ┌ Middleware ───┐      "Cosa faccio prima?"
     │ basicAuth      │
     │ redirectRegex  │
     │ compress       │
     └───────┬───────┘
             │
             ▼
     ┌── Service ────┐      "Dove sta il container?"
     │ loadbalancer   │
     │ server.port    │
     └───────────────┘
             │
             ▼
         Container
      (es. cinebase-web:8080)
```

### 2.2 Configurazione statica vs dinamica

| | Statica (`traefik.yml`) | Dinamica |
|---|---|---|
| **Quando si carica** | All'avvio di Traefik | In tempo reale |
| **Cosa contiene** | entryPoints, providers, certificati | routers, services, middlewares |
| **Come si modifica** | Riavviando Traefik | Modificando label Docker o file in `/config` |
| **Esempio** | `entryPoints.web.address: ":80"` | `traefik.http.routers.web.rule=Host(...)` |

La configurazione statica dice a Traefik **come funzionare**. La dinamica dice **cosa instradare**.

---

## 3. Configurazione statica (`traefik.yml`)

### 3.1 File completo commentato

```yaml
global:
  checkNewVersion: false       # Non chiamare l'API di Traefik
  sendAnonymousUsage: false    # Non inviare statistiche

log:
  level: INFO                  # DEBUG per troubleshooting

# ── API e Dashboard ──────────────────────────────────────────────────────
api:
  dashboard: true              # Abilita dashboard web su /api
  insecure: false              # false = solo via HTTPS con basic auth

# ── EntryPoints (porte di ingresso) ─────────────────────────────────────
entryPoints:
  web:
    address: ":80"             # HTTP
    http:
      redirections:
        entryPoint:
          to: websecure        # Tutto HTTP → HTTPS
          scheme: https
          permanent: true      # 301 redirect
  websecure:
    address: ":443"            # HTTPS

# ── Certificati Let's Encrypt ───────────────────────────────────────────
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@<DOMINIO>          # Email per notifiche scadenza
      storage: /certificates/acme.json    # Dove salvare i certificati
      httpChallenge:
        entryPoint: web                   # Sfida HTTP sulla porta 80

# ── Providers (fonti di configurazione dinamica) ────────────────────────
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false               # Richiede esplicitamente traefik.enable=true
    network: traefik-net                  # Network predefinita per i container
  file:
    directory: /config                    # Carica tutti i .yml in /config/
    watch: true                           # Ricarica automaticamente se cambiano
```

### 3.2 EntryPoints spiegati

- **`web`** (porta 80): riceve HTTP. Il redirect manda tutto a `websecure`.
- **`websecure`** (porta 443): riceve HTTPS con certificato Let's Encrypt.

Ogni router deve dichiarare a quale entryPoint appartiene.

### 3.3 Providers spiegati

- **`docker`**: Traefik osserva i container Docker con label `traefik.*`. Quando un container parte/riparte, la configurazione si aggiorna automaticamente.
- **`file`**: carica file YAML da `/config/`. Utile per middleware basic auth che non possono stare nelle label (bug `$$` con bcrypt).

---

## 4. Docker Provider — Discovery automatico

### 4.1 Come funziona

1. Traefik si connette a `/var/run/docker.sock` (sola lettura)
2. Cerca container con label `traefik.enable=true`
3. Legge tutte le label `traefik.http.*` e costruisce router, services, middlewares
4. Quando un container parte/riparte, si aggiorna in tempo reale

### 4.2 Label essenziali per esporre un servizio

```yaml
services:
  cinebase-web:
    image: registry.<DOMINIO>/cinebase/web:latest
    networks:
      - traefik-net                          # Deve essere sulla rete di Traefik
    labels:
      - "traefik.enable=true"                                         # ① Attiva discovery
      - "traefik.http.routers.cinebase.rule=Host(`www.<DOMINIO_APP>`)"  # ② Router: quale dominio
      - "traefik.http.routers.cinebase.entrypoints=websecure"         # ③ Solo HTTPS
      - "traefik.http.routers.cinebase.tls.certresolver=letsencrypt"  # ④ Certificato auto
      - "traefik.http.services.cinebase.loadbalancer.server.port=8080"# ⑤ Porta del container
```

### 4.3 Esempio completo: servizio senza middleware

```yaml
# Portainer — servizio esposto con solo HTTPS, nessuna auth extra
portainer:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.portainer.rule=Host(`portainer.<DOMINIO>`)"
    - "traefik.http.routers.portainer.entrypoints=websecure"
    - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
    - "traefik.http.services.portainer.loadbalancer.server.port=9000"
```

### 4.4 Priorità router

Se due router hanno la stessa regola `Host()`, vince quello con **priorità più alta**:

```yaml
# Router con priorità esplicita
- "traefik.http.routers.api.priority=100"
- "traefik.http.routers.api.rule=Host(`api.<DOMINIO_APP>`)"
```

Utile quando hai regole che si sovrappongono (es. `<DOMINIO_APP>` vs `www.<DOMINIO_APP>`).

---

## 5. HTTP Routers

Un router decide **quale container** riceve una richiesta in base al dominio.

### 5.1 Anatomia di un router

```yaml
traefik.http.routers.<nome>.<proprietà>=<valore>
```

| Proprietà | Obbligatoria? | Esempio |
|---|---|---|
| `rule` | SÌ | `Host(\`www.<DOMINIO_APP>\`)` |
| `entrypoints` | SÌ | `websecure` |
| `tls.certresolver` | SÌ (per HTTPS) | `letsencrypt` |
| `service` | NO (auto) | `cinebase-web@docker` |
| `middlewares` | NO | `netdata-auth@file` |
| `priority` | NO | `100` |

### 5.2 Regole Host()

| Regola | Match |
|---|---|
| `Host(\`<DOMINIO_APP>\`)` | Solo `<DOMINIO_APP>` |
| `Host(\`www.<DOMINIO_APP>\`)` | Solo `www.<DOMINIO_APP>` |
| `Host(\`<DOMINIO_APP>\`, \`www.<DOMINIO_APP>\`)` | Entrambi |
| `HostRegexp(\`{subdomain:[a-z]+}.<DOMINIO_APP>\`)` | Qualsiasi sottodominio |

### 5.3 Router senza servizio esplicito

Se non specifichi il `service`, Traefik lo deduce dal nome del router:
```yaml
traefik.http.routers.cinebase-web  → cerca servizio "cinebase-web"
```
Ma è meglio esplicitarlo per chiarezza, specialmente se router e container hanno nomi diversi.

---

## 6. HTTP Services

Un service dice a Traefik **come raggiungere** il container.

### 6.1 LoadBalancer (il più comune)

```yaml
# Servizio semplice: una sola porta
- "traefik.http.services.cinebase.loadbalancer.server.port=8080"
```

Questo dice a Traefik: "il container cinebase ascolta sulla porta 8080".

### 6.2 LoadBalancer con più server (scaling)

Se hai più repliche dello stesso container:
```yaml
- "traefik.http.services.api.loadbalancer.server.port=8080"
# Traefik bilancia automaticamente tra tutti i container con questa label
```

### 6.3 Servizio speciale `api@internal`

La dashboard di Traefik non è un container Docker — è un servizio interno:
```yaml
service: api@internal
```
Si usa solo nel file provider, non nelle label Docker.

---

## 7. HTTP Middlewares

Un middleware intercetta la richiesta **prima** che arrivi al container.

### 7.1 basicAuth — proteggere con password

```yaml
# File provider (~/docker/traefik/config/middleware-netdata.yml)
http:
  middlewares:
    netdata-auth:
      basicAuth:
        users:
          - "admin:$2y$05$HzDahqhocN6ZFnuGCSY0q.Vceo1RV4W9792vRHAB1i7PZo71Od3Mu"
```

```yaml
# Label Docker Compose (riferimento al middleware)
- "traefik.http.routers.netdata.middlewares=netdata-auth@file"
```

**Perché `@file`?** Il router è definito nel provider `docker` (label), ma il middleware è nel provider `file`. Traefik cerca per default nello stesso provider del router. Il suffisso `@file` dice "cercalo nel provider file".

### 7.2 redirectRegex — redirect permanente

```yaml
# Da <DOMINIO_APP> a www.<DOMINIO_APP>
- "traefik.http.middlewares.cinebase-redirect-www.redirectregex.regex=^https://cinebase\\.it/(.*)"
- "traefik.http.middlewares.cinebase-redirect-www.redirectregex.replacement=https://www.<DOMINIO_APP>/$${1}"
- "traefik.http.middlewares.cinebase-redirect-www.redirectregex.permanent=true"
```

`$${1}` in Docker Compose → `${1}` in Traefik (escaping `$` per YAML).

### 7.3 Chain — combinare più middleware

```yaml
http:
  middlewares:
    cinebase-secure:
      chain:
        middlewares:
          - cinebase-rate-limit
          - cinebase-headers
```

### 7.4 Middleware personalizzati nell'architettura reale

| Servizio | Middleware | Dove è definito | Perché |
|---|---|---|---|
| Dashboard Traefik | `dashboard-auth` | `config/dashboard.yml` (file provider) | basicAuth per proteggere la dashboard |
| Netdata | `netdata-auth` | `config/middleware-netdata.yml` (file provider) | basicAuth; il router è in `docker` provider → serve `@file` |
| Registry UI | `registry-ui-auth` | `config/middleware-registry-ui.yml` (file provider) | Stesso htpasswd del registry; `@file` obbligatorio |
| CineBase redirect | `cinebase-redirect-www` | Label Docker (stesso provider del router) | `<DOMINIO_APP>` → `www.<DOMINIO_APP>`; no `@file` necessario |

---

## 8. Reti Docker e Traefik

### 8.1 Il pattern a due reti

```
┌────────────────────────────────────────────┐
│  traefik-net (esterna, condivisa)           │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │cinebase  │  │ netdata  │  │ portainer│  │
│  │ -web     │  │          │  │          │  │
│  └────┬─────┘  └──────────┘  └──────────┘  │
│       │                                     │
│       │ cinebase-net (interna, isolata)     │
│       │  ┌──────────┐  ┌──────────┐        │
│       │  │ filmapi  │  │ mariadb  │        │
│       │  └──────────┘  └──────────┘        │
└───────┴─────────────────────────────────────┘
```

### 8.2 Definizione delle reti

```yaml
# docker-compose.yml di cinebase
services:
  cinebase-web:
    networks:
      - cinebase-net      # rete interna
      - traefik-net       # raggiungibile da Traefik

  filmapi:
    networks:
      - cinebase-net      # sola rete interna
      - traefik-net       # anche questa raggiungibile da Traefik (API pubblica)

  mariadb:
    networks:
      - cinebase-net      # SOLO rete interna, MAI esposto

networks:
  cinebase-net:
    driver: bridge        # rete isolata per questo progetto
  traefik-net:
    external: true        # rete condivisa, creata da Traefik
```

### 8.3 Perché due reti

- **Sicurezza**: MariaDB non è su `traefik-net` → nessuno dall'esterno può raggiungerlo
- **Isolamento**: i container di progetti diversi non si vedono tra loro
- **Performance**: traffico interno tra filmapi e mariadb non passa da Traefik

### 8.4 Come Traefik usa le reti

Quando Traefik scopre un container, determina il suo IP sulla rete `traefik-net` e lo usa per l'inoltro. Se il container ha più reti, Traefik usa l'IP sulla rete specificata in `providers.docker.network` (nel nostro caso `traefik-net`).

---

## 9. Certificati Let's Encrypt

### 9.1 Come funziona la HTTP Challenge

1. Traefik riceve una richiesta HTTPS per un nuovo dominio
2. Let's Encrypt chiede di dimostrare che il dominio è tuo
3. Traefik espone un file temporaneo sulla porta 80
4. Let's Encrypt verifica il file → rilascia il certificato
5. Il certificato viene salvato in `/certificates/acme.json`

Tutto automatico, nessuna azione manuale.

### 9.2 Verificare i certificati

```bash
# Elenca i certificati nel file acme.json
docker exec traefik cat /certificates/acme.json | jq '.letsencrypt.Certificates[].domain.main'

# Data di scadenza
docker exec traefik cat /certificates/acme.json | jq '.letsencrypt.Certificates[] | {domain: .domain.main, notAfter: .certificate | @base64d | fromjson | .NotAfter}'

# Forzare rinnovo
docker restart traefik
```

### 9.3 Domini multipli con un certificato

Traefik crea automaticamente un certificato per ogni dominio (non wildcard). Con il resolver `letsencrypt`, ogni sottodominio ottiene il suo certificato individuale via HTTP challenge. Questo funziona per tutti i domini i cui record A puntano al server.

---

## 10. Basic Authentication — setup completo

### 10.1 Generare l'hash della password

```bash
# Installa htpasswd
sudo apt install -y apache2-utils

# Genera hash bcrypt
printf '%s' "TuaPassword" | htpasswd -nB -i admin
# Output: admin:$2y$05$HzDahqhocN6ZFnuGCSY0q.Vceo1RV4W9792vRHAB1i7PZo71Od3Mu
```

### 10.2 Creare il file provider

```bash
HASH=$(printf '%s' "TuaPassword" | htpasswd -nB -i admin)

cat > ~/docker/traefik/config/middleware-netdata.yml << EOF
http:
  middlewares:
    netdata-auth:
      basicAuth:
        users:
          - "$HASH"
EOF
```

**⚠️ Perché non usare label Docker Compose?**

Le label Docker Compose richiedono `$$` per ogni `$` nell'hash bcrypt. Un hash come `$2y$05$...` ha ~5 `$`, che diventano `$$2y$$05$$...`. Fragile e illeggibile. Inoltre, con heredoc `<< EOF` (senza apici), bash espande `$2y` come variabile vuota, corrompendo l'hash.

Il file provider **non ha questi problemi** perché il file YAML è interpretato direttamente da Traefik senza passare attraverso bash o Docker Compose.

### 10.3 Usare il middleware in Docker Compose

```yaml
labels:
  - "traefik.http.routers.netdata.middlewares=netdata-auth@file"
```

### 10.4 Riassunto: quando usare `@file`

| Router definito in... | Middleware definito in... | Suffisso |
|---|---|---|
| Docker Compose (provider `docker`) | Docker Compose (provider `docker`) | Nessuno |
| Docker Compose (provider `docker`) | File YAML (provider `file`) | `@file` |
| File YAML (provider `file`) | File YAML (provider `file`) | Nessuno |

---

## 11. Esempi completi dal nostro server

### 11.1 Servizio pubblico (nessuna auth)

```yaml
# CineBase frontend — accesso libero
cinebase-web:
  networks:
    - cinebase-net
    - traefik-net
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.cinebase-web.rule=Host(`www.<DOMINIO_APP>`)"
    - "traefik.http.routers.cinebase-web.entrypoints=websecure"
    - "traefik.http.routers.cinebase-web.tls.certresolver=letsencrypt"
    - "traefik.http.services.cinebase-web.loadbalancer.server.port=8080"
```

### 11.2 Servizio protetto da basic auth

```yaml
# Netdata — richiede login
netdata:
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.netdata.rule=Host(`monitor.<DOMINIO>`)"
    - "traefik.http.routers.netdata.entrypoints=websecure"
    - "traefik.http.routers.netdata.tls.certresolver=letsencrypt"
    - "traefik.http.services.netdata.loadbalancer.server.port=19999"
    - "traefik.http.routers.netdata.middlewares=netdata-auth@file"
```

### 11.3 Redirect www

```yaml
# Nello stesso container del frontend
cinebase-web:
  labels:
    # Sito principale
    - "traefik.http.routers.cinebase-web.rule=Host(`www.<DOMINIO_APP>`)"
    - "traefik.http.routers.cinebase-web.entrypoints=websecure"
    - "traefik.http.routers.cinebase-web.tls.certresolver=letsencrypt"
    - "traefik.http.services.cinebase-web.loadbalancer.server.port=8080"
    # Redirect <DOMINIO_APP> → www.<DOMINIO_APP>
    - "traefik.http.routers.cinebase-redirect.rule=Host(`<DOMINIO_APP>`)"
    - "traefik.http.routers.cinebase-redirect.entrypoints=websecure"
    - "traefik.http.routers.cinebase-redirect.tls.certresolver=letsencrypt"
    - "traefik.http.routers.cinebase-redirect.middlewares=cinebase-redirect-www"
    - "traefik.http.middlewares.cinebase-redirect-www.redirectregex.regex=^https://cinebase\\.it/(.*)"
    - "traefik.http.middlewares.cinebase-redirect-www.redirectregex.replacement=https://www.<DOMINIO_APP>/$${1}"
    - "traefik.http.middlewares.cinebase-redirect-www.redirectregex.permanent=true"
```

### 11.4 Servizio con due router (pubblico + protetto)

```yaml
# Docker Registry — pubblico, ma la UI è protetta
# docker-compose.yml del registry
registry:
  labels:
    - "traefik.http.routers.registry.rule=Host(`registry.<DOMINIO>`)"
    - "traefik.http.routers.registry.entrypoints=websecure"
    - "traefik.http.routers.registry.tls.certresolver=letsencrypt"
    - "traefik.http.services.registry.loadbalancer.server.port=5000"

registry-ui:
  labels:
    - "traefik.http.routers.registry-ui.rule=Host(`registry-ui.<DOMINIO>`)"
    - "traefik.http.routers.registry-ui.entrypoints=websecure"
    - "traefik.http.routers.registry-ui.tls.certresolver=letsencrypt"
    - "traefik.http.routers.registry-ui.middlewares=registry-ui-auth@file"
    - "traefik.http.services.registry-ui.loadbalancer.server.port=80"
```

> **Nota**: la registry UI (accessibile a `registry-ui.<DOMINIO>`) è protetta da basic auth, mentre la registry stessa (`registry.<DOMINIO>`) non lo è — l'autenticazione avviene via `docker login`.

---

## 12. Comandi di diagnostica

```bash
# Dashboard Traefik (verifica router, services, middlewares)
curl -s -u admin:<password> https://traefik.<DOMINIO>/api/http/routers | jq '.[] | {name: .name, rule: .rule, status: .status}'

# Router con errori
curl -s -u admin:<password> https://traefik.<DOMINIO>/api/http/routers | jq '.[] | select(.status != "enabled")'

# Middleware configurati (dal provider file)
curl -s -u admin:<password> https://traefik.<DOMINIO>/api/http/middlewares | jq 'keys'

# Log Traefik (errori di routing, certificati)
docker logs traefik --tail 50 | grep -E 'error|Error|ERR'

# Verificare che un dominio abbia il certificato
echo | openssl s_client -connect www.<DOMINIO_APP>:443 -servername www.<DOMINIO_APP> 2>/dev/null | openssl x509 -noout -dates

# Test routing con curl
curl -s -o /dev/null -w '%{http_code}' https://www.<DOMINIO_APP>
```

---

## 13. Aggiungere un nuovo progetto — checklist

1. Crea `~/docker/nuovo-progetto/docker-compose.yml`
2. Definisci due reti: `internal` (bridge) + `traefik-net` (external)
3. Aggiungi al container esposto le label:
   ```yaml
   labels:
     - "traefik.enable=true"
     - "traefik.http.routers.<nome>.rule=Host(`<dominio>`)"
     - "traefik.http.routers.<nome>.entrypoints=websecure"
     - "traefik.http.routers.<nome>.tls.certresolver=letsencrypt"
     - "traefik.http.services.<nome>.loadbalancer.server.port=<porta>"
   ```
4. Aggiungi record A nel DNS: `<dominio>` → `<IP_SERVER>`
5. Avvia: `docker compose up -d`

---

## 14. Errori comuni e soluzioni

| Errore | Causa | Soluzione |
|---|---|---|
| `404 page not found` | Router non trovato per quel dominio | Controlla label `Host()` e che `traefik.enable=true` |
| `bad gateway` (502) | Traefik non raggiunge il container | Container su `traefik-net`? Porta corretta? |
| `middleware "X@file" does not exist` | Middleware definito in provider file ma senza `@file` nel router | Aggiungi `@file` al nome del middleware |
| `middleware "X@file@file" does not exist` | Doppio `@file` (sed eseguito due volte) | `sed -i 's/netdata-auth@file@file/netdata-auth@file/'` |
| Certificato non generato | Dominio non punta al server o porta 80 non raggiungibile | Verifica DNS: `nslookup dominio`; `curl -I http://dominio` |
| `ERR internal server error` su dashboard | File YAML malformato in `/config/` | Controlla indentazione e sintassi YAML |
| Dashboard accessibile senza password | `insecure: true` nel `traefik.yml` | Imposta `insecure: false` e usa file provider per basic auth |
| `traefik.enable=true` ma il container non appare | Container su rete diversa da `traefik-net` | Aggiungi `traefik-net` alle reti del servizio |
| Container visibile ma `404` da Traefik | `exposedByDefault: false` senza `traefik.enable=true` | Aggiungi label `traefik.enable=true` |

---

## 15. Manutenzione

```bash
# Aggiornare Traefik
cd ~/docker/traefik
docker compose pull
docker compose up -d

# Backup configurazione
tar czf ~/backup/traefik-$(date +%Y%m%d).tar.gz ~/docker/traefik/traefik.yml ~/docker/traefik/config/

# Verificare scadenze certificati (ogni mese)
docker exec traefik cat /certificates/acme.json | jq '.letsencrypt.Certificates[] | {domain: .domain.main, notAfter: .certificate | @base64d | fromjson | .NotAfter}'

# Pulizia immagini vecchie
docker image prune -a -f
```
