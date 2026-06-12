# Traefik – Casi d'uso nel contesto multi-progetto

Scenario: server ARM singolo, più progetti docker-compose indipendenti, ogni progetto su un dominio diverso con HTTPS automatico.

---

## Caso 1 – Esporre un'app su dominio con HTTPS

Ogni container che vuoi esporre ha bisogno di 5 label:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<nome>.rule=Host(`miodominio.com`)"
  - "traefik.http.routers.<nome>.entrypoints=websecure"
  - "traefik.http.routers.<nome>.tls.certresolver=letsencrypt"
  - "traefik.http.services.<nome>.loadbalancer.server.port=<porta_container>"
```

**Esempio**: un'app Next.js che ascolta sulla porta 3000:

```yaml
services:
  frontend:
    image: cinebase-frontend:latest
    container_name: cinebase-web
    restart: unless-stopped
    networks:
      - traefik-net
      - internal
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.cinebase.rule=Host(`cinebase.miodominio.com`)"
      - "traefik.http.routers.cinebase.entrypoints=websecure"
      - "traefik.http.routers.cinebase.tls.certresolver=letsencrypt"
      - "traefik.http.services.cinebase.loadbalancer.server.port=3000"
```

Ogni `<nome>` deve essere **univoco** tra tutti i progetti in esecuzione. Consiglio: usa il nome del progetto come prefisso (`cinebase-frontend`, `cinebase-strapi`, `blog-web`, ecc.).

---

## Caso 2 – Più container nello stesso progetto (es. frontend + API + database)

Traefik espone solo i container con `traefik.enable=true`. Il database non va esposto:

```yaml
services:
  frontend:
    # ... label Traefik per cinebase.miodominio.com ...
    networks: [traefik-net, internal]

  strapi:
    container_name: cinebase-strapi
    networks: [internal]      # ← NO traefik-net, NO label
    # ... (raggiungibile solo dal frontend sulla rete internal)

  postgres:
    container_name: cinebase-db
    networks: [internal]      # ← mai esposto a internet
    # ...
    volumes:
      - ./pgdata:/var/lib/postgresql/data

networks:
  internal:                   # rete isolata interna al progetto
    driver: bridge
  traefik-net:
    external: true            # rete condivisa con Traefik
```

Solo il container che serve traffico HTTP va su `traefik-net`. Gli altri restano sulla rete interna del progetto.

---

## Caso 3 – Due domini che puntano allo stesso container

Stessa app raggiungibile da due domini diversi:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.app-dominio1.rule=Host(`dominio1.com`)"
  - "traefik.http.routers.app-dominio1.entrypoints=websecure"
  - "traefik.http.routers.app-dominio1.tls.certresolver=letsencrypt"
  - "traefik.http.routers.app-dominio2.rule=Host(`dominio2.com`)"
  - "traefik.http.routers.app-dominio2.entrypoints=websecure"
  - "traefik.http.routers.app-dominio2.tls.certresolver=letsencrypt"
  - "traefik.http.services.app.loadbalancer.server.port=3000"
```

Due router dichiarati (`app-dominio1`, `app-dominio2`), un solo service (`app`). Traefik genera due certificati distinti.

---

## Caso 4 – Path-based routing (dominio.com/app1, dominio.com/app2)

Più app sullo stesso dominio, smistate per percorso:

```yaml
# App A: miodominio.com/app-a
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.app-a.rule=Host(`miodominio.com`) && PathPrefix(`/app-a`)"
  - "traefik.http.routers.app-a.entrypoints=websecure"
  - "traefik.http.routers.app-a.tls.certresolver=letsencrypt"
  - "traefik.http.routers.app-a.middlewares=strip-app-a"
  - "traefik.http.middlewares.strip-app-a.stripprefix.prefixes=/app-a"
  - "traefik.http.services.app-a.loadbalancer.server.port=3000"

# App B: miodominio.com/app-b
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.app-b.rule=Host(`miodominio.com`) && PathPrefix(`/app-b`)"
  - "traefik.http.routers.app-b.entrypoints=websecure"
  - "traefik.http.routers.app-b.tls.certresolver=letsencrypt"
  - "traefik.http.routers.app-b.middlewares=strip-app-b"
  - "traefik.http.middlewares.strip-app-b.stripprefix.prefixes=/app-b"
  - "traefik.http.services.app-b.loadbalancer.server.port=4000"
```

Il middleware `stripprefix` rimuove `/app-a` dall'URL prima di inoltrare la richiesta all'app (così l'app riceve `/` invece di `/app-a`).

---

## Caso 5 – Proteggere un'app con basic auth (password)

Aggiungi questa label al container:

```yaml
labels:
  - "traefik.http.routers.miapp.middlewares=miapp-auth"
  - "traefik.http.middlewares.miapp-auth.basicauth.users=utente:$$2y$$05$$HashedPassword..."
```

La password si genera con:
```bash
echo $(htpasswd -nbB utente "password") | sed -e s/\\$/\\$\\$/g
```

Utile per staging, ambienti di test, o dashboard amministrative che non devono essere pubbliche.

---

## Caso 6 – IP whitelist (accedi solo da certi IP)

```yaml
labels:
  - "traefik.http.routers.miapp.middlewares=ipwhitelist"
  - "traefik.http.middlewares.ipwhitelist.ipwhitelist.sourcerange=1.2.3.4/32,10.0.0.0/8"
```

Tutto il traffico da IP non inclusi riceve `403 Forbidden`. Perfetto per app interne, amministrazione, o API protette.

---

## Caso 7 – Rate limiting (anti-abuso su API pubbliche)

```yaml
labels:
  - "traefik.http.routers.api.middlewares=ratelimit"
  - "traefik.http.middlewares.ratelimit.ratelimit.average=100"
  - "traefik.http.middlewares.ratelimit.ratelimit.period=1m"
  - "traefik.http.middlewares.ratelimit.ratelimit.burst=20"
```

Limita a 100 richieste al minuto in media, con picco massimo di 20 extra. Oltre queste soglie, Traefik risponde `429 Too Many Requests`.

---

## Caso 8 – Redirect (vecchio dominio → nuovo dominio)

Aggiungi un router dedicato con middleware di redirect:

```yaml
labels:
  - "traefik.http.routers.vecchio-dominio.rule=Host(`vecchiodominio.com`)"
  - "traefik.http.routers.vecchio-dominio.entrypoints=websecure"
  - "traefik.http.routers.vecchio-dominio.tls.certresolver=letsencrypt"
  - "traefik.http.routers.vecchio-dominio.middlewares=redirect-nuovo"
  - "traefik.http.middlewares.redirect-nuovo.redirectregex.regex=^https?://vecchiodominio.com/(.*)"
  - "traefik.http.middlewares.redirect-nuovo.redirectregex.replacement=https://nuovodominio.com/$${1}"
  - "traefik.http.middlewares.redirect-nuovo.redirectregex.permanent=true"
```

Anche il vecchio dominio ottiene il certificato (così il redirect HTTPS funziona).

---

## Caso 9 – Aggiungere header di sicurezza a tutte le app

Invece di ripetere le label su ogni container, definisci un middleware condiviso in `~/docker/traefik/config/security-headers.yml`:

```yaml
http:
  middlewares:
    security-headers:
      headers:
        frameDeny: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
        customFrameOptionsValue: "SAMEORIGIN"
```

Poi in ogni container aggiungi solo:
```yaml
labels:
  - "traefik.http.routers.miapp.middlewares=security-headers@file"
```

`@file` indica a Traefik che il middleware è definito nel provider file (config dinamica), non nelle label.

---

## Caso 10 – Compressione gzip sulle risposte

Middleware da aggiungere in `~/docker/traefik/config/gzip.yml`:

```yaml
http:
  middlewares:
    gzip:
      compress: {}
```

E lo richiami dal container: `traefik.http.routers.miapp.middlewares=gzip@file`

---

## Tabella riepilogativa label

| Funzione | Label |
|----------|-------|
| Abilitare Traefik | `traefik.enable=true` |
| Dominio | `traefik.http.routers.X.rule=Host(\`dominio.com\`)` |
| HTTPS + certificato | `traefik.http.routers.X.tls.certresolver=letsencrypt` |
| Porta del container | `traefik.http.services.X.loadbalancer.server.port=3000` |
| Path routing | `...rule=Host(...) && PathPrefix(\`/app\`)` |
| Strip prefix | `traefik.http.middlewares.X.stripprefix.prefixes=/app` |
| Basic auth | `traefik.http.middlewares.X.basicauth.users=...` |
| IP whitelist | `traefik.http.middlewares.X.ipwhitelist.sourcerange=...` |
| Rate limit | `traefik.http.middlewares.X.ratelimit.average=...` |
| Redirect | `traefik.http.middlewares.X.redirectregex.regex=...` |
| Header sicurezza | `...middlewares=security-headers@file` |
| Compressione | `...middlewares=gzip@file` |
