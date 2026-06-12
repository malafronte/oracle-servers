# Guida CI/CD Forgejo Actions — Setup runner, workflow e deploy

**Server**: <NOME_SERVER> (ARM Ampere A1, 4 OCPU, 24 GB RAM, Ubuntu 24.04)
**Data**: Giugno 2026

---

## 1. Architettura

```
git push forgejo main
        │
        ▼
Forgejo (git.<DOMINIO>)
        │
        ▼
Forgejo Runner (forgejo-runner1/2 su s1)
        │
        ├── 1. Checkout repo
        ├── 2. Installa Docker CLI (apt-get install docker.io)
        ├── 3. Login registry.<DOMINIO>
        ├── 4. docker build (3 immagini .NET 10)
        ├── 5. docker push registry.<DOMINIO>
        └── 6. SSH → server → docker compose pull && up -d
```

Il runner esegue i job in un container `node:22-bookworm` (Debian). Docker socket dell'host è accessibile via `container.docker_host: "automount"`. Il deploy avviene via SSH perché il container non ha accesso al filesystem dell'host.

---

## 2. Configurazione runner

### 2.1 File `runner-config.yml`

I runner v12 girano come container `forgejo-runner1` e `forgejo-runner2` nel file `~/docker/forgejo/docker-compose.yml`. La configurazione è in `~/docker/forgejo/runner{1,2}/data/runner-config.yml`:

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
      uuid: <UUID generato dalla registrazione>
      token: <secret esadecimale>
```

### 2.2 Scelta strategica: `:docker://node:22-bookworm` vs `:host`

| Modalità | Dove gira il job | Vantaggi | Svantaggi |
|---|---|---|---|
| `:docker://node:22-bookworm` | Container `node:22-bookworm` (Debian) | Immutabile, isolato, Debian ha `apt-get`, Docker socket automount | Serve installare pacchetti extra (docker.io, openssh-client) |
| `:host` | Dentro il container runner (Alpine) | Niente container aggiuntivo | Alpine ha `apk`, non `apt-get`; meno compatibilità con actions standard |

**Scelta per CineBase**: `:docker://node:22-bookworm` perché:
- Node.js 22 già installato (serve per actions JS come `checkout@v4`)
- Debian permette `apt-get install docker.io` per i comandi Docker
- `container.docker_host: "automount"` monta automaticamente `/var/run/docker.sock`

### 2.3 Pacchetti installati nel workflow

Il job container (`node:22-bookworm`) parte pulito. Due pacchetti vanno installati a runtime:

| Pacchetto | Comando | Perché |
|---|---|---|
| `docker.io` | `apt-get install -y docker.io` | `docker build`, `docker push` |
| `openssh-client` | `apt-get install -y openssh-client` | `ssh` per deploy su host |

Sono installati in un unico step all'inizio del workflow per minimizzare il tempo.

---

## 3. Workflow deploy.yml

File: `.forgejo/workflows/deploy.yml` nel repo CineBase.

```yaml
name: Build and Deploy CineBase

on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install Docker CLI and SSH client
        run: apt-get update && apt-get install -y --no-install-recommends docker.io openssh-client

      - name: Login to private registry
        run: |
          echo "${{ secrets.REGISTRY_PASSWORD }}" | docker login registry.<DOMINIO> --username "${{ secrets.REGISTRY_USER }}" --password-stdin

      - name: Build backend (FilmAPI)
        run: |
          docker build \
            -t registry.<DOMINIO>/cinebase/filmapi:latest \
            -f backend/FilmAPI/Dockerfile .
      - name: Build seeder (FilmApiSeeder)
        run: |
          docker build \
            -t registry.<DOMINIO>/cinebase/seeder:latest \
            -f backend/scripts/FilmApiSeeder/Dockerfile .
      - name: Build frontend (CineBase.Web)
        run: |
          docker build \
            -t registry.<DOMINIO>/cinebase/web:latest \
            -f frontend/CineBase.Web/Dockerfile .

      - name: Push images to registry
        run: |
          docker push registry.<DOMINIO>/cinebase/filmapi:latest
          docker push registry.<DOMINIO>/cinebase/seeder:latest
          docker push registry.<DOMINIO>/cinebase/web:latest

      - name: Deploy stack via SSH
        env:
          SSH_KEY: ${{ secrets.S1_SSH_KEY }}
        run: |
          mkdir -p ~/.ssh
          echo "$SSH_KEY" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            ${{ secrets.S1_SSH_USER }}@${{ secrets.S1_SSH_HOST }} \
            "cd ~/docker/cinebase && docker compose pull && docker compose up -d --remove-orphans"
```

### 3.1 Perché SSH per il deploy e non docker compose diretto

Il container job (`node:22-bookworm`) e l'host (`<NOME_SERVER>`) sono due ambienti separati. Anche con Docker socket condiviso, il filesystem dell'host non è accessibile. Quindi:
- `docker compose pull` richiede il file `docker-compose.yml` in `/home/ubuntu/docker/cinebase/`
- Questo path esiste sull'host, non nel container job
- Soluzione: SSH dal container all'host per eseguire `docker compose` localmente

### 3.2 Perché `--password-stdin` e non `-p`

Il carattere `è` nella password del registry viene interpretato male dalla shell quando si usa `-p`. Con `--password-stdin` e `echo "$SECRET" | docker login ...` il problema di encoding è risolto.

---

## 4. Secrets su Forgejo

Vanno impostati su `https://git.<DOMINIO>/<UTENTE>/cinebase/settings/actions/secrets`:

| Nome | Valore | Note |
|---|---|---|
| `REGISTRY_USER` | `<UTENTE>` | Utente registry |
| `REGISTRY_PASSWORD` | (password registry) | Usare `--password-stdin` per evitare encoding |
| `S1_SSH_HOST` | `<IP_SERVER>` | IP server |
| `S1_SSH_USER` | `ubuntu` | Utente SSH |
| `S1_SSH_KEY` | (chiave privata ed25519, **senza passphrase**) | Generata con `ssh-keygen -t ed25519 -f oci-s1-deploy-ed25519` |

### 4.1 Chiave SSH deploy: generazione dedicata

La chiave usata per i workflow **non deve avere passphrase**, altrimenti SSH fallisce con `Permission denied (publickey)`. Si usa una chiave **aggiuntiva** dedicata al deploy:

```bash
# Genera chiave senza passphrase (premi Enter due volte)
ssh-keygen -t ed25519 -C "forgejo-deploy@<NOME_SERVER>" \
  -f tenant/.secrets/s1/oci-s1-deploy-ed25519

# Aggiungi la chiave pubblica al server
cat tenant/.secrets/s1/oci-s1-deploy-ed25519.pub | \
  ssh -i tenant/.secrets/s1/oci-s1-ed25519 ubuntu@<IP_SERVER> \
  "cat >> ~/.ssh/authorized_keys"

# Testa la connessione
ssh -i tenant/.secrets/s1/oci-s1-deploy-ed25519 ubuntu@<IP_SERVER> "echo OK"
```

La chiave personale con passphrase (`oci-s1-ed25519`) resta funzionante per l'accesso interattivo. Entrambe coesistono in `authorized_keys`.

---

## 5. Errori comuni e fix

### 5.1 `no matching online runner with label: ubuntu-24.04`

**Causa**: il workflow usa `runs-on: ubuntu-24.04` ma il runner ha label `ubuntu-latest`.

**Fix**: cambia `runs-on: ubuntu-latest` nel workflow.

### 5.2 `docker: command not found` nel container job

**Causa**: il container `node:22-bookworm` non ha Docker CLI. Anche con socket condiviso, serve il client.

**Fix**: aggiungi step:
```yaml
- name: Install Docker CLI
  run: apt-get update && apt-get install -y --no-install-recommends docker.io
```

### 5.3 `login attempt failed with status: 401 Unauthorized`

**Causa 1**: password sbagliata nel secret.  
**Causa 2**: caratteri speciali nella password (es. `è`, `$`) interpretati male dalla shell con `-p`.

**Fix**: usa `--password-stdin` con pipe:
```bash
echo "${{ secrets.REGISTRY_PASSWORD }}" | docker login ... --password-stdin
```

### 5.4 `cd: /root/docker/cinebase: No such file or directory`

**Causa**: il container job usa `$HOME=/root`, ma le directory di deploy sono in `/home/ubuntu/`.

**Fix**: deploy via SSH invece di eseguire `docker compose` dentro il container job.

### 5.5 `Permission denied (publickey)` su SSH

**Causa**: la chiave privata nel secret `S1_SSH_KEY` ha una passphrase. Il workflow non può fornirla.

**Fix**: genera una chiave dedicata **senza passphrase** (vedi §4.1).

### 5.6 `Cannot find: node in PATH`

**Causa**: il runner usa label `:host` ma il container runner (Alpine) non ha Node.js.

**Fix**: usa label `:docker://node:22-bookworm` (Debian, Node.js pre-installato).

### 5.7 `unable to clone 'https://data.forgejo.org/appleboy/ssh-action'`

**Causa**: azioni esterne non disponibili su `data.forgejo.org` (mirror limitato rispetto a GitHub).

**Fix**: usa comandi shell diretti invece di `uses:`:
```bash
ssh -o StrictHostKeyChecking=no ... "cd ~/docker/cinebase && docker compose pull && docker compose up -d"
```

### 5.8 Runner in crash loop `Restarting (1)` con `permission denied` su Docker socket

**Causa**: manca `group_add: ["<DOCKER_GID>"]` nel docker-compose del runner.

**Fix**: aggiungi al docker-compose:
```yaml
group_add:
  - "999"  # GID del gruppo docker sull'host
```

### 5.9 `Push to create is not enabled for users`

**Causa**: Forgejo non permette di creare repository via `git push` iniziale.

**Fix**: crea prima il repo vuoto su Forgejo (UI), poi pusha.

---

## 6. Workflow CI/CD completo — lista di controllo

Prima di pushare un nuovo progetto:

- [ ] Creare repo vuoto su Forgejo (via UI)
- [ ] Aggiungere i secret: `REGISTRY_USER`, `REGISTRY_PASSWORD`, `S1_SSH_HOST`, `S1_SSH_USER`, `S1_SSH_KEY`
- [ ] La chiave `S1_SSH_KEY` deve essere una chiave ed25519 **senza passphrase**
- [ ] La chiave pubblica corrispondente deve essere in `~/.ssh/authorized_keys` sul server
- [ ] `.forgejo/workflows/deploy.yml` con `runs-on: ubuntu-latest`
- [ ] Step `Install Docker CLI and SSH client` prima di qualsiasi comando Docker
- [ ] Login registry con `--password-stdin` (pipe, non `-p`)
- [ ] Deploy via SSH, non `docker compose` diretto nel container job
- [ ] Runner configurato con label `ubuntu-latest:docker://node:22-bookworm` e `container.docker_host: "automount"`

---

## 7. Comandi di manutenzione

```bash
# Verifica stato runner su Forgejo
docker exec -u 1000:1000 forgejo forgejo forgejo-cli actions list

# Registra un nuovo runner
SECRET=$(openssl rand -hex 20)
UUID=$(docker exec -u 1000:1000 forgejo forgejo forgejo-cli actions register --name runner1 --secret "$SECRET")
echo "UUID: $UUID  Secret: $SECRET"

# Riavvia runner dopo modifica config
docker restart forgejo-runner1

# Log Forgejo Actions
docker logs forgejo --tail 100 | grep -i action

# Log runner
docker logs forgejo-runner1 --tail 50

# Test SSH deploy manuale
ssh -i tenant/.secrets/s1/oci-s1-deploy-ed25519 ubuntu@<IP_SERVER> \
  "cd ~/docker/cinebase && docker compose pull && docker compose up -d --remove-orphans"

# Forzare una pipeline (commit vuoto)
cd ~/source/repos/5IA/CineBase
git commit --allow-empty -m "trigger: test CI/CD"
git push forgejo main
```
