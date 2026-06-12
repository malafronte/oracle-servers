# Server s1 — Guida alla configurazione

**Server**: `<NOME_SERVER>` — ARM Ampere A1, 4 OCPU, 24 GB RAM, Ubuntu 24.04.4 LTS

---

## Configurazione rapida: file `.env`

Tutti i segreti, IP, dominio e parametri OCI sono centralizzati in **due** file:

| File | Versionato | Contiene |
|---|---|---|
| `.env.example` | Sì (git) | Placeholder, struttura, documentazione |
| `.env` | No (gitignored) | Valori reali: password, IP, OCID, dominio |

**Prima di eseguire qualsiasi script**, copia `.env.example` in `.env` e compila i valori:

```bash
cp .env.example .env
nano .env   # oppure vim, code, ecc.
```

Gli script caricano automaticamente `.env` dalla stessa directory. Se manca, si fermano con un errore esplicativo.

### Come caricare le variabili nella shell

Prima di eseguire comandi interattivi (`ssh`, `scp`, `oci`, ecc.), carica le variabili
d'ambiente dal `.env`:

**Git Bash / WSL** (consigliato — sintassi `${VAR}` nativa):
```bash
# Dalla root del repository (oracle-servers/)
set -a; source tenant/servers/s1/.env; set +a
```

**PowerShell**:
```powershell
# Dalla root del repository (oracle-servers/)
Get-Content tenant\servers\s1\.env | ForEach-Object { if ($_ -match '^([^#].+?)=(.+)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
```

> Dopo il caricamento, in Git Bash puoi usare `${S1_IP}`, `${DOMAIN}`, ecc.
> In PowerShell usa `$env:S1_IP`, `$env:DOMAIN`, ecc.
> I comandi in questa guida usano la sintassi bash `${VAR}`. Se usi PowerShell,
> sostituisci `${VAR}` con `$env:VAR`.

### Variabili nel `.env`

| Variabile | Esempio | Descrizione |
|---|---|---|
| `S1_IP` | `<IP_SERVER>` | IP pubblico del server |
| `S1_SSH_USER` | `ubuntu` | Utente SSH |
| `DOMAIN` | `miodominio.com` | Dominio base per Traefik e servizi |
| `LETSENCRYPT_EMAIL` | `admin@miodominio.com` | Email per certificati Let's Encrypt |
| `TRAEFIK_DASHBOARD_USER` | `admin` | Utente basic auth dashboard Traefik |
| `TRAEFIK_DASHBOARD_PASSWORD` | `...` | Password dashboard Traefik |
| `REGISTRY_USER` | `mio-utente` | Utente Docker Registry |
| `REGISTRY_PASSWORD` | `...` | Password Docker Registry |
| `FORGEJO_DB_PASSWORD` | `...` | Password PostgreSQL Forgejo |
| `NETDATA_DASHBOARD_USER` | `admin` | Utente dashboard Netdata |
| `NETDATA_DASHBOARD_PASSWORD` | `...` | Password dashboard Netdata |
| `TELEGRAM_BOT_TOKEN` | (opzionale) | Token bot Telegram per notifiche |
| `TELEGRAM_CHAT_ID` | (opzionale) | Chat ID Telegram per notifiche |
| `BACKUP_BUCKET_NAME` | `s1-backup` | Nome bucket OCI per backup |
| `OCI_COMPARTMENT_ID` | `ocid1.tenancy...` | OCID del compartment |
| `OCI_INSTANCE_ID` | `ocid1.instance...` | OCID dell'istanza s1 |
| `OCI_USER_ID` | `ocid1.user...` | OCID utente OCI |
| `OCI_TENANCY_ID` | `ocid1.tenancy...` | OCID tenancy |
| `OCI_REGION` | `eu-milan-1` | Regione OCI |
| `OCI_KEY_FILE` | `C:\...\oci_api_key.pem` | Percorso chiave API OCI |
| `OCI_FINGERPRINT` | `c3:a2:5c:...` | Fingerprint chiave API |
| `OCI_SESSION_PROFILE` | `<NOME_PROFILO>` | Profilo creato da `oci session authenticate` |

---

## Prerequisiti prima di iniziare

### 1. DNS

Configura questi record A nei DNS (tutti puntano a `${S1_IP}`).
`${DOMAIN}` è il dominio infrastrutturale (es. `<DOMINIO>`).
Per domini applicativi separati (es. `<DOMINIO_APP>`), vedi `09-progetto-template.sh`.

| Record A             | Servizio          |
| -------------------- | ----------------- |
| `traefik.${DOMAIN}`  | Dashboard Traefik |
| `portainer.${DOMAIN}`| Portainer         |
| `monitor.${DOMAIN}`  | Netdata           |
| `registry.${DOMAIN}` | Docker Registry   |
| `git.${DOMAIN}`      | Forgejo           |
| `*.${DOMAIN}`        | Wildcard (consigliato) |

### 2. Connettersi al server

La chiave SSH si trova in `tenant/.secrets/s1/` (gitignorata). I valori `${S1_IP}` e `${S1_SSH_KEY}` sono definiti in `.env`:

```bash
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP}
```

### 3. Copiare script e `.env` sul server

```bash
# Copia script e .env sul server
scp -i ${S1_SSH_KEY} -r tenant/servers/s1/scripts tenant/servers/s1/.env ${S1_SSH_USER}@${S1_IP}:~/
```

---

## Ordine di esecuzione

Esegui gli script **in quest'ordine** dal server (dopo averli copiati via SCP insieme al `.env`):

```bash
# 1. Copia gli script e il .env sul server
scp -i ${S1_SSH_KEY} -r tenant/servers/s1/scripts tenant/servers/s1/.env ${S1_SSH_USER}@${S1_IP}:~/

# 2. Connettiti al server
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP}

# 3. Sposta .env nella cartella scripts e rendi eseguibili gli script
mv .env scripts/
cd scripts
chmod +x *.sh

# 4. Esegui in ordine
./01-prerequisiti.sh         # Prepara il sistema
./02-installa-docker.sh      # Installa Docker su ARM64
# Esci e rientra dalla sessione SSH per i group permissions
./03-crea-struttura.sh       # Crea la struttura directory
./04-setup-traefik.sh        # Avvia Traefik (reverse proxy + SSL)
./05-setup-portainer.sh      # Avvia Portainer (GUI Docker)
./06-setup-registry.sh       # Avvia Docker Registry privato
./07-setup-forgejo.sh        # Avvia Forgejo + PostgreSQL + runner CI/CD
./08-setup-netdata.sh        # Avvia Netdata (monitoring)
./10-setup-backup.sh         # Configura backup automatico su OCI
```

---

## Script disponibili

| Script                     | Cosa fa                                               |
| -------------------------- | ----------------------------------------------------- |
| `01-prerequisiti.sh`       | Aggiorna pacchetti, installa curl, jq, apache2-utils |
| `02-installa-docker.sh`    | Installa Docker CE + compose plugin su ARM64           |
| `03-crea-struttura.sh`     | Crea `~/docker/` e tutte le sottodirectory             |
| `04-setup-traefik.sh`      | Configura e avvia Traefik (reverse proxy + Let's Encrypt) |
| `05-setup-portainer.sh`    | Configura e avvia Portainer                            |
| `06-setup-registry.sh`     | Configura e avvia Docker Registry privato              |
| `07-setup-forgejo.sh`      | Configura e avvia Forgejo + PostgreSQL + 2 runner CI   |
| `08-setup-netdata.sh`      | Configura e avvia Netdata con allarmi                  |
| `09-progetto-template.sh`  | Crea struttura per nuovo progetto (dominio configurabile) |
| `10-setup-backup.sh`       | Crea lo script di backup e il cron job                 |
| `deploy.sh`                | Helper per deploy rapido di un progetto                |
| `backup.sh`                | Script di backup eseguibile manualmente                |

---

## Struttura generata sul server

Dopo l'esecuzione, il server avrà questa struttura:

```
~/docker/
├── traefik/
│   ├── docker-compose.yml
│   ├── traefik.yml
│   ├── config/
│   │   └── dashboard.yml
│   └── certificates/
├── portainer/
│   └── docker-compose.yml
├── netdata/
│   ├── docker-compose.yml
│   └── config/
├── registry/
│   ├── docker-compose.yml
│   ├── auth/htpasswd
│   └── data/
├── forgejo/
│   ├── docker-compose.yml
│   ├── data/
│   ├── runner1/
│   └── runner2/
├── deploy.sh
└── backup.sh
```

---

## Dopo la configurazione

1. **Traefik**: visita `https://traefik.${DOMAIN}` e verifica il certificato SSL
2. **Portainer**: visita `https://portainer.${DOMAIN}`, crea utente admin, scegli "Get Started"
3. **Forgejo**: visita `https://git.${DOMAIN}`, completa l'installazione guidata
4. **Registry**: testa con `docker login registry.${DOMAIN}` (utente/password in `.env`)
5. **Netdata**: visita `https://monitor.${DOMAIN}` (utente/password in `.env`)
6. **Forgejo Runners**: registra i runner usando il token da Site Administration → Actions → Runners

### Registrazione runner Forgejo

Dopo aver ottenuto il token da Forgejo:

```bash
docker exec -it forgejo-runner1 forgejo-runner register \
  --no-interactive \
  --instance https://git.${DOMAIN} \
  --token "IL-TUO-TOKEN" \
  --name "runner1" \
  --labels "ubuntu-latest:docker://node:20-bookworm"

docker exec -it forgejo-runner2 forgejo-runner register \
  --no-interactive \
  --instance https://git.${DOMAIN} \
  --token "IL-TUO-TOKEN" \
  --name "runner2" \
  --labels "ubuntu-latest:docker://node:20-bookworm"
```

---

## OCI Setup (da eseguire localmente su Windows)

1. **Sicurezza firewall**: apri le porte 80 e 443 sulla security list OCI.
   Vedi [`tenant/docs/sicurezza-oci-firewall.md`](../../docs/sicurezza-oci-firewall.md)
   per la guida completa su tutti i livelli di sicurezza (VCN, UFW, container).

2. **Bucket backup e IAM**: vedi `oci-setup/README.md` per:
   - Creare il bucket S3-compatibile
   - Creare il Dynamic Group per l'Instance Principal
   - Creare la Policy IAM per l'accesso al bucket

I valori `${OCI_COMPARTMENT_ID}`, `${OCI_INSTANCE_ID}`, `${OCI_SECURITY_LIST_ID}`, ecc.
sono già definiti in `.env`.
