# Guida operativa: Server DevOps completo su ARM Ubuntu 24.04

**Target**: `<NOME_SERVER>` — ARM Ampere A1, 4 OCPU, 24 GB RAM, Ubuntu 24.04.4 LTS, IP `<IP_SERVER>`.

Obiettivo: trasformare il server in una piattaforma completa con reverse proxy HTTPS, registry privato, forge Git + CI/CD e capacità di ospitare più progetti dockerizzati isolati.

---

## Indice

1. [Prerequisiti e preparazione](#1-prerequisiti-e-preparazione)
2. [Installare Docker su ARM64](#2-installare-docker-su-arm64)
3. [Struttura directory](#3-struttura-directory)
4. [Traefik — reverse proxy + certificati](#4-traefik--reverse-proxy--certificati)
5. [Portainer — interfaccia grafica](#5-portainer--interfaccia-grafica)
6. [Docker Registry privato](#6-docker-registry-privato)
7. [Forgejo — Git + Issues + PR + CI/CD](#7-forgejo--git--issues--pr--cicd)
8. [Netdata — monitoring infrastruttura](#8-netdata--monitoring-infrastruttura)
9. [Progetti docker-compose multipli](#9-progetti-docker-compose-multipli)
10. [Backup automatico su OCI Object Storage](#10-backup-automatico-su-oci-object-storage)
11. [Architettura finale e comandi utili](#11-architettura-finale-e-comandi-utili)

---

## 1. Prerequisiti e preparazione

### 1.1 DNS

Prima di iniziare, configura questi record A nei DNS del tuo dominio (tutti puntano a `<IP_SERVER>`):

| Sottodominio | Servizio |
|---|---|
| `traefik.<DOMINIO>` | Dashboard Traefik |
| `portainer.<DOMINIO>` | Portainer |
| `monitor.<DOMINIO>` | Netdata (monitoring) |
| `registry.<DOMINIO>` | Docker Registry |
| `registry-ui.<DOMINIO>` | Docker Registry UI (opzionale) |
| `git.<DOMINIO>` | Forgejo |
| `cinebase.<DOMINIO>` | Progetto CineBase |
| `api.cinebase.<DOMINIO>` | API CineBase |
| `*.<DOMINIO>` | (consigliato) Wildcard per futuri progetti |

### 1.2 Connettersi al server

```bash
ssh -i ./<NOME_CHIAVE_SSH> ubuntu@<IP_SERVER>
```

### 1.3 Mantenere viva la connessione SSH

Di default Ubuntu chiude le sessioni inattive dopo pochi minuti. Ecco come evitarlo.

#### Lato client (consigliato)

Aggiungi a `~/.ssh/config` sulla tua macchina:

```
Host <IP_SERVER>
    ServerAliveInterval 60
    ServerAliveCountMax 10
```

Così il client invia un keepalive ogni 60 secondi e tollera fino a 10 mancate risposte (~10 minuti di inattività).

#### Lato server (se serve aumentare il timeout per tutti)

```bash
sudo sed -i 's/^#ClientAliveInterval.*/ClientAliveInterval 120/' /etc/ssh/sshd_config
sudo sed -i 's/^#ClientAliveCountMax.*/ClientAliveCountMax 6/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

Questo porta il timeout lato server a 12 minuti (120s × 6). Su Ubuntu 24.04 il servizio si chiama `ssh`, **non** `sshd`.

#### Evitare la passphrase a ogni connessione (ssh-agent)

Su Windows (PowerShell):

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add "C:\Users\TuoUtente\.ssh\tua-chiave"
```

Su Linux/macOS:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/tua-chiave
```

Inserisci la passphrase una volta sola per sessione.

### 1.4 Pacchetti di sistema

```bash
sudo apt update && sudo apt install -y ca-certificates curl apache2-utils jq
```

---

## 2. Installare Docker su ARM64

```bash
# Rimuovi vecchie versioni
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null

# Aggiungi repository Docker
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Installa
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Aggiungi utente al gruppo docker
sudo usermod -aG docker $USER
```

**Esci e rientra** dalla sessione SSH per applicare il gruppo docker.

Verifica:
```bash
docker --version         # Docker version 28+
docker compose version   # Docker Compose version v2+
docker run --rm hello-world
```

---

## 3. Struttura directory

```bash
mkdir -p ~/docker/{traefik/{config,certificates},portainer,registry/{data,auth},forgejo/{data,runner1/data,runner2/data},postgres/data,netdata/{config,lib,cache}}
```

Struttura completa che otterremo:

```
~/docker/
├── traefik/
│   ├── docker-compose.yml
│   ├── traefik.yml
│   ├── config/
│   │   ├── dashboard.yml
│   │   ├── middleware-registry-ui.yml
│   │   └── middleware-netdata.yml
│   └── certificates/
├── portainer/
│   └── docker-compose.yml
├── netdata/
│   ├── docker-compose.yml
│   └── config/
├── registry/
│   ├── docker-compose.yml       # include registry + registry-ui (profilo "ui")
│   ├── auth/htpasswd
│   └── data/
├── forgejo/
│   ├── docker-compose.yml
│   ├── data/
│   ├── runner1/
│   └── runner2/
├── cinebase/
│   └── docker-compose.yml
├── blog-personale/
│   └── docker-compose.yml
├── deploy.sh
└── backup.sh
```

---

## 4. Traefik — reverse proxy + certificati

### 4.1 Configurazione statica

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
      email: tua-email@esempio.com          # <-- CAMBIA
      storage: /certificates/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik-net
  file:
    directory: /config
    watch: true
```

### 4.2 Password per dashboard Traefik

```bash
echo $(htpasswd -nbB admin "TuaPasswordSicura123") | sed -e s/\\$/\\$\\$/g
# Copia l'output (admin:$$2y$$05$$...)
```

Crea `~/docker/traefik/config/dashboard.yml`:

```yaml
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - "admin:$$2y$$05$$HABC123..."    # <-- incolla output htpasswd
  routers:
    dashboard:
      rule: "Host(`traefik.<DOMINIO>`)"  # <-- CAMBIA dominio
      service: api@internal
      middlewares:
        - dashboard-auth
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
```

### 4.3 Docker Compose

Crea `~/docker/traefik/docker-compose.yml`:

```yaml
services:
  traefik:
    image: traefik:v3.7.4
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

### 4.4 Avvio

```bash
cd ~/docker/traefik
docker compose up -d
docker ps | grep traefik
curl -s https://traefik.<DOMINIO> | head -5
```

---

## 5. Portainer — interfaccia grafica

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
      - "traefik.http.routers.portainer.rule=Host(`portainer.<DOMINIO>`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  traefik-net:
    external: true
```

Avvio:
```bash
cd ~/docker/portainer && docker compose up -d
```

Prima visita su `https://portainer.<DOMINIO>`: crea utente admin, scegli **Get Started** → ambiente locale.

### 5.1 Aggiungere il Registry privato a Portainer

Dopo aver configurato il registry (script 06), aggiungilo a Portainer per poter deployare immagini dal registry privato:

1. Vai su **Registries** → **Add registry**
2. Seleziona **Custom registry**
3. Compila:
   - ****Name**: `<NOME_REGISTRY>`
   - **Registry URL**: `registry.<DOMINIO>`
   - **Authentication**: attiva
   - **Username**: l'utente htpasswd del registry
   - **Password**: la password htpasswd del registry

Da ora, quando crei un container in Portainer, puoi specificare l'immagine come `registry.<DOMINIO>/progetto/web:latest` e selezionare il registry `<NOME_REGISTRY>` dal menu a tendina.

> **Nota**: Portainer CE (Community Edition) mostra alcune funzionalità etichettate come "Business Edition". Il supporto ai registry privati è incluso nella versione gratuita.

---

## 6. Docker Registry privato

### 6.1 Autenticazione

```bash
htpasswd -Bc ~/docker/registry/auth/htpasswd tuo-utente
# Inserisci password due volte
```

### 6.2 Docker Compose

Crea `~/docker/registry/docker-compose.yml`:

```yaml
services:
  registry:
    image: registry:3.1.1
    container_name: registry
    restart: unless-stopped
    networks:
      - traefik-net
    volumes:
      - ./data:/var/lib/registry
      - ./auth/htpasswd:/auth/htpasswd:ro
    environment:
      - REGISTRY_AUTH=htpasswd
      - REGISTRY_AUTH_HTPASSWD_REALM=Registry
      - REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
      - REGISTRY_HTTP_ADDR=0.0.0.0:5000
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry.rule=Host(`registry.<DOMINIO>`)"
      - "traefik.http.routers.registry.entrypoints=websecure"
      - "traefik.http.routers.registry.tls.certresolver=letsencrypt"
      - "traefik.http.services.registry.loadbalancer.server.port=5000"

  registry-ui:
    image: joxit/docker-registry-ui:2.6.0
    container_name: registry-ui
    restart: unless-stopped
    profiles:
      - ui                         # non parte automaticamente
    networks:
      - traefik-net
    environment:
      - REGISTRY_TITLE=Docker Registry
      - DELETE_IMAGES=true
      - SINGLE_REGISTRY=true
      - NGINX_PROXY_PASS_URL=http://registry:5000
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry-ui.rule=Host(`registry-ui.<DOMINIO>`)"
      - "traefik.http.routers.registry-ui.entrypoints=websecure"
      - "traefik.http.routers.registry-ui.tls.certresolver=letsencrypt"
      - "traefik.http.routers.registry-ui.middlewares=registry-ui-auth@file"
      - "traefik.http.services.registry-ui.loadbalancer.server.port=80"

networks:
  traefik-net:
    external: true
```

> **Profilo `ui`**: la registry UI non parte con `docker compose up -d` normale. Va attivata esplicitamente (vedi §6.4).

### 6.3 Middleware autenticazione UI

La UI usa lo stesso file htpasswd del registry. Crea `~/docker/traefik/config/middleware-registry-ui.yml`:

```yaml
http:
  middlewares:
    registry-ui-auth:
      basicAuth:
        users:
          - "tuo-utente:$2y$05$HABC123..."  # incolla la riga da ~/docker/registry/auth/htpasswd
```

Traefik ricarica automaticamente il file (`watch: true` sulla directory `/config`).

### 6.4 Attivare / Disattivare la UI

```bash
cd ~/docker/registry

# Attivare
docker compose --profile ui up -d registry-ui

# Disattivare (non rimuove il container, solo lo ferma)
docker compose --profile ui stop registry-ui

# Rimuovere del tutto
docker compose --profile ui down registry-ui
```

Senza `--profile ui`, i normali comandi `docker compose up/down/ps` ignorano completamente la UI.

---

## 7. Forgejo — Git + Issues + PR + CI/CD

> **Documentazione ufficiale**:
> - [Installazione Docker](https://forgejo.org/docs/next/admin/installation/docker/)
> - [Runner Docker](https://forgejo.org/docs/next/admin/actions/installation/docker/)
> - [Registrazione runner](https://forgejo.org/docs/next/admin/actions/registration/)
> - [Docker dentro i workflow](https://forgejo.org/docs/next/admin/actions/docker-access/)

### 7.1 Directory dati runner

I runner v12 girano come utente non-root (`1001:1001`). Le directory dati devono appartenere a questo utente, e il container deve essere nel gruppo `docker` dell'host per accedere al socket:

```bash
DOCKER_GID=$(getent group docker | cut -d: -f3)
mkdir -p ~/docker/forgejo/runner{1,2}/data
sudo chown -R 1001:1001 ~/docker/forgejo/runner{1,2}/data
chmod 775 ~/docker/forgejo/runner{1,2}/data
chmod g+s ~/docker/forgejo/runner{1,2}/data
echo "Docker GID: $DOCKER_GID"
```

### 7.2 Docker Compose

Crea `~/docker/forgejo/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16-alpine
    container_name: forgejo-db
    restart: unless-stopped
    networks:
      - forgejo-internal
    environment:
      - POSTGRES_USER=forgejo
      - POSTGRES_PASSWORD=ForgejoDbP4ssw0rd!
      - POSTGRES_DB=forgejo
    volumes:
      - ../postgres/data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U forgejo"]
      interval: 10s
      timeout: 5s
      retries: 5

  forgejo:
    image: codeberg.org/forgejo/forgejo:15
    container_name: forgejo
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - forgejo-internal
      - traefik-net
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - FORGEJO__database__DB_TYPE=postgres
      - FORGEJO__database__HOST=postgres:5432
      - FORGEJO__database__NAME=forgejo
      - FORGEJO__database__USER=forgejo
      - FORGEJO__database__PASSWD=ForgejoDbP4ssw0rd!
      - FORGEJO__server__DOMAIN=git.<DOMINIO>
      - FORGEJO__server__ROOT_URL=https://git.<DOMINIO>
      - FORGEJO__server__SSH_DOMAIN=git.<DOMINIO>
      - FORGEJO__server__SSH_PORT=2222
      - FORGEJO__actions__ENABLED=true
      - FORGEJO__service__DISABLE_REGISTRATION=true
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "2222:22"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.forgejo.rule=Host(`git.<DOMINIO>`)"
      - "traefik.http.routers.forgejo.entrypoints=websecure"
      - "traefik.http.routers.forgejo.tls.certresolver=letsencrypt"
      - "traefik.http.services.forgejo.loadbalancer.server.port=3000"

  runner1:
    image: data.forgejo.org/forgejo/runner:12
    container_name: forgejo-runner1
    restart: unless-stopped
    depends_on:
      - forgejo
    networks:
      - forgejo-internal
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./runner1/data:/data
    user: "1001:1001"
    group_add:
      - "${DOCKER_GID}"             # GID del gruppo docker sull'host, rilevato con getent
    command: 'forgejo-runner daemon --config /data/runner-config.yml'

  runner2:
    image: data.forgejo.org/forgejo/runner:12
    container_name: forgejo-runner2
    restart: unless-stopped
    depends_on:
      - forgejo
    networks:
      - forgejo-internal
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./runner2/data:/data
    user: "1001:1001"
    group_add:
      - "${DOCKER_GID}"
    command: 'forgejo-runner daemon --config /data/runner-config.yml'

networks:
  forgejo-internal:
    driver: bridge
  traefik-net:
    external: true
```

> **Versioni**: Forgejo 15 (ultima stabile), Runner 12 (ultimo). Per Forgejo 16 (next) usare `forgejo:16`.
>
> **Nota SSH**: Forgejo ascolta SSH su porta 2222 (la 22 è già usata dal server). Per clonare via SSH: `git clone ssh://git@git.<DOMINIO>:2222/utente/repo.git`
>
> **Registro runner**: L'immagine runner ufficiale è su `data.forgejo.org` (non `code.forgejo.org`). Se irraggiungibile, usare `code.forgejo.org/forgejo/runner:12`.

### 7.3 Reinstallazione pulita (solo se necessario)

Se devi ripartire da zero (es. aggiornare da una versione precedente):

```bash
cd ~/docker/forgejo
docker compose down -v           # ferma container e rimuove volumi
sudo rm -rf ~/docker/forgejo ~/docker/postgres
```

Poi esegui lo script `07-setup-forgejo.sh` che ricrea tutto da zero. **Attenzione**: questo cancella tutti i repo Git, utenti, issue e dati Forgejo.

### 7.4 Avvio e configurazione iniziale

```bash
cd ~/docker/forgejo && docker compose up -d postgres forgejo
```

Visita `https://git.<DOMINIO>`, togli la spunta a **Disable Self-Registration**, clicca **Installa Forgejo**, e registra il primo utente (sarà admin automaticamente).

### 7.5 Registrazione runner

Il comando `forgejo-runner register` è **deprecato**. La registrazione ufficiale avviene via `forgejo forgejo-cli actions register` da dentro il container Forgejo, oppure via UI. Il metodo CLI è più affidabile per l'automazione.

```bash
# Genera un secret da 40 caratteri hex e registra runner1
RUNNER1_SECRET=$(openssl rand -hex 20)
RUNNER1_UUID=$(docker exec -u 1000:1000 forgejo forgejo forgejo-cli actions register \
  --name runner1 \
  --secret "$RUNNER1_SECRET")
echo "runner1 UUID: $RUNNER1_UUID"

# Stessa cosa per runner2
RUNNER2_SECRET=$(openssl rand -hex 20)
RUNNER2_UUID=$(docker exec -u 1000:1000 forgejo forgejo forgejo-cli actions register \
  --name runner2 \
  --secret "$RUNNER2_SECRET")
echo "runner2 UUID: $RUNNER2_UUID"
```

Poi crea `~/docker/forgejo/runner1/data/runner-config.yml` con UUID e token:

```yaml
log:
  level: info

runner:
  file: .runner
  capacity: 1
  labels:
    - ubuntu-latest:docker://node:22-bookworm

container:
  docker_host: "automount"

host:
  workdir_parent: /tmp

server:
  connections:
    forgejo:
      url: https://git.<DOMINIO>
      uuid: <RUNNER1_UUID>    # <-- incolla UUID runner1
      token: <RUNNER1_SECRET>  # <-- incolla secret
```

> `automount` condivide automaticamente il socket Docker dell'host (`/var/run/docker.sock`) con i container dei job, permettendo ai workflow di usare `docker build`, `docker push`, ecc. È l'approccio più semplice per un server singolo. Per ambienti multi-tenant, considera [Docker-in-Docker](https://forgejo.org/docs/next/admin/actions/docker-access/#docker-in-docker).

Copia la config per runner2 (cambiando UUID e token) e avvia:

```bash
docker compose up -d runner1 runner2
```

Verifica su **Site Administration → Actions → Runners**: entrambi i runner devono apparire con pallino verde (online).

### 7.6 Workflow di esempio per i progetti

Crea `.forgejo/workflows/ci.yml` in qualsiasi repo:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Install dependencies
        run: npm ci

      - name: Run tests
        run: npm test

      - name: Build and push Docker image
        if: github.ref == 'refs/heads/main'
        run: |
          docker build -t registry.<DOMINIO>/progetto/app:latest .
          docker push registry.<DOMINIO>/progetto/app:latest
```

> **⚠️ Nota**: I workflow che usano `docker` o deploy via SSH richiedono configurazione aggiuntiva (Docker CLI, SSH client, secret). Vedi la **[Guida completa CI/CD Forgejo Actions](guida-cicd-forgejo-actions.md)** per tutti i dettagli su runner, workflow, errori comuni e setup chiave SSH.

---

## 8. Netdata — monitoring infrastruttura

Netdata monitora CPU, RAM, dischi, rete e container Docker in tempo reale con dashboard web e allarmi configurabili. Scoperta automatica dei container, storico delle metriche, notifiche Telegram.

**RAM**: ~200-300 MB. **Container**: 1.

### 8.1 Docker Compose

Crea `~/docker/netdata/docker-compose.yml`:

```yaml
services:
  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    restart: unless-stopped
    hostname: s1
    pid: host
    cap_add:
      - SYS_PTRACE
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./config:/etc/netdata
      - ./lib:/var/lib/netdata
      - ./cache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - NETDATA_CLAIM_TOKEN=            # opzionale, per Netdata Cloud
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.netdata.rule=Host(`monitor.<DOMINIO>`)"
      - "traefik.http.routers.netdata.entrypoints=websecure"
      - "traefik.http.routers.netdata.tls.certresolver=letsencrypt"
      - "traefik.http.services.netdata.loadbalancer.server.port=19999"
      - "traefik.http.routers.netdata.middlewares=netdata-auth@file"

volumes:
  lib:
  cache:

networks:
  traefik-net:
    external: true
```

> **Nota sui volumi**: Netdata ha bisogno di accesso a `/proc`, `/sys` e al socket Docker per raccogliere metriche di sistema e container. Le capability `SYS_PTRACE` e `SYS_ADMIN` sono necessarie per monitorare i processi. La dashboard è protetta da basic auth via file provider Traefik.

### 8.2 Password basic auth (file provider)

La password non va nelle label Docker Compose (causa bug `$$` con bcrypt). Si usa un file provider Traefik, come per la dashboard e la registry UI.

Crea `~/docker/traefik/config/middleware-netdata.yml`:

```bash
# Genera l'hash
HASH=$(printf '%s' "TuaPasswordSicura" | htpasswd -nB -i admin)

# Crea il file provider (senza $$ escaping)
cat > ~/docker/traefik/config/middleware-netdata.yml << EOF
http:
  middlewares:
    netdata-auth:
      basicAuth:
        users:
          - "$HASH"
EOF
```

La label nel docker-compose usa `netdata-auth@file` (riferimento al middleware, nessun `$` nel valore).

### 8.3 Notifiche Telegram

1. Su Telegram, cerca **[@BotFather](https://t.me/BotFather)** e scrivi `/newbot`
2. Segui le istruzioni (nome e username del bot). Alla fine ricevi un **token** (es. `123456:ABC-DEF...`)
3. Verifica che il token sia valido: `https://api.telegram.org/bot<IL-TUO-TOKEN>/getMe`
4. Cerca il tuo bot su Telegram e scrivigli `/start` (o un messaggio qualsiasi)
5. Ottieni il **chat_id** visitando `https://api.telegram.org/bot<IL-TUO-TOKEN>/getUpdates` — il valore è nel JSON sotto `"chat"` → `"id"` (es. `<CHAT_ID>`)
6. Inserisci i valori in `.env` e aggiorna `.env.example`:
   ```bash
   TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
   TELEGRAM_CHAT_ID=<CHAT_ID>
   ```
7. Copia `.env` aggiornato sul server e riesegui lo script 08:
   ```bash
   scp -i ${S1_SSH_KEY} tenant/servers/s1/.env ${S1_SSH_USER}@${S1_IP}:~/scripts/
   ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP} "cd ~/scripts && bash 08-setup-netdata.sh"
   ```

Lo script rileva le variabili `.env`, inserisce le env var `NETDATA_HEALTHCHECK_TELEGRAM_*` nel docker-compose e riavvia Netdata.

**Allarmi preconfigurati** (attivi subito): CPU > 80% per 10 min, RAM < 10% libera, disco > 90% pieno, container fermo, servizio down.

### 8.4 Avvio

```bash
cd ~/docker/netdata && docker compose up -d
```

Accesso: `https://monitor.<DOMINIO>` → login basic auth → dashboard.

### 8.5 Autenticazione Netdata v2

Netdata v2 (dalla `stable` v2.10+) mostra una pagina di sign-in interna dopo il basic auth di Traefik. È il comportamento previsto: Netdata Cloud offre un SSO opzionale con funzionalità aggiuntive.

| Senza login (Skip) | Con Netdata Cloud |
|---|---|
| Dashboard locale solo su questo server | Dashboard unificata multi-server |
| Metriche in RAM (persistenza limitata) | Storico metriche su Cloud |
| Allarmi solo via Telegram/email | Allarmi centralizzati su Cloud |
| Nessuna condivisione | Dashboard condivisibili con team |

Per un server singolo, cliccare **"Skip and use the dashboard anonymously"** è più che sufficiente. Il basic auth di Traefik garantisce già la protezione degli accessi. Se in futuro servisse il Cloud, basta reclamare l'agent con `NETDATA_CLAIM_TOKEN`.

### 8.6 Nota: middleware cross-provider in Traefik

Il router Netdata è definito nel provider `docker` (label docker-compose), mentre il middleware `netdata-auth` è nel provider `file` (`middleware-netdata.yml`). Quando router e middleware appartengono a provider **diversi**, il riferimento DEVE includere il suffisso esplicito: `netdata-auth@file`.

Senza `@file`, Traefik cerca il middleware nello stesso provider del router (`docker`), non lo trova, e restituisce `404 page not found`. L'errore nel dashboard Traefik appare come: `middleware "netdata-auth@docker" does not exist`.

**Regola generale**: se router e middleware sono nello stesso provider, il suffisso è opzionale (es. la dashboard Traefik, dove entrambi stanno in `dashboard.yml`). Se sono in provider diversi, il suffisso `@provider` è obbligatorio.

### 8.7 Allarme personalizzato `disk_space_low` (disco generale)

L'allarme monitora lo spazio disco della root partition e scatta quando l'uso supera l'80% (warning) o il 95% (critical). Il file è generato dallo script `08-setup-netdata.sh` in `~/docker/netdata/config/health.d/disk-backup.conf`.

**Configurazione originale e problemi riscontrati:**

| Problema | Causa | Soluzione |
|---|---|---|
| Allarme non visibile nella pagina Alarms | `on: disk_space._` è sintassi v1, non riconosciuta da v2 | `on: disk.space` (contesto corretto v2) |
| `alarm:` vs `template:` | `alarm` richiede un chart ID specifico; `disk.space` è un contesto condiviso da più mount point | `template:` (applica a tutti i chart con contesto `disk.space`) |
| Allarme sempre in WARNING (falso positivo) | `lookup` con `units: GB` e `warn: $used > 20` confronta il valore raw (probabilmente in MB) con GB | `calc: $used * 100 / ($used + $avail)` con `units: %` |
| Errore _"There was an error while fetching alert explanation"_ | Bug del servizio AI di Netdata Cloud (confermato: anche gli alert built-in hanno lo stesso warning) | Non risolvibile lato config; l'alert funziona comunque |

**Configurazione finale corretta:**

```yaml
template: disk_space_low
    on: disk.space
    class: Utilization
    type: Storage
    component: Backup
    calc: $used * 100 / ($used + $avail)
    units: %
    every: 1m
    warn: $this > 80
    crit: $this > 95
    info: Spazio disco usato superiore al 80% (warn) o 95% (crit)
    to: sysadmin
```

**Pattern ufficiale Netdata**: questa configurazione segue l'esempio `disk_full_percent` dalla [documentazione ufficiale Netdata](https://learn.netdata.cloud/docs/alerts-&-notifications/alert-configuration-reference#example-2-disk-space-monitoring). L'uso di `calc` + `$this` nelle condizioni è il metodo raccomandato.

**Ricarica senza riavvio:**
```bash
docker exec netdata netdatacli reload-health
```

### 8.8 Script monitoraggio backup (quota OCI Always Free 10 GB)

La quota **10 GB** non è del disco locale (che è ~100 GB boot volume), ma del **bucket Object Storage OCI** dove vengono caricati i backup. Lo script `check-backup-size.sh` in `~/docker/netdata/` viene eseguito ogni ora via cron e invia alert Telegram quando la dimensione del backup si avvicina al limite.

**Logica dello script:**
1. Se esiste la cartella `~/backup/` con archivi compressi (`*.tar.gz`, `*.zip`), usa la loro dimensione (valore reale)
2. Altrimenti, stima la dimensione dalle directory raw (`~/docker/registry/data`, `~/docker/postgres`, `~/docker/forgejo/data`)
3. Confronta con le soglie: **9 GB warning**, **9.5 GB critical**
4. Se superata, invia un messaggio Telegram via API JSON (per preservare le emoji)

**Come funziona l'invio Telegram con emoji:**

Il problema: quando si esegue `curl` da shell, i caratteri emoji (es. 🟡🔴) vengono persi perché il terminale SSH non supporta UTF-8 completo. La soluzione è usare l'API JSON Telegram, salvando il payload in un file temporaneo:

```bash
# Salva il messaggio JSON in un file (emoji preservate)
printf '{"chat_id":"%s","text":"🔴 CRITICAL: Backup %s"}' "${TELEGRAM_CHAT_ID}" "${LABEL}" > /tmp/telegram_msg.json

# Invia via API JSON
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d @/tmp/telegram_msg.json
```

Il file JSON preserva l'encoding UTF-8, evitando che la shell interpreti (e corroda) gli emoji.

**Soglie e variabili:**
| Soglia | Valore | Azione |
|---|---|---|
| WARNING | 9 GB (9000 MB) | Messaggio Telegram 🟡 |
| CRITICAL | 9.5 GB (9500 MB) | Messaggio Telegram 🔴 |

**Cron:**
```
0 * * * * /home/ubuntu/docker/netdata/check-backup-size.sh
```

Lo script è generato automaticamente da `08-setup-netdata.sh` tramite heredoc. Se modificato nel repository, rieseguire lo script per rigenerarlo sul server.

### 8.9 Test invio messaggio Telegram

**Test diretto con curl:**
```bash
source <(sed 's/\r$//' ~/scripts/.env)
printf '{"chat_id":"%s","text":"🧪 Test messaggio da <NOME_SERVER>"}' "${TELEGRAM_CHAT_ID}" > /tmp/test_msg.json
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d @/tmp/test_msg.json
rm -f /tmp/test_msg.json
```

**Test forzato dell'alert backup:** ridurre temporaneamente la soglia per simulare il superamento:
```bash
# 1. Backup
cp ~/docker/netdata/check-backup-size.sh /tmp/check-backup-size.sh.bak

# 2. Abbassa soglia a 20 MB per forzare WARNING (il backup reale è ~25 MB)
sed -i 's/9000/20/' ~/docker/netdata/check-backup-size.sh

# 3. Esegui — dovresti ricevere il messaggio Telegram
~/docker/netdata/check-backup-size.sh

# 4. Ripristina soglia originale
mv /tmp/check-backup-size.sh.bak ~/docker/netdata/check-backup-size.sh
```

### 8.10 Risoluzione errori comuni

**Errore `middleware "netdata-auth@file@file" does not exist`**
- **Causa**: doppio suffisso `@file` nel label docker-compose. Succede se il `sed` dello script 08 viene eseguito su un file che ha già `@file`.
- **Sintomo**: dashboard Netdata restituisce 404, Traefik log mostra l'errore.
- **Fix:**
  ```bash
  sed -i 's/netdata-auth@file@file/netdata-auth@file/' ~/docker/netdata/docker-compose.yml
  cd ~/docker/netdata && docker compose up -d
  docker restart traefik
  ```

**Errore _"There was an error while fetching alert explanation"_ nella dashboard Netdata**
- **Causa**: bug del servizio AI di Netdata Cloud. Non dipende dalla configurazione dell'alert.
- **Verifica**: cliccare su un alert built-in di Netdata (es. "disk space usage") — se anche quello mostra lo stesso errore, è confermato essere un bug di Netdata Cloud, non della nostra configurazione.
- **Impatto**: nessuno. L'alert funziona e scatta regolarmente. Solo la spiegazione AI non è disponibile.

---

## 9. Progetti docker-compose multipli

### 8.1 Struttura di ogni progetto

```yaml
# ~/docker/nome-progetto/docker-compose.yml
services:
  web:
    image: registry.<DOMINIO>/progetto/web:latest
    container_name: progetto-web
    restart: unless-stopped
    networks:
      - internal
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.progetto.rule=Host(`progetto.<DOMINIO>`)"
      - "traefik.http.routers.progetto.entrypoints=websecure"
      - "traefik.http.routers.progetto.tls.certresolver=letsencrypt"
      - "traefik.http.services.progetto.loadbalancer.server.port=3000"

  db:
    image: postgres:16-alpine
    container_name: progetto-db
    restart: unless-stopped
    networks:
      - internal                                     # ← MAI esposto
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=progetto
      - POSTGRES_PASSWORD=ProgettoP4ss!
      - POSTGRES_DB=progetto

networks:
  internal:
    driver: bridge
  traefik-net:
    external: true
```

### 8.2 Script di deploy

Crea `~/docker/deploy.sh`:

```bash
#!/bin/bash
# Uso: ./deploy.sh <nome-progetto>
PROJECT=$1
if [ -z "$PROJECT" ]; then
  echo "Uso: ./deploy.sh <nome-progetto>"
  exit 1
fi
cd ~/docker/$PROJECT || exit 1
docker compose pull
docker compose up -d
docker image prune -f
echo "Deploy completato: $PROJECT"
```

```bash
chmod +x ~/docker/deploy.sh
```

### 8.3 Aggiungere un nuovo progetto

```bash
mkdir -p ~/docker/nuovo-progetto
vim ~/docker/nuovo-progetto/docker-compose.yml   # copia struttura sopra
cd ~/docker/nuovo-progetto && docker compose up -d
```

Traefik rileva il nuovo container automaticamente e genera il certificato.

---

## 10. Backup automatico su OCI Object Storage

Usiamo l'Object Storage Always Free (10 GB Standard) e l'Instance Principal (il server si autentica automaticamente essendo dentro OCI, senza chiavi).

### 10.1 Creare il bucket (dal PC Windows, dove OCI CLI è configurata)

```powershell
oci os bucket create --name <NOME_BUCKET> --compartment-id <OCID_TENANCY>
```

### 10.2 Configurare Instance Principal sul server

**Sulla console OCI:**

1. **Identity & Security → Dynamic Groups → Create Dynamic Group**
   - Nome: `<NOME_DYNAMIC_GROUP>`
   - Regola: `Any { instance.id = '<OCID_INSTANCE>' }`

2. **Identity & Security → Policies → Create Policy**
   - Nome: `<NOME_POLICY>`
   - Policy:
   ```
   Allow dynamic-group <NOME_DYNAMIC_GROUP> to manage objects in tenancy where target.bucket.name='<NOME_BUCKET>'
   ```
   (In una policy nel root tenancy si usa la keyword `tenancy`, non `compartment <nome-tenancy>`, altrimenti si ottiene l'errore `Compartment {nome} does not exist or is not part of the policy compartment subtree`.)

**Sul server:**

```bash
# Installa OCI CLI (script ufficiale Oracle; lo snap oci-cli è deprecato)
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
hash -r   # ricarica tabella comandi

# Verifica che l'Instance Principal funzioni
oci os object list --bucket-name <NOME_BUCKET> --auth instance_principal
# Dovrebbe restituire {"data": []} (bucket vuoto, OK)
```

### 10.3 Script di backup

**Non creare `~/docker/backup.sh` a mano**: lo script `10-setup-backup.sh` lo genera automaticamente con la versione corretta e aggiornata. Eseguilo sul server dopo aver configurato bucket, Dynamic Group e policy (vedi §10.2):

```bash
bash ~/scripts/10-setup-backup.sh
```

Lo script generato (`~/docker/backup.sh`) fa il backup di:

- PostgreSQL Forgejo (`pg_dumpall` consistente)
- PostgreSQL Analytics Waline+Umami (`pg_dumpall`)
- MariaDB CineBase (`mariadb-dump`)
- Volume `cinebase_*media-uploads` (cover immagini)
- `forgejo/data` (allegati, LFS)
- `registry/auth` (htpasswd)
- `traefik/certificates` (`acme.json`, per evitare rate limit Let's Encrypt)

I file root-only (`acme.json` 0600, dati forgejo di `opc`) sono letti via container Docker helper (gira come root), senza sudo sul server. L'upload avviene via Instance Principal. La retention è gestita dallo script stesso (3 giorni locale, 30 giorni remota).

> **Importante**: la versione precedente di questa guida mostrava un `backup.sh` manuale che includeva `registry/data/` (immagini Docker, ricostruibili dal CI/CD — gonfierebbe il backup) e usava il path errato `postgres/` (quello corretto è `postgres/data/`, ma è comunque sostituito dal dump SQL consistente). Quella versione è **obsoleta e buggata**: usare solo `10-setup-backup.sh`.

### 10.4 Automatizzare con cron

`10-setup-backup.sh` configura già il cron job (`0 3 * * * ~/docker/backup.sh`). Verifica:

```bash
crontab -l | grep backup
```

### 10.5 Ripristino da backup

La procedura completa di restore (download archivio, restore dei singoli DB, restore dei file statici via container helper per preservare i permessi) è documentata in [`guida-backup-oci.md` §11](guida-backup-oci.md). Le operazioni fondamentali:

```bash
# 1. Scarica il backup dal bucket (sostituisci YYYY-MM-DD con la data reale,
#    o usa $(date +%Y-%m-%d) per quello di oggi)
oci os object get --bucket-name <NOME_BUCKET> \
  --name "s1-backup-$(date +%Y-%m-%d).tar.gz" \
  --file /tmp/restore.tar.gz --auth instance_principal

# 2. Estrai
mkdir -p /tmp/restore && tar xzf /tmp/restore.tar.gz -C /tmp/restore

# 3. Restore dei DB e dei file statici: vedi guida-backup-oci.md §11
#    (ogni DB ha la sua procedura, i file statici vanno estratti via container
#    helper per preservare ownership/permessi di acme.json e forgejo/data)
```

---

## 11. Architettura finale e comandi utili

### 11.1 Schema completo

```text
                           Internet
                              │
                     ┌───────┴───────┐
                     │   Traefik     │
                     │  :80 / :443   │
                     │  Dashboard 🔒 │
                     └───┬───┬───┬───┘
                         │   │   │
    ┌────────────────────┘   │   └────────────────────┐
    ▼                        ▼                        ▼
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────┐
│ Portainer│  │ Netdata  │  │ Forgejo  │  │ Progetti (N)     │
│:9000     │  │:19999    │  │:3000     │  │ ciascuno isolato │
└──────────┘  │ Allarmi  │  └────┬─────┘  └──────────────────┘
              │ Telegram │       │
              └──────────┘  ┌────┴─────────┐
                            │ PostgreSQL   │ ────┐
┌──────────┐                │ Runner 1     │     │
│ Registry │                │ Runner 2     │     │  backup notturno
│:5000     │                └──────────────┘     │  (registry + DB Forgejo)
└────┬─────┘                                     │
     │                                           │
     └───────────────────────────────────────────┘
                              │
                     ┌───────┴──────────┐
                     │ OCI Object       │
                     │ Storage          │
                     │ (<NOME_BUCKET>)      │
                     └──────────────────┘
```

#### Cosa include il backup notturno

L'archivio `s1-backup-YYYY-MM-DD.tar.gz` generato da `~/docker/backup.sh` contiene:

| Componente | Strategia | Contenuto |
|---|---|---|
| `forgejo-postgres-YYYYMMDD.sql` | `pg_dumpall` via `docker exec` | DB Forgejo: repo Git, utenti, issue, PR, milestone |
| `analytics-postgres-YYYYMMDD.sql` | `pg_dumpall` via `docker exec` | DB Waline (commenti) + Umami (analytics) |
| `cinebase-mariadb-YYYYMMDD.sql` | `mariadb-dump` via `docker exec` | DB CineBase: catalogo, utenti, ordini |
| `cinebase-media-uploads-YYYYMMDD.tar.gz` | `tar` via container helper | Volume cover immagini CineBase |
| `forgejo-data.tar.gz` | `tar` via container helper | Allegati, avatar, LFS di Forgejo |
| `registry-auth.tar.gz` | `tar` via container helper | htpasswd del registry |
| `traefik-certificates.tar.gz` | `tar` via container helper | `acme.json` (cert Let's Encrypt, evita rate limit) |

I dump SQL sono **consistenti** (snapshot atomico), non copie a caldo dei file. I file statici sono letti via container Docker helper (gira come root) per gestire `acme.json` 0600 di root e i dati di forgejo di proprietà di `opc` — niente sudo sul server.

Dettagli completi di setup, retention e restore in [`guida-backup-oci.md`](guida-backup-oci.md).

#### Cosa **non** include il backup

| Cosa | Perché |
|------|--------|
| `registry/data/` (immagini Docker) | Ricostruibili dal CI/CD ( Forgejo Actions fa build + push a ogni commit) |
| `postgres/data/` raw | Sostituito dal dump SQL consistente (`forgejo-postgres-*.sql`) |
| `forgejo/runner*/data/` | Configurazione runner CI/CD, rigenerabile con `07b-setup-forgejo-runners.sh` |
| File di configurazione di Traefik, Portainer, Netdata | Sono file di testo. Vanno **versionati su Forgejo stesso** così hai storico e puoi ripristinarli clonando il repo |
| Volumi dati di eventuali progetti futuri | Ogni progetto è diverso. Man mano che crei nuovi progetti, **aggiungi i loro volumi critici** a `10-setup-backup.sh` (e ri-eseguilo) oppure lascia che ogni progetto gestisca il suo backup separato. CineBase è già coperto (MariaDB + media-uploads) |

> **Filosofia**: il backup copre i dati che **non puoi rigenerare** (database, repo Git, credenziali, allegati, certificati). I Dockerfile e il codice sorgente sono già su Forgejo — si ricostruiscono. I file di configurazione vanno versionati. I volumi applicativi di nuovi progetti vanno aggiunti progetto per progetto.

### 11.2 Stato dei container

```bash
$ docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

NAMES              STATUS          IMAGE
traefik            Up 2 days       traefik:v3.7.4
portainer          Up 2 days       portainer/portainer-ce:2.39.3
netdata            Up 2 days       netdata/netdata:stable
registry           Up 2 days       registry:3.1.1
registry-ui        Up 2 days       joxit/docker-registry-ui:2.6.0
forgejo-db         Up 2 days       postgres:16-alpine
forgejo            Up 2 days       codeberg.org/forgejo/forgejo:15
forgejo-runner1    Up 2 days       data.forgejo.org/forgejo/runner:12
forgejo-runner2    Up 2 days       data.forgejo.org/forgejo/runner:12
cinebase-web       Up 1 day        registry.dominio/cinebase/web:latest
cinebase-api       Up 1 day        registry.dominio/cinebase/api:latest
blog-web           Up 12 hours     registry.dominio/blog/web:latest
```

RAM totale stimata: **~4.2 GB** (sistema + Docker + Traefik + Portainer + Netdata + Registry + Forgejo + PostgreSQL + 2 runner). Lasciano ~19.8 GB per i progetti applicativi.

### 11.3 Comandi quotidiani

```bash
# Avviare/fermare tutto
cd ~/docker/traefik && docker compose up -d
cd ~/docker/registry && docker compose up -d
cd ~/docker/forgejo && docker compose up -d
cd ~/docker/netdata && docker compose up -d

# Deploy di un progetto
./deploy.sh cinebase

# Log Traefik (vedere certificati generati, errori routing)
docker logs -f --tail 50 traefik

# Log Forgejo
docker logs -f --tail 50 forgejo

# Spazio disco
df -h /
du -sh ~/docker/registry/data ~/docker/forgejo/data ~/docker/postgres

# Rinnovare certificati (automatico, ma puoi forzare)
docker restart traefik

# Backup manuale
~/docker/backup.sh

# Aggiornare tutte le immagini
cd ~/docker/traefik && docker compose pull && docker compose up -d
cd ~/docker/registry && docker compose pull && docker compose up -d
cd ~/docker/forgejo && docker compose pull && docker compose up -d
cd ~/docker/netdata && docker compose pull && docker compose up -d
```

### 11.4 Flusso di sviluppo quotidiano

```
1. PC sviluppo: scrivi codice, commit, push su git.<DOMINIO>
2. Forgejo runner: esegue CI/CD (build + test + docker build + docker push)
3. Server: ./deploy.sh progetto  → docker compose pull → docker compose up -d
4. Verifica: curl https://progetto.<DOMINIO>
5. Portainer: monitora CPU/RAM, log, stato container
```
