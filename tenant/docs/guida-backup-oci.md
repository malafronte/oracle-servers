# Guida — Backup automatico su OCI Object Storage

> Procedura operativa completa per configurare il backup notturno del server `s1` (malafronte-oci-s1) su OCI Object Storage, usando l'autenticazione **Instance Principal** (nessun segreto sul server).

**Server**: `malafronte-oci-s1` (OCI ARM64 Ampere A1, Ubuntu 24.04)
**Bucket**: `s1-backup` (10 GB Standard, Always Free)
**Frequenza**: ogni giorno alle 03:00 (Europe/Rome)
**Script generatore**: [`10-setup-backup.sh`](../servers/s1/scripts/10-setup-backup.sh)
**Script runtime (generato sul server)**: `~/docker/backup.sh`

---

## 1. Architettura

```
            ┌─────────────────────────────────────┐
            │  Server s1 (cron 03:00 Europe/Rome) │
            │                                     │
            │  ~/docker/backup.sh                 │
            │    1. pg_dumpall  forgejo-db        │
            │    2. pg_dumpall  analytics-postgres│
            │    3. mariadb-dump cinebase-mariadb │
            │    4. tar volume  media-uploads     │
            │    5. tar file    forgejo/data      │
            │                   registry/auth     │
            │                   traefik/certifs   │
            │    6. tar.gz unico  → ~/backup/     │
            │    7. oci os object put             │
            │       --auth instance_principal     │
            └────────────────┬────────────────────┘
                             │ HTTPS
                             ▼
            ┌─────────────────────────────────────┐
            │  OCI Object Storage                 │
            │  bucket: s1-backup                  │
            │  retention: 30 gg (via script)      │
            └─────────────────────────────────────┘

Autenticazione server → OCI:
   Instance Principal (Dynamic Group + Policy IAM)
   Nessuna API key sul server, nessun segreto in .env
```

L'**Instance Principal** è il meccanismo di OCI per cui un'istanza compute si autentica ad altri servizi OCI usando la propria identità, senza chiavi API. È la best practice per i workload server-side: se il server viene compromesso, l'attaccante può solo scrivere nel bucket (non ha credenziali riutilizzabili altrove).

---

## 2. Prerequisiti

| Prerequisito | Dove | Come verificarlo |
|---|---|---|
| OCI CLI installata sul **PC locale** | Windows | `oci --version` |
| OCI CLI installata sul **server s1** | Ubuntu | `oci --version` (vedi §4) |
| File `.env` popolato nel repo | `tenant/servers/s1/.env` | deve avere `BACKUP_BUCKET_NAME`, `OCI_COMPARTMENT_ID`, `OCI_INSTANCE_ID`, `OCI_TENANCY_ID`, `OCI_REGION`, `S1_IP`, `S1_SSH_USER`, `S1_SSH_KEY` |
| Stack applicativo attivo | server s1 | `docker ps` mostra `forgejo-db`, `analytics-postgres`, `cinebase-mariadb`, `cinebase-web` |

> Istruzioni per installare OCI CLI su Windows: [Oracle docs](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) o `pip install oci-cli`.

---

## 3. Fase 1 — Setup OCI lato cloud (dal PC, una tantum)

Tutti i comandi vanno eseguiti dal **PC locale** in Git Bash (o PowerShell), dalla root del repo `oracle-servers/`. Prima carica le variabili d'ambiente:

**Git Bash** (consigliato):
```bash
set -a; source tenant/servers/s1/.env; set +a
```

**PowerShell**:
```powershell
Get-Content tenant\servers\s1\.env | ForEach-Object { if ($_ -match '^([^#].+?)=(.+)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
```

### 3.1 Login OCI CLI via browser (session auth)

Esegui (sostituisci la region con la tua):

```bash
oci session authenticate --region "${OCI_REGION}"
```

Si aprirà il browser. Completa il login con le credenziali del tuo tenant OCI. A login completato, la CLI chiede un nome profilo: **sceglierne uno e ricordalo** (es. `malafronte_def`). Il valore va poi riflesso come `OCI_SESSION_PROFILE` nel `.env` di `tenant/servers/s1/`. Non è obbligatorio usare lo stesso nome del `.env.example`: è una scelta libera, ma va tenuta allineata tra CLI e `.env`.

> Se hai già una sessione scaduta con lo stesso profile name, la CLI fallisce con `FileNotFoundError: ...oci_api_key.pem`. Soluzione: elimina la directory `~/.oci/sessions/<profile>/` e rifai `oci session authenticate`.

Verifica che la sessione sia attiva:

```bash
oci iam region list --auth security_token --profile "${OCI_SESSION_PROFILE}"
```

Da questo momento, tutti i comandi `oci` su PC richiedono i flag `--auth security_token --profile "${OCI_SESSION_PROFILE}"` (Git Bash) o `--auth security_token --profile $env:OCI_SESSION_PROFILE` (PowerShell). La sessione scade dopo ~1 ora; rinnovare con lo stesso comando.

### 3.2 Creazione bucket `s1-backup`

```bash
oci os bucket create \
  --name "${BACKUP_BUCKET_NAME}" \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --auth security_token --profile "${OCI_SESSION_PROFILE}"
```

Verifica:

```bash
oci os bucket get \
  --name "${BACKUP_BUCKET_NAME}" \
  --auth security_token --profile "${OCI_SESSION_PROFILE}" \
  --query "data.{name:name,namespace:namespace,compartment:compartment-id}" \
  --output table
```

### 3.3 Recupero OCID dell'istanza s1

Se non hai già `OCI_INSTANCE_ID` nel `.env`, recuperarlo ora:

```bash
oci compute instance list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --query "data[*].{name:\"display-name\",id:id,state:\"lifecycle-state\"}" \
  --auth security_token --profile "${OCI_SESSION_PROFILE}" \
  --output table
```

Copia l'OCID dell'istanza `malafronte-oci-s1` e inseriscilo in `.env` come `OCI_INSTANCE_ID`.

### 3.4 Dynamic Group (via Console OCI)

L'Instance Principal richiede un **Dynamic Group** che includa l'istanza s1.

1. Apri la Console OCI: **Identity & Security → Domains → Dynamic Groups** (o in tenancy vecchie: **Identity → Dynamic Groups**).
2. **Create Dynamic Group**:
   - **Name**: `server-s1`
   - **Description**: `Server malafronte-oci-s1 per backup su Object Storage`
   - **Rule** (rule type Match any):
     ```
     Any { instance.id = 'OCID_DELLA_TUA_ISTANZA' }
     ```
     Sostituisci con il valore di `${OCI_INSTANCE_ID}`.
3. **Create**.

Verifica (dal PC, dopo ~30 secondi di propagazione IAM):

```bash
oci iam dynamic-group list \
  --auth security_token --profile "${OCI_SESSION_PROFILE}" \
  --query "data[?name=='server-s1'].{name:name,id:id}" \
  --output table
```

### 3.5 Policy IAM

La policy autorizza il Dynamic Group `server-s1` a gestire gli oggetti nel bucket.

1. **Console OCI → Identity & Security → Policies → Create Policy**.
2. **Name**: `s1-backup-policy`
3. **Compartment**: il tuo tenancy root (o il compartment dove sta il bucket).
4. **Policy statements** (una riga; la policy è nel **root tenancy**, quindi si usa la keyword `tenancy` e non `compartment <nome>`):

   ```
   Allow dynamic-group server-s1 to manage objects in tenancy where target.bucket.name='s1-backup'
   ```

   Per consentire anche il list dei bucket (utile per diagnostica):

   ```
   Allow dynamic-group server-s1 to read buckets in tenancy where target.bucket.name='s1-backup'
   ```

In alternativa via CLI (richiede permessi da amministratore tenancy). Le statements vanno passate come array JSON tramite `file://` per evitare problemi di escaping delle graffe e degli apici:

```bash
# Scrivi le statements su file temporaneo
cat > /tmp/policy.json <<EOF
["Allow dynamic-group server-s1 to manage objects in tenancy where target.bucket.name='${BACKUP_BUCKET_NAME}'","Allow dynamic-group server-s1 to read buckets in tenancy where target.bucket.name='${BACKUP_BUCKET_NAME}'"]
EOF

oci iam policy create \
  --name s1-backup-policy \
  --compartment-id "${OCI_TENANCY_ID}" \
  --description "Permette a server-s1 di gestire oggetti nel bucket ${BACKUP_BUCKET_NAME}" \
  --statements file:///tmp/policy.json \
  --auth security_token --profile "${OCI_SESSION_PROFILE}"
```

> **Importante**: in una policy creata nel root tenancy (compartment = tenancy), le statements devono usare la parola chiave `tenancy`, non `compartment <nome-tenancy>`. Usare `compartment <nome>` produce l'errore `Compartment {nome} does not exist or is not part of the policy compartment subtree`.

> **PowerShell — attenzione all'unwrap di array con un solo elemento**: se crei le statements in PowerShell con `@("statement")` e poi `ConvertTo-Json`, l'array di un solo elemento viene "unwrappato" a stringa singola, producendo `"statement"` invece di `["statement"]`. La CLI fallisce con `InvalidParameter`. Soluzione: usare `ConvertTo-Json -AsArray` (PowerShell 7+) o scrivere il JSON a mano nel file temporaneo.

---

## 4. Fase 2 — Installazione OCI CLI sul server

Connettiti al server (dal PC):

```bash
ssh -i "${S1_SSH_KEY}" "${S1_SSH_USER}@${S1_IP}"
```

Sul server, installa la CLI con lo script ufficiale Oracle (lo snap `oci-cli` è deprecato e non più disponibile). Lo script installa in `~/bin/oci` dell'utente corrente (no sudo), creando un virtualenv dedicato:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
```

L'installazione richiede ~2–3 minuti (scarica dipendenze Python). Lo script aggiorna automaticamente `~/.bashrc` con `~/bin` nel PATH.

Verifica:

```bash
# Ricarica la shell per aggiornare PATH (o apri nuova sessione SSH)
hash -r
oci --version
which oci
```

Output atteso: `oci 3.x.x` in `/home/ubuntu/bin/oci`.

> Lo script `~/docker/backup.sh` esporta già `export PATH="$HOME/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"` all'inizio, perché il cron ha un PATH minimale di default e non avrebbe altrimenti accesso a `~/bin/oci`.

Verifica che l'istanza veda la propria identità:

```bash
curl -sH "Authorization: Bearer Oracle" \
  http://169.254.169.254/opc/v2/instance/ | jq -r .displayName
```

Deve restituire `malafronte-oci-s1`. Se restituisce `404 not found`, riprova con `http://169.254.169.254/opc/v1/instance/` (v1 fallback).

---

## 5. Fase 3 — Verifica Instance Principal

Sempre sul server, verifica che possa leggere il bucket:

```bash
oci os object list \
  --bucket-name "${BACKUP_BUCKET_NAME}" \
  --auth instance_principal
```

Deve restituire `{"data": []}` (bucket vuoto = OK).

Se ricevi `NotAuthorizedOrNotFound` o `404`:
1. Verifica che l'OCID istanza nel Dynamic Group sia corretto (§3.3).
2. Verifica che la policy sia nel compartment corretto (quello del bucket).
3. Aspetta 1–2 minuti per la propagazione IAM.
4. Verifica con `oci iam compartment list --auth instance_principal` che l'istanza veda il compartment.

---

## 6. Fase 4 — Deploy dello script di backup sul server

### 6.1 SCP dello script aggiornato (dal PC)

```bash
scp -i "${S1_SSH_KEY}" \
  tenant/servers/s1/scripts/10-setup-backup.sh \
  "${S1_SSH_USER}@${S1_IP}:~/scripts/"
```

### 6.2 Esecuzione (sul server)

```bash
ssh -i "${S1_SSH_KEY}" "${S1_SSH_USER}@${S1_IP}"
```

Sul server:

```bash
# Assicurati che ~/scripts/.env sia aggiornato (deve contenere BACKUP_BUCKET_NAME)
grep '^BACKUP_BUCKET_NAME=' ~/scripts/.env

# Esegui il setup (idempotente)
bash ~/scripts/10-setup-backup.sh
```

Output atteso:
- `~/docker/backup.sh` creato
- `~/docker/deploy.sh` creato
- `~/backup/` directory creata
- cron job configurato (`crontab -l | grep backup` mostra `0 3 * * * /home/ubuntu/docker/backup.sh`)

Verifica il cron:

```bash
crontab -l | grep backup
```

---

## 7. Fase 5 — Test manuale del backup

Esegui il backup manualmente per la prima volta, così vedi subito eventuali errori:

```bash
~/docker/backup.sh
```

L'output mostra, in sequenza:
1. dump PostgreSQL Forgejo
2. dump PostgreSQL Analytics
3. dump MariaDB CineBase
4. tar volume media-uploads
5. copia file statici
6. composizione archivio
7. upload OCI

Verifica il log:

```bash
tail -30 ~/backup/backup.log
```

Verifica l'archivio locale:

```bash
ls -lh ~/backup/
du -sh ~/backup/s1-backup-*.tar.gz
```

Verifica che l'archivio contenga i dump attesi:

```bash
tar tzf ~/backup/s1-backup-$(date +%Y-%m-%d).tar.gz | head -20
```

Devono comparire almeno:
- `./forgejo-postgres-YYYYMMDD.sql`
- `./analytics-postgres-YYYYMMDD.sql`
- `./cinebase-mariadb-YYYYMMDD.sql`
- `./cinebase-media-uploads-YYYYMMDD.tar.gz`
- `./forgejo-data.tar.gz`
- `./registry-auth.tar.gz`
- `./traefik-certificates.tar.gz` (contiene anche `acme.json`)

> I file statici sono archiviati come singoli `.tar.gz` dentro l'archivio master (per gestire file root-only come `acme.json` 0600 e i dati di forgejo di proprietà `opc`). La lettura avviene via container Docker (gira come root) — niente `sudo` sul server.

---

## 8. Fase 6 — Verifica upload su OCI (dal PC)

Torna sul PC. Carica le variabili (§3) e la session auth se scaduta (§3.1). Verifica il file caricato:

```bash
oci os object list \
  --bucket-name "${BACKUP_BUCKET_NAME}" \
  --auth security_token --profile "${OCI_SESSION_PROFILE}" \
  --query "data[*].{name:name,size:\"size\"}" \
  --output table
```

Dettaglio del singolo oggetto (dimensione, MD5, data):

```bash
oci os object head \
  --bucket-name "${BACKUP_BUCKET_NAME}" \
  --name "s1-backup-$(date +%Y-%m-%d).tar.gz" \
  --auth security_token --profile "${OCI_SESSION_PROFILE}"
```

---

## 9. Fase 7 — Retention automatica (gestita dallo script)

La retention degli oggetti su OCI è gestita **direttamente dallo script `~/docker/backup.sh`** alla fine di ogni esecuzione, non da una lifecycle rule del bucket. Questo approccio è stato scelto perché:

- non richiede una **policy service aggiuntiva** (`Allow service objectstorage-<region> to manage object-family in tenancy where ...`) che la CLI crea con prompt interattivi;
- funziona in qualsiasi condizione di tenancy/identity domain;
- il server ha già accesso in scrittura via Instance Principal (dalla `s1-backup-policy`).

### 9.1 Come funziona

Dopo l'upload, lo script:

1. calcola il cutoff (`oggi - RETENTION_DAYS_REMOTE` giorni, default 30);
2. lista tutti gli oggetti `s1-backup-YYYY-MM-DD.tar.gz` nel bucket;
3. cancella quelli con data `< cutoff`.

La data è parsata dal nome file (formato ISO `YYYY-MM-DD`), non dai metadati OCI, per essere deterministica.

### 9.2 Parametri configurabili

Nel `backup.sh` generato:

```bash
RETENTION_DAYS_LOCAL=3     # backup salvati sul server (~/backup/)
RETENTION_DAYS_REMOTE=30   # backup salvati su OCI Object Storage
```

Per cambiarli, modifica `10-setup-backup.sh` (le costanti sono nel blocco `BACKUPEOF` dell'heredoc) e ri-eseguilo sul server.

### 9.3 Opzione alternativa: lifecycle rule del bucket

Se preferisci gestire la retention lato OCI (funziona anche col server spento), imposta una lifecycle rule via Console:

1. **Console OCI → Storage → Buckets → s1-backup → Lifecycle Policy Rules → Create Rule**
2. Name: `retention-30gg`, Action: Delete Object, Days: `30`, filter vuoto.
3. **Prerequisito** (importante): serve una policy service aggiuntiva nel root tenancy:

   ```
   Allow service objectstorage-eu-milan-1 to manage object-family in tenancy where target.bucket.name='s1-backup'
   ```

   Nota il verbo **`object-family`** (non `objects`) — è obbligatorio per le lifecycle rule. La policy va creata in Console perché la CLI richiede prompt interattivi per il `policy update` con statements.

Se usi entrambi (script retention + lifecycle rule), l'oggetto viene cancellato dal primo che scatta.

> La retention locale è di **3 giorni** (`find ... -mtime +3 -delete`), la retention remota di **30 giorni**. L'obiettivo è dare profondità storica su OCI senza intasare il disco del server.

---

## 10. Fase 8 — Monitoring e verifiche periodiche

### 10.1 Netdata + Telegram (già attivo)

Lo script `~/docker/netdata/check-backup-size.sh` (generato da `08-setup-netdata.sh`) controlla ogni ora la dimensione delle directory raw / degli archivi e invia un alert Telegram se:
- 🟡 **WARNING** > 9 GB
- 🔴 **CRITICAL** > 9,5 GB (quota 10 GB)

Se supera la soglia, l'evento più probabile è la retention OCI non applicata (verifica §9) o un dump SQL cresciuto anomalo.

### 10.2 Verifica periodica (es. mensile)

Dal PC, controlla che il backup del giorno prima sia presente:

```bash
oci os object list \
  --bucket-name "${BACKUP_BUCKET_NAME}" \
  --auth security_token --profile "${OCI_SESSION_PROFILE}" \
  --query "data[*].name" --output table
```

### 10.3 Test di restore (consigliato trimestralmente)

Vedi §11. Un backup non testato è un backup che non si sa se funziona.

### 10.4 Test della retention remota (consigliato al primo setup)

Per verificare che la retention via script stia effettivamente cancellando i backup vecchi su OCI, crea un backup fittizio datato 60 giorni fa ed esegui un backup reale: la retention deve cancellare quello fittizio.

**Sul server:**

```bash
# 1. Crea e carica un backup fittizio con data 60 giorni fa
OLD_DATE=$(date -d "60 days ago" +%Y-%m-%d)
echo "fake-old-backup" > /tmp/fake.tar.gz
oci os object put --bucket-name "${BACKUP_BUCKET_NAME}" \
  --file /tmp/fake.tar.gz \
  --name "s1-backup-${OLD_DATE}.tar.gz" \
  --auth instance_principal --force

# 2. Verifica che il bucket abbia 2 oggetti (finto + oggi)
oci os object list --bucket-name "${BACKUP_BUCKET_NAME}" --auth instance_principal --query "data[*].name"

# 3. Esegui il backup reale (lancia anche la retention)
~/docker/backup.sh

# 4. Verifica che il backup fittizio sia stato cancellato
oci os object list --bucket-name "${BACKUP_BUCKET_NAME}" --auth instance_principal --query "data[*].name"

# 5. Cleanup del file temporaneo locale
rm /tmp/fake.tar.gz
```

**Output atteso** nello step 3 (in fondo al log):

```
[...] Retention remota: elimina oggetti con data < <cutoff>...
[...]    Deleted s1-backup-<OLD_DATE>.tar.gz (data <OLD_DATE>)
[...]    Retention remota: 1 oggetti eliminati.
```

Dove `<cutoff>` è la data di "oggi - 30 giorni" e `<OLD_DATE>` è "oggi - 60 giorni" (quindi precedente al cutoff).

Se il backup fittizio **non** viene cancellato, verificare:
- che il nome rispetti esattamente il pattern `s1-backup-YYYY-MM-DD.tar.gz` (la data è parsata dal nome con `grep -oE` + `sed`, non dai metadati OCI);
- che `date -d` funzioni (GNU date, standard su Ubuntu);
- che il cutoff sia effettivamente `oggi - 30 giorni` (verifica con `date -d "30 days ago" +%Y-%m-%d`).

---

## 11. Procedura di ripristino (restore)

> **Importante — nomi oggetto**: i backup si chiamano `s1-backup-YYYY-MM-DD.tar.gz` dove `YYYY-MM-DD` è la **data reale** del backup (es. `s1-backup-2026-06-18.tar.gz`). Nei comandi seguenti puoi usare `$(date +%Y-%m-%d)` per scaricare il backup di **oggi** (la shell lo espande), oppure sostituire con la data esplicita del backup che vuoi scaricare. Per vedere le date disponibili:
>
> ```bash
> oci os object list --bucket-name "${BACKUP_BUCKET_NAME}" \
>   --auth security_token --profile "${OCI_SESSION_PROFILE}" \
>   --query "data[*].name" --output table
> ```

### 11.1 Download dell'archivio (dal server o dal PC)

**Sul server** (Instance Principal):

```bash
# Backup di oggi (la shell espande $(date +%Y-%m-%d))
oci os object get \
  --bucket-name "${BACKUP_BUCKET_NAME}" \
  --name "s1-backup-$(date +%Y-%m-%d).tar.gz" \
  --file /tmp/restore.tar.gz \
  --auth instance_principal

# Oppure un backup specifico:
# oci os object get --bucket-name "${BACKUP_BUCKET_NAME}" \
#   --name "s1-backup-2026-06-18.tar.gz" --file /tmp/restore.tar.gz \
#   --auth instance_principal
```

**Dal PC** (session auth):

```bash
oci os object get \
  --bucket-name "${BACKUP_BUCKET_NAME}" \
  --name "s1-backup-$(date +%Y-%m-%d).tar.gz" \
  --file ./restore.tar.gz \
  --auth security_token --profile "${OCI_SESSION_PROFILE}"
```

### 11.2 Estrazione

```bash
mkdir -p /tmp/restore && tar xzf /tmp/restore.tar.gz -C /tmp/restore
ls /tmp/restore
```

> Dopo `ls /tmp/restore` vedrai i nomi reali dei file estratti (es. `forgejo-postgres-20260618.sql`, `cinebase-mariadb-20260618.sql`, ecc.). Nei comandi delle sezioni 11.3–11.6, **sostituisci `YYYYMMDD` con la data reale** che vedi nell'output di `ls`. Per il backup di oggi, in Git Bash/Linux puoi usare `$(date +%Y%m%d)` (nota: formato compatto senza trattini, diverso da `$(date +%Y-%m-%d)` usato per il nome archivio).

### 11.3 Restore PostgreSQL Forgejo

```bash
# Fermare i servizi che usano il DB
docker compose -f ~/docker/forgejo/docker-compose.yml stop forgejo

# Ripristinare (pg_dumpall ricrea ruoli + database)
docker exec -i forgejo-db psql -U forgejo -d postgres < /tmp/restore/forgejo-postgres-YYYYMMDD.sql

# Riavviare
docker compose -f ~/docker/forgejo/docker-compose.yml up -d
```

### 11.4 Restore PostgreSQL Analytics (Waline + Umami)

```bash
docker compose -f ~/docker/analytics/docker-compose.yml stop waline umami
docker exec -i analytics-postgres psql -U analytics -d postgres < /tmp/restore/analytics-postgres-YYYYMMDD.sql
docker compose -f ~/docker/analytics/docker-compose.yml up -d
```

### 11.5 Restore MariaDB CineBase

```bash
docker compose -f ~/docker/cinebase/docker-compose.yml stop filmapi cinebase-web seeder
docker exec -i cinebase-mariadb mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" < /tmp/restore/cinebase-mariadb-YYYYMMDD.sql
docker compose -f ~/docker/cinebase/docker-compose.yml up -d
```

### 11.6 Restore media-uploads

```bash
MEDIA_VOL=$(docker volume ls --filter name=media-uploads -q | head -n1)
docker run --rm \
  -v "${MEDIA_VOL}:/data" \
  -v /tmp/restore:/backup:ro \
  alpine sh -c 'rm -rf /data/* && tar xzf /backup/cinebase-media-uploads-YYYYMMDD.tar.gz -C /data'
```

### 11.7 Restore file statici (forgejo/data, registry/auth, traefik/certificates)

I file statici sono archiviati come singoli `.tar.gz` (per poter leggere file root-only). Estrazione via container helper (gira come root) per preservare ownership/permessi originali:

```bash
# Estrai prima l'archivio master
mkdir -p /tmp/restore && tar xzf /tmp/restore.tar.gz -C /tmp/restore

# Poi estrai i singoli tar statici al loro posto (usa docker per i permessi)
MEDIAhelper() {
  local tarball="/tmp/restore/$1" dest="$2"
  [ -f "$tarball" ] || { echo "manca $tarball"; return; }
  sudo mkdir -p "$dest"
  sudo docker run --rm \
    -v "$tarball:/backup.tar.gz:ro" \
    -v "$dest:/dest" \
    alpine tar xzf /backup.tar.gz -C /dest
}

MEDIAhelper forgejo-data.tar.gz         "$HOME/docker/forgejo/data"
MEDIAhelper registry-auth.tar.gz        "$HOME/docker/registry/auth"
MEDIAhelper traefik-certificates.tar.gz "$HOME/docker/traefik/certificates"
```

Riavvia i relativi stack dopo il restore. Verifica i permessi (Forgejo gira come UID 1000, `acme.json` deve restare `0600` di root).

---

## 12. Troubleshooting

### `oci: command not found` sul server

Lo snap `oci-cli` è **deprecato e non più disponibile** sullo snap store. Installa con lo script ufficiale Oracle (come utente `ubuntu`, NO sudo):

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
hash -r          # ricarica tabella comandi della shell
exec -l $SHELL   # oppure apri nuova sessione SSH per ricaricare ~/.bashrc
```

Lo script installa in `~/bin/oci` (virtualenv in `~/.cli_virtualenv`). Se per qualche motivo lo script Oracle non funzionasse, fallback con `pip`:

```bash
sudo apt update && sudo apt install -y python3-pip
sudo pip3 install --break-system-packages oci-cli
```

### Instance Principal: `NotAuthorizedOrNotFound`

Cause possibili:
1. OCID istanza nel Dynamic Group non coincide (verifica §3.3 e §3.4).
2. Policy creata nel compartment sbagliato (deve essere il compartment del bucket).
3. Propagazione IAM non ancora completata (attendi 1–2 min).
4. Nome bucket nella policy con typo o case mismatch (OCI è case-sensitive).

Debug:

```bash
# Sul server, verifica cosa vede l'istanza
oci iam compartment list --auth instance_principal --query "data[*].name" --output table
```

### Dump MariaDB fallisce: `Access denied`

`MYSQL_ROOT_PASSWORD` non viene letto. Verifica:

```bash
grep '^MYSQL_ROOT_PASSWORD=' ~/docker/cinebase/.env
```

Se manca, aggiorna il `.env` di CineBase. Lo script lo carica automaticamente.

> **Nota tecnica**: il backup.sh **non fa `source`** del `.env` di CineBase, perché quel file contiene valori con caratteri speciali (es. `ADMIN_SEED_PASSWORD=...==)KLLqwe`, JWT con `!`, `)`, `==`) che farebbero esplodere la shell con `syntax error near unexpected token ')'`. Lo script estrae invece solo le variabili strettamente necessarie (`BACKUP_BUCKET_NAME`, `MYSQL_ROOT_PASSWORD`) tramite una funzione `load_var()` che fa `grep` + `sed`. È per questo che se aggiungi una dipendenza da una nuova variabile del `.env` di CineBase, devi aggiungere una `load_var` corrispondente nello script.

### Dump PostgreSQL Analytics fallisce: `database waline does not exist`

Lo schema è stato inizializzato ma i database non sono presenti. Esegui `init-db.sql` di analytics:

```bash
docker exec -i analytics-postgres psql -U analytics -d postgres < ~/docker/analytics/init-db.sql
```

### Upload OCI fallisce con `OutOfHostCapacity` o `500`

Riprova: è un errore transiente di OCI. Lo script non ritenta in automatico (per evitare di sovrascrivere backup parziali), ma la retention locale di 3 giorni permette di fare upload manuale. Sostituisci `YYYY-MM-DD` con la data del file già presente in `~/backup/`:

```bash
# Vedi quali backup locali hai
ls -lh ~/backup/

# Carica manualmente quello che ti interessa
oci os object put --bucket-name "${BACKUP_BUCKET_NAME}" \
  --file ~/backup/s1-backup-YYYY-MM-DD.tar.gz \
  --name s1-backup-YYYY-MM-DD.tar.gz \
  --auth instance_principal --force
```

> Qui `YYYY-MM-DD` va sostituito **manualmente** con la data reale del file (es. `2026-06-18`) — non è un placeholder espandibile dalla shell in questo contesto.

### Il backup cresce oltre 9 GB (alert Telegram)

Verifica:
1. Che la retention remota via script sia funzionante: nell'output dell'ultimo backup deve comparire `Retention remota: N oggetti eliminati` oppure `nessun oggetto da eliminare` (vedi §9 e §10.4 per il test).
2. La dimensione dei singoli dump:

   ```bash
   ls -lh ~/backup/
   ```

3. Se `forgejo/data` è cresciuto (allegati LFS), valuta di escludere pattern specifici dal tar (modificare `10-setup-backup.sh` e ri-eseguirlo).

### Cron non gira

```bash
# Stato del servizio cron
sudo systemctl status cron

# Log di sistema
grep CRON /var/log/syslog | tail -20

# Verifica che la riga ci sia
crontab -l | grep backup

# Esegui manualmente per vedere l'errore
~/docker/backup.sh
```

---

## 13. Riferimenti

- Script generatore: [`10-setup-backup.sh`](../servers/s1/scripts/10-setup-backup.sh)
- Script runtime (sul server): `~/docker/backup.sh`
- Setup OCI base: [`oci-setup/README.md`](../servers/s1/oci-setup/README.md)
- Documentazione Oracle:
  - [Instance Principal](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/callingservicesfrominstances.htm)
  - [Object Storage lifecycle policies](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/usinglifecyclepolicies.htm)
  - [OCI CLI reference](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/)
- Guide correlate:
  - [Guida Waline + Umami](guida-deploy-waline-umami.md) (il cui DB è backuppato qui)
  - [Guida primo deploy CineBase](guida-primo-deploy-cinebase.md) (il cui DB è backuppato qui)
  - [Guida Telegram Bot](guida-telegram-bot.md) (alert del check-backup-size.sh)

---

*Questa guida integra la sezione "Backup" del [`README.md`](../../README.md) con la procedura operativa completa. Per la policy di cosa viene backuppato e perché, fare riferimento a quel documento.*
