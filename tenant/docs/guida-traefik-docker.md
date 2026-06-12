# Guida: Traefik + Portainer + docker-compose multipli su ARM Ubuntu

Server target: **Ampere ARM64 (aarch64)**, Ubuntu 24.04 LTS, 4 OCPU / 24 GB RAM.

---

## 1. Installare Docker e Docker Compose su ARM64

```bash
# Rimuovi vecchie versioni (se presenti)
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null

# Installa dipendenze
sudo apt update && sudo apt install -y ca-certificates curl

# Aggiungi la chiave GPG ufficiale Docker
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Aggiungi il repository (multi-arch, supporta ARM64)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Installa Docker Engine + Compose plugin
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Aggiungi il tuo utente al gruppo docker (evita sudo ogni volta)
sudo usermod -aG docker $USER

# Esci e rientra dalla sessione SSH perché il gruppo abbia effetto
exit
# poi riconnettiti
```

Verifica:
```bash
docker --version         # Docker version 28.x.x
docker compose version   # Docker Compose version v2.x.x
docker run --rm hello-world
```

---

## 2. Struttura delle directory

```
/home/ubuntu/docker/
├── traefik/                  ← infrastruttura condivisa
│   ├── docker-compose.yml
│   ├── traefik.yml           ← config statica Traefik
│   └── config/               ← config dinamica (certificati, middleware)
├── portainer/                ← interfaccia grafica
│   └── docker-compose.yml
├── progetto-1/               ← ogni progetto ha il suo docker-compose
│   └── docker-compose.yml
├── progetto-2/
│   └── docker-compose.yml
└── ...
```

Crea la struttura:
```bash
mkdir -p ~/docker/{traefik/config,traefik/certificates,portainer}
```

---

## 3. Traefik – reverse proxy e certificati automatici

### 3.1 File di configurazione statica

Crea `~/docker/traefik/traefik.yml`:

```yaml
global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: tua-email@esempio.com        # <-- CAMBIA QUI
      storage: /certificates/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-net
```

### 3.2 Docker Compose per Traefik

Crea `~/docker/traefik/docker-compose.yml`:

```yaml
services:
  traefik:
    image: traefik:v3.6
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/traefik.yml:ro
      - ./config:/config
      - ./certificates:/certificates
    networks:
      - traefik-net

networks:
  traefik-net:
    name: traefik-net
    external: false
```

### 3.3 Avviare Traefik

```bash
cd ~/docker/traefik
docker compose up -d
```

Verifica che sia attivo: `docker ps | grep traefik`

### 3.4 Accesso alla dashboard (solo IP, protetta con basic auth)

Prima genera la password per la basic auth:
```bash
sudo apt install -y apache2-utils
echo $(htpasswd -nbB admin "tua-password-sicura") | sed -e s/\\$/\\$\\$/g
```

Copia l'output (es. `admin:$$2y$05$...`).

Aggiungi al file `~/docker/traefik/traefik.yml` sotto `api:`:

```yaml
api:
  dashboard: true
  insecure: false
```

Poi in ogni docker-compose che espone Traefik stesso... In realtà per la dashboard di Traefik creiamo un file di configurazione dinamica.

Crea `~/docker/traefik/config/dashboard.yml`:

```yaml
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - "admin:$$2y$05$HABC123..."   # <-- incolla qui l'output di htpasswd
  routers:
    dashboard:
      rule: "Host(`traefik.tuo-dominio.com`)"   # <-- CAMBIA con un tuo dominio
      service: api@internal
      middlewares:
        - dashboard-auth
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
```

Ora modifica `~/docker/traefik/traefik.yml`, aggiungi un provider file:

```yaml
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-net
  file:
    directory: /config
    watch: true
```

Riavvia Traefik: `docker compose -f ~/docker/traefik/docker-compose.yml restart`.

---

## 4. Portainer – interfaccia grafica per Docker

Crea `~/docker/portainer/docker-compose.yml`:

```yaml
services:
  portainer:
    image: portainer/portainer-ce:2.39.3-alpine
    container_name: portainer
    restart: unless-stopped
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(`portainer.tuo-dominio.com`)"   # <-- CAMBIA
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  traefik-net:
    external: true
```

Avvia:
```bash
cd ~/docker/portainer && docker compose up -d
```

Prima visita su `https://portainer.tuo-dominio.com` crea l'utente admin e scegli "Local environment".

---

## 5. Progetto di esempio – web app isolata

Crea `~/docker/progetto-esempio/docker-compose.yml`:

```yaml
services:
  web:
    image: nginxdemos/nginx-hello:latest
    container_name: esempio-web
    restart: unless-stopped
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.esempio.rule=Host(`esempio.tuo-dominio.com`)"   # <-- CAMBIA
      - "traefik.http.routers.esempio.entrypoints=websecure"
      - "traefik.http.routers.esempio.tls.certresolver=letsencrypt"
      - "traefik.http.services.esempio.loadbalancer.server.port=8080"

networks:
  traefik-net:
    external: true
```

Avvia:
```bash
cd ~/docker/progetto-esempio && docker compose up -d
```

Visita `https://esempio.tuo-dominio.com` — Traefik ha già generato il certificato.

---

## 6. Aggiungere un nuovo progetto – checklist

1. Crea la directory: `mkdir -p ~/docker/nuovo-progetto`
2. Scrivi il `docker-compose.yml` del progetto (con reti e volumi propri)
3. Aggiungi il network esterno `traefik-net`
4. Aggiungi le label Traefik per dominio e certificato
5. Assicurati che il dominio punti all'IP del server (record A nel DNS)
6. Avvia: `cd ~/docker/nuovo-progetto && docker compose up -d`

---

## 7. Comandi utili

```bash
# Vedere tutti i container in esecuzione
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Vedere i log di un container
docker logs -f --tail 50 traefik

# Riavviare un progetto
cd ~/docker/progetto-esempio && docker compose restart

# Aggiornare un progetto (ricrea i container con l'immagine più recente)
cd ~/docker/progetto-esempio && docker compose pull && docker compose up -d

# Fermare un progetto
cd ~/docker/progetto-esempio && docker compose down

# Vedere tutti i volumi e reti creati
docker volume ls && docker network ls

# Verificare i certificati Let's Encrypt
docker exec traefik ls -la /certificates/
```

---

## 8. DNS e domini

Prima di esporre qualsiasi servizio:

1. Apri il pannello DNS del tuo provider di domini
2. Crea un record **A** che punti all'IP pubblico del server (`<IP_SERVER>`)
3. Per ogni nuova app, aggiungi un record A con lo stesso IP (es. `esempio -> <IP_SERVER>`) oppure un record CNAME che punti al dominio principale
4. Aspetta la propagazione DNS (1-10 minuti, verifica con `nslookup esempio.tuo-dominio.com`)
5. Avvia il docker-compose del progetto

Traefik userà la HTTP challenge di Let's Encrypt per validare il dominio e generare il certificato.

---

## 9. Riepilogo architettura

```
                          Internet
                             │
                     ┌───────┴───────┐
                     │   Traefik     │
                     │  :80 / :443   │
                     │  Let's Encrypt│
                     └───┬───┬───┬───┘
                         │   │   │
             ┌───────────┘   │   └─────────────┐
             ▼               ▼                 ▼
    ┌────────────┐  ┌────────────┐   ┌────────────┐
    │ cinebase   │  │ progetto-2 │   │ progetto-3 │
    │ (isolato)  │  │ (isolato)  │   │ (isolato)  │
    └────────────┘  └────────────┘   └────────────┘
    docker-compose  docker-compose   docker-compose
    proprio         proprio          proprio

              Portainer (https://portainer.dominio)
              └─ interfaccia web per gestire tutto
```

Ogni progetto:
- Ha la sua rete Docker interna (isolamento)
- Si aggancia a `traefik-net` solo per l'accesso HTTP
- Ha volumi e dipendenze (db, cache) propri
- Si gestisce indipendentemente (avvio/stop/aggiornamento)
