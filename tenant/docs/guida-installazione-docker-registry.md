# Guida: Docker Registry privato integrato con Traefik + Portainer

Scenario: server ARM Ampere, Traefik già attivo su `traefik-net`, dominio `registry.<DOMINIO>` configurato nei DNS.

---

## 1. Prerequisiti

- Docker + Docker Compose installati (vedi `guida-traefik-docker.md`)
- Traefik attivo con `traefik-net` creata
- Dominio `registry.<DOMINIO>` con record A → `<IP_SERVER>`
- `htpasswd` installato (`sudo apt install -y apache2-utils`)

---

## 2. Preparazione directory e autenticazione

```bash
mkdir -p ~/docker/registry/data
mkdir -p ~/docker/registry/auth

# Crea un utente per push/pull
htpasswd -Bc ~/docker/registry/auth/htpasswd tuo-utente
# (ti chiederà la password due volte)

# Aggiungere altri utenti in futuro:
# htpasswd -B ~/docker/registry/auth/htpasswd altro-utente
```

---

## 3. Docker Compose per il Registry

Crea `~/docker/registry/docker-compose.yml`:

```yaml
services:
  registry:
    image: registry:2
    container_name: registry
    restart: unless-stopped
    networks:
      - traefik-net
    volumes:
      - ./data:/var/lib/registry          # immagini persistenti
      - ./auth/htpasswd:/auth/htpasswd:ro # credenziali
    environment:
      - REGISTRY_AUTH=htpasswd
      - REGISTRY_AUTH_HTPASSWD_REALM=Registry
      - REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd
      - REGISTRY_HTTP_ADDR=0.0.0.0:5000
      # Abilita la pull-through cache da Docker Hub (opzionale)
      - REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io
      - REGISTRY_PROXY_USERNAME=              # lascia vuoto per cache anonima
      - REGISTRY_PROXY_PASSWORD=
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry.rule=Host(`registry.<DOMINIO>`)"
      - "traefik.http.routers.registry.entrypoints=websecure"
      - "traefik.http.routers.registry.tls.certresolver=letsencrypt"
      - "traefik.http.services.registry.loadbalancer.server.port=5000"
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5000/v2/"]
      interval: 30s
      timeout: 5s
      retries: 3

networks:
  traefik-net:
    external: true
```

### Spiegazione delle variabili

| Variabile | Scopo |
|-----------|-------|
| `REGISTRY_AUTH=htpasswd` | Attiva autenticazione via file htpasswd |
| `REGISTRY_HTTP_ADDR=0.0.0.0:5000` | Ascolta su porta 5000 (interna al container) |
| `REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io` | **Pull-through cache**: quando fai `docker pull ubuntu:latest` dal tuo registry, lui lo scarica da Docker Hub, lo salva in cache e te lo serve. I pull successivi sono istantanei e non consumano rate limit di Docker Hub |
| `REGISTRY_PROXY_USERNAME` / `_PASSWORD` | Credenziali Docker Hub (solo se hai account a pagamento per rate limit più alti; per uso personale lascia vuoto) |

> ⚠️ La pull-through cache è opzionale. Senza di essa il registry serve solo immagini che hai pushato tu. Con la cache, funziona anche come proxy trasparente verso Docker Hub.

---

## 4. Avvio

```bash
cd ~/docker/registry
docker compose up -d
```

Verifica:
```bash
docker ps | grep registry
curl -u tuo-utente:password https://registry.<DOMINIO>/v2/_catalog
# Output: {"repositories":[]}
```

---

## 5. Configurare Docker per fidarsi del registry

Per pushare devi autenticarti. Su ogni macchina che usa il registry:

```bash
docker login registry.<DOMINIO>
# Username: tuo-utente
# Password: [quella impostata con htpasswd]
```

Le credenziali vengono salvate in `~/.docker/config.json`.

### Su Windows (PowerShell)

```powershell
docker login registry.<DOMINIO>
# Stessa procedura
```

### Automatizzare login su CI/CD

```bash
echo "password" | docker login registry.<DOMINIO> -u tuo-utente --password-stdin
```

---

## 6. Usare il registry nei progetti

### 6.1 Build, tag e push di un'immagine

```bash
# Sviluppo locale: build dell'immagine
docker build -t cinebase-api .

# Tagga per il tuo registry privato
docker tag cinebase-api:latest registry.<DOMINIO>/cinebase/api:latest
docker tag cinebase-api:latest registry.<DOMINIO>/cinebase/api:v1.2.3

# Push
docker push registry.<DOMINIO>/cinebase/api:latest
docker push registry.<DOMINIO>/cinebase/api:v1.2.3
```

> **Convenzione nomi**: `registry.<DOMINIO>/<progetto>/<componente>:<tag>`
> 
> Esempi: `cinebase/web:latest`, `cinebase/api:latest`, `blog/frontend:v1`

### 6.2 Usare l'immagine in un docker-compose

```yaml
# ~/docker/cinebase/docker-compose.yml
services:
  cinebase-api:
    image: registry.<DOMINIO>/cinebase/api:latest
    # ... resto invariato ...

  cinebase-web:
    image: registry.<DOMINIO>/cinebase/web:latest
    # ... resto invariato ...
```

### 6.3 Deploy sul server

```bash
# Dopo aver pushato una nuova versione dal PC di sviluppo:

# Sul server
cd ~/docker/cinebase
docker compose pull                        # scarica le nuove immagini
docker compose up -d                       # ricrea solo i container con immagine aggiornata
docker image prune -f                      # rimuove le vecchie immagini
```

### 6.4 Script di deploy semplificato

Crea `~/docker/deploy.sh`:

```bash
#!/bin/bash
# Uso: ./deploy.sh cinebase
#      ./deploy.sh blog-personale

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

---

## 7. Integrazione con l'architettura esistente

```
                          Internet
                             │
                     ┌───────┴───────┐
                     │   Traefik     │
                     │  :80 / :443   │
                     └───┬───┬───┬───┘
                         │   │   │
         ┌───────────────┘   │   └──────────────┐
         ▼                   ▼                  ▼
┌─────────────────┐  ┌────────────┐   ┌────────────┐
│ Docker Registry │  │  CineBase  │   │   Blog     │
│ registry.dominio│  │ 2 domini   │   │ 2 domini   │
│ Porta 5000      │  │ stack      │   │ stack      │
└────────┬────────┘  └─────┬──────┘   └─────┬──────┘
         │                 │                │
         │  backup notturno│                │
         ▼                 │                │
┌─────────────────┐        │                │
│  OCI Object     │        │                │
│  Storage        │   pull delle immagini ──┘
│  (Always Free)  │   da registry.dominio
└─────────────────┘
```

### Schema delle directory

```
~/docker/
├── traefik/
│   ├── docker-compose.yml
│   ├── traefik.yml
│   ├── config/
│   └── certificates/
├── portainer/
│   └── docker-compose.yml
├── registry/
│   ├── docker-compose.yml
│   ├── auth/htpasswd
│   ├── data/              ← immagini salvate qui
│   └── backup.log
├── cinebase/
│   └── docker-compose.yml
├── blog-personale/
│   └── docker-compose.yml
├── deploy.sh
└── backup-registry.sh     ← backup automatico su OCI Object Storage
```

---

## 8. Backup automatico su OCI Object Storage (Always Free)

OCI Always Free include **10 GB di Object Storage**. Ci bastano per un backup sicuro del registry.

### 8.1 Creare il bucket su OCI

Dal tuo PC Windows (dove OCI CLI è già configurata):

```powershell
# Crea il bucket nella tua region
oci os bucket create --name docker-registry-backup --compartment-id <OCID_TENANCY>
```

### 8.2 Installare e configurare OCI CLI sul server

Per caricare i backup dal server, serve OCI CLI anche lì. L'approccio più pulito è l'**Instance Principal**: il server è già dentro OCI, quindi può autenticarsi senza chiavi.

**Sul server (`ssh ubuntu@<IP_SERVER>`):**

```bash
# Installa OCI CLI (via snap, già presente su Ubuntu 24.04)
sudo snap install oci-cli --classic

# Verifica
oci --version
```

**Sulla console OCI** (dal browser), configura l'Instance Principal:

1. Vai a **Identity & Security → Dynamic Groups**
2. Clicca **Create Dynamic Group**
   - Nome: `docker-registry-vm`
   - Regola: `Any { instance.id = '<OCID_INSTANCE>' }`
     (l'OCID di `<NOME_SERVER>`, lo trovi con `oci compute instance list`)
3. Vai a **Identity & Security → Policies**
4. Clicca **Create Policy**
   - Nome: `registry-backup-policy`
   - Policy:
     ```
     Allow dynamic-group docker-registry-vm to manage objects in compartment <nome-tenancy> where target.bucket.name='docker-registry-backup'
     ```

**Sul server**, verifica che l'Instance Principal funzioni:

```bash
oci os object list --bucket-name docker-registry-backup --auth instance_principal
# Output: {"data": []}  ← bucket vuoto, ma l'autenticazione funziona
```

> **Alternativa senza Instance Principal**: copia il file `<HOME>\\.oci\config` e `oci_api_key.pem` sul server in `~/.oci/`. Stesso identico setup del PC Windows.

### 8.3 Script di backup automatico

Crea `~/docker/backup-registry.sh` sul server:

```bash
#!/bin/bash
# Backup giornaliero del Docker Registry su OCI Object Storage
# Uso: ./backup-registry.sh
# Cron: 0 3 * * * /home/ubuntu/docker/backup-registry.sh

set -e

BUCKET="docker-registry-backup"
BACKUP_DIR="/home/ubuntu/docker/registry"
BACKUP_FILE="/tmp/registry-backup-$(date +%Y-%m-%d).tar.gz"
LOG_FILE="/home/ubuntu/docker/registry/backup.log"
RETENTION_DAYS=7

echo "[$(date)] Inizio backup del registry..." | tee -a "$LOG_FILE"

# Ferma temporaneamente il registry per consistenza
docker stop registry 2>/dev/null || true

# Crea l'archivio
tar czf "$BACKUP_FILE" -C "$BACKUP_DIR" data/ auth/

# Riavvia il registry
docker start registry 2>/dev/null || true

# Carica su OCI Object Storage
oci os object put \
  --bucket-name "$BUCKET" \
  --file "$BACKUP_FILE" \
  --name "registry-$(date +%Y-%m-%d).tar.gz" \
  --auth instance_principal \
  --force \
  2>&1 | tee -a "$LOG_FILE"

# Pulisci i backup locali più vecchi di RETENTION_DAYS giorni
find /tmp -name "registry-backup-*" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true

# Pulisci i backup remoti più vecchi di RETENTION_DAYS giorni
CUTOFF_DATE=$(date -d "-$RETENTION_DAYS days" +%Y-%m-%d)
oci os object list --bucket-name "$BUCKET" --auth instance_principal --all 2>/dev/null | \
  jq -r '.data[]?.name // empty' | \
  while read -r obj; do
    OBJ_DATE=$(echo "$obj" | grep -oP '\d{4}-\d{2}-\d{2}')
    if [[ "$OBJ_DATE" < "$CUTOFF_DATE" ]]; then
      oci os object delete --bucket-name "$BUCKET" --object-name "$obj" --auth instance_principal --force 2>&1 | tee -a "$LOG_FILE"
    fi
  done

echo "[$(date)] Backup completato: $BACKUP_FILE" | tee -a "$LOG_FILE"
```

Rendi eseguibile:
```bash
chmod +x ~/docker/backup-registry.sh
```

### 8.4 Automatizzare con cron

```bash
# Esegui ogni notte alle 3:00
(crontab -l 2>/dev/null; echo "0 3 * * * /home/ubuntu/docker/backup-registry.sh") | crontab -
```

Verifica che cron sia attivo:
```bash
cron_status=$(systemctl is-active cron); echo $cron_status
# Output: active
```

### 8.5 Ripristinare il registry da backup

Scenario: il server è stato ricreato, Docker e il registry sono stati reinstallati, ma il volume `data/` è vuoto.

```bash
# 1. Sul server, installa OCI CLI e configura l'Instance Principal (vedi 8.2)

# 2. Scarica l'ultimo backup
oci os object list --bucket-name docker-registry-backup --auth instance_principal --all | \
  jq -r '.data | sort_by(.["time-created"]) | last | .name'

# 3. Scarica il file (sostituisci con il nome ottenuto sopra)
oci os object get \
  --bucket-name docker-registry-backup \
  --name "registry-2026-06-06.tar.gz" \
  --file /tmp/registry-restore.tar.gz \
  --auth instance_principal

# 4. Ferma il registry e ripristina
cd ~/docker/registry
docker compose down
sudo rm -rf data/
tar xzf /tmp/registry-restore.tar.gz
docker compose up -d

# 5. Verifica
curl -u tuo-utente:password https://registry.<DOMINIO>/v2/_catalog
```

### 8.6 Pulizia delle immagini vecchie (garbage collection)

Il registry non cancella automaticamente i layer orfani. Dopo aver pushato nuovi tag:

```bash
cd ~/docker/registry
docker exec registry bin/registry garbage-collect /etc/docker/registry/config.yml --delete-untagged
```

Mettilo in un cron mensile (esegue dopo il backup):
```bash
(crontab -l 2>/dev/null; echo "0 5 1 * * cd ~/docker/registry && docker exec registry bin/registry garbage-collect /etc/docker/registry/config.yml --delete-untagged") | crontab -
```

### 8.7 Vedere quali immagini ci sono

```bash
curl -u tuo-utente:password https://registry.<DOMINIO>/v2/_catalog
# {"repositories":["cinebase/api","cinebase/web","blog/frontend"]}

curl -u tuo-utente:password https://registry.<DOMINIO>/v2/cinebase/api/tags/list
# {"name":"cinebase/api","tags":["latest","v1.2.3"]}
```

---

## 9. (Opzionale) Aggiungere una UI web

Se vuoi sfogliare le immagini da browser, aggiungi `docker-registry-ui`:

```yaml
# Aggiungi a ~/docker/registry/docker-compose.yml

  registry-ui:
    image: joxit/docker-registry-ui:latest
    container_name: registry-ui
    restart: unless-stopped
    networks:
      - traefik-net
    environment:
      - REGISTRY_TITLE=Docker Registry
      - REGISTRY_URL=https://registry.<DOMINIO>
      - SINGLE_REGISTRY=true
      - DELETE_IMAGES=true
      - NGINX_PROXY_PASS_URL=https://registry.<DOMINIO>
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.registry-ui.rule=Host(`registry-ui.<DOMINIO>`)"
      - "traefik.http.routers.registry-ui.entrypoints=websecure"
      - "traefik.http.routers.registry-ui.tls.certresolver=letsencrypt"
      - "traefik.http.services.registry-ui.loadbalancer.server.port=80"
```

Record DNS: `registry-ui.<DOMINIO>` → `<IP_SERVER>`

---

## 10. Flusso di lavoro completo

```
1. Sviluppo locale (tuo PC)
   docker build -t registry.<DOMINIO>/cinebase/api:latest .
   docker push registry.<DOMINIO>/cinebase/api:latest

2. Sul server VPS
   cd ~/docker/cinebase
   docker compose pull          ← scarica da registry.<DOMINIO>
   docker compose up -d         ← avvia con la nuova immagine

3. Verifica
   curl https://cinebase.<DOMINIO>   ← funziona?
   docker logs cinebase-api               ← errori?

4. Rollback (se necessario)
   docker tag registry.<DOMINIO>/cinebase/api:v1.2.3 registry.<DOMINIO>/cinebase/api:latest
   docker push registry.<DOMINIO>/cinebase/api:latest
   # ripeti il deploy
```
