# Build immagini Docker per server ARM64

Guida alla generazione di immagini Docker compatibili con il server
`<NOME_SERVER>` (ARM Ampere A1, architettura `linux/arm64`).

---

## Perché l'architettura è importante

Il server OCI ha CPU **ARM64** (Ampere A1). Un'immagine Docker buildata su
PC **amd64** (x86_64) **non funziona** su ARM64 — otterrai errori `exec format error`.

| Dove | Architettura | Cosa produce |
|---|---|---|
| PC Windows (WSL2 / Docker Desktop) | `linux/amd64` | Immagini per CPU Intel/AMD |
| Server OCI (<NOME_SERVER>) | `linux/arm64` | Immagini per CPU ARM |
| Forgejo Runner (sul server) | `linux/arm64` | Immagini per CPU ARM |

### Verifica l'architettura locale

```bash
docker info --format '{{.OSType}}/{{.Architecture}}'
# Su PC Windows (WSL2): linux/x86_64
# Sul server OCI:        linux/aarch64
```

---

## Flusso consigliato (CI/CD con Forgejo)

Il flusso normale **non** prevede build in locale. Il codice va pushato su Forgejo,
il runner CI/CD builda l'immagine nativa ARM64 e la pusha sul registry:

```
PC sviluppo                    Forgejo (git.<DOMINIO>)     Registry (registry.<DOMINIO>)
    │                                    │                              │
    │  git push                          │                              │
    ├───────────────────────────────────►│                              │
    │                                    │                              │
    │                                    │  Runner CI/CD:               │
    │                                    │  1. git clone                │
    │                                    │  2. docker build (ARM64)     │
    │                                    │  3. docker push ────────────►│
    │                                    │                              │
    │                                    │                    Server:   │
    │                                    │              docker compose pull
    │                                    │              docker compose up -d
```

### Workflow Forgejo di esempio

Crea `.forgejo/workflows/build.yml` nel repository:

```yaml
name: Build and Push
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build Docker image
        run: |
          docker build \
            -t registry.<DOMINIO>/${{ github.repository }}:latest \
            -t registry.<DOMINIO>/${{ github.repository }}:${{ github.sha }} \
            .

      - name: Login to Registry
        run: |
          echo "${{ secrets.REGISTRY_PASSWORD }}" | \
          docker login registry.<DOMINIO> \
            --username ${{ secrets.REGISTRY_USER }} \
            --password-stdin

      - name: Push Docker image
        run: |
          docker push registry.<DOMINIO>/${{ github.repository }}:latest
          docker push registry.<DOMINIO>/${{ github.repository }}:${{ github.sha }}
```

> Il runner Forgejo gira **sul server ARM64**, quindi `docker build` produce
> automaticamente un'immagine `linux/arm64` nativa. Nessun flag di piattaforma necessario.

### Configurare i secrets su Forgejo

Vai su **Repository → Settings → Actions → Secrets** e aggiungi:

| Nome | Valore (da `.env`) |
|---|---|
| `REGISTRY_USER` | `${REGISTRY_USER}` |
| `REGISTRY_PASSWORD` | `${REGISTRY_PASSWORD}` |

---

## Build locale per ARM64 (da PC Windows amd64)

Se devi testare/buildare in locale un'immagine per il server ARM, usa
**Docker Buildx** con emulazione QEMU o cross-compilazione.

### 1. Verifica che Buildx sia disponibile

```bash
docker buildx version
```

### 2. Crea un builder multi-piattaforma

```bash
# Crea un builder che supporta ARM64 via QEMU
docker buildx create --name arm64-builder --use

# Avvia il builder
docker buildx inspect --bootstrap
```

### 3. Builda per ARM64

```bash
# Solo build (immagine rimane in cache locale buildx)
docker buildx build --platform linux/arm64 \
  -t registry.<DOMINIO>/progetto/web:latest \
  .

# Build + push diretto al registry (salta il passaggio intermedio)
docker buildx build --platform linux/arm64 \
  -t registry.<DOMINIO>/progetto/web:latest \
  --push .
```

### 4. Multi-architettura (opzionale)

Se vuoi un'immagine che funzioni sia su amd64 che arm64 (utile per test):

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t registry.<DOMINIO>/progetto/web:latest \
  --push .
```

> **Nota**: la build per piattaforme diverse richiede QEMU. Su Windows, Docker Desktop
> lo include. Su Linux va installato: `sudo apt install qemu-user-static`.

---

## Build nativa sul server (ARM64, senza buildx)

Se sei connesso via SSH al server, puoi buildare nativamente (senza buildx né QEMU).
L'architettura è già `linux/arm64`:

```bash
# Connesso al server
cd ~/docker/progetto
docker build -t registry.<DOMINIO>/progetto/web:latest .
docker login registry.<DOMINIO>
docker push registry.<DOMINIO>/progetto/web:latest

# Oppure con docker compose
docker compose build
docker compose push
```

> **Vantaggio**: massima velocità, nessuna emulazione. **Svantaggio**: occupi risorse
> del server (CPU/RAM) durante la build. Per progetti piccoli va bene; per progetti
> grandi, meglio usare il runner CI/CD dedicato.

---

## Best practices

### 1. Usa sempre il CI/CD per il deploy

- **Mai** buildare in locale e pushare manualmente per ambienti di produzione
- Il runner Forgejo builda in modo riproducibile, su architettura ARM64 nativa
- Il workflow CI/CD è versionato nel repo → tracciabilità

### 2. Tagga le immagini con versioni esplicite

```
registry.<DOMINIO>/cinebase/web:latest     ← mutable, sovrascritto
registry.<DOMINIO>/cinebase/web:v1.2.3     ← immutabile, puntuale
registry.<DOMINIO>/cinebase/web:abc1234    ← git sha, tracciabile
```

### 3. Dockerfile multi-stage

Riduci la dimensione dell'immagine separando build e runtime:

```dockerfile
# Stage 1: build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: runtime
FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
CMD ["node", "dist/index.js"]
```

### 4. Minimizza i layer

- Unisci comandi `RUN` correlati: `RUN apt update && apt install -y pkg && rm -rf /var/lib/apt/lists/*`
- Metti le dipendenze che cambiano meno spesso **prima** nel Dockerfile (cache Docker più efficace)

### 5. Non includere segreti nell'immagine

- Usa `.dockerignore` per escludere `.env`, `.git`, `node_modules/`
- Passa i segreti a runtime via variabili d'ambiente o Docker secrets, **mai** nel Dockerfile

### 6. Testa localmente prima di pushare

```bash
# Build locale ARM64 (con buildx)
docker buildx build --platform linux/arm64 -t progetto-test .

# Testa l'immagine direttamente sul server
ssh ${S1_SSH_USER}@${S1_IP} "docker pull registry.<DOMINIO>/progetto/web:latest && docker run --rm -p 3000:3000 registry.<DOMINIO>/progetto/web:latest"
```

---

## Comandi rapidi

### Build locale per ARM64
```bash
docker buildx create --name arm64-builder --use 2>/dev/null || docker buildx use arm64-builder
docker buildx inspect --bootstrap
docker buildx build --platform linux/arm64 -t registry.<DOMINIO>/progetto/web:latest --push .
```

### Build nativa sul server
```bash
ssh ${S1_SSH_USER}@${S1_IP} 'cd ~/docker/progetto && docker compose build && docker compose push'
```

### Deploy dopo build
```bash
ssh ${S1_SSH_USER}@${S1_IP} 'cd ~/docker/progetto && docker compose pull && docker compose up -d'
```

### Verifica architettura immagine
```bash
docker manifest inspect registry.<DOMINIO>/progetto/web:latest | grep architecture
```
