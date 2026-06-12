# OCI Setup — Comandi da eseguire localmente (Windows)

Questi comandi vanno eseguiti dal tuo PC Windows dove hai già configurato la OCI CLI.

> **Carica le variabili d'ambiente prima di eseguire i comandi.**
> Esegui dalla **root del repository** (`oracle-servers/`):
>
> **Git Bash / WSL** (consigliato):
> ```bash
> set -a; source tenant/servers/s1/.env; set +a
> ```
>
> **PowerShell**:
> ```powershell
> Get-Content tenant\servers\s1\.env | ForEach-Object { if ($_ -match '^([^#].+?)=(.+)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
> ```
>
> I comandi sotto sono mostrati per entrambi gli ambienti. In **PowerShell** le variabili
> si referenziano con `$env:VAR`, in **Git Bash** con `$VAR` o `${VAR}`.

## 1. Creare il bucket per i backup

Il bucket usa lo storage **Always Free** (10 GB Standard).

**PowerShell:**
```powershell
oci os bucket create --name $env:BACKUP_BUCKET_NAME --compartment-id $env:OCI_COMPARTMENT_ID
```

**Git Bash:**
```bash
oci os bucket create --name $BACKUP_BUCKET_NAME --compartment-id $OCI_COMPARTMENT_ID
```

Verifica:

**PowerShell:**
```powershell
oci os bucket list --compartment-id $env:OCI_COMPARTMENT_ID --query "data[?name=='$env:BACKUP_BUCKET_NAME']"
```

**Git Bash:**
```bash
oci os bucket list --compartment-id $OCI_COMPARTMENT_ID --query "data[?name=='$BACKUP_BUCKET_NAME']"
```

## 2. Creare il Dynamic Group (Instance Principal)

L'Instance Principal permette al server di autenticarsi automaticamente
con OCI senza bisogno di chiavi o file di configurazione.

### 2.1 Ottieni l'OCID dell'istanza

Dalla console OCI: **Compute → Instances → <NOME_SERVER> → OCID**

Oppure via CLI:

**PowerShell:**
```powershell
oci compute instance list --compartment-id $env:OCI_COMPARTMENT_ID --display-name <NOME_SERVER> --query "data[0].id"
```

**Git Bash:**
```bash
oci compute instance list --compartment-id $OCI_COMPARTMENT_ID --display-name <NOME_SERVER> --query "data[0].id"
```

### 2.2 Crea il Dynamic Group

Vai su **Console OCI → Identity & Security → Dynamic Groups → Create Dynamic Group**:

- **Nome**: `server-s1`
- **Descrizione**: `Server <NOME_SERVER>`
- **Regola** (usa l'OCID dal tuo `.env`):
  ```
  Any { instance.id = 'OCID_DELLA_TUA_INSTANZA' }
  ```
  L'OCID è nella variabile `${OCI_INSTANCE_ID}` (Git Bash) o `$env:OCI_INSTANCE_ID` (PowerShell).

### 2.3 Crea la Policy IAM

Vai su **Console OCI → Identity & Security → Policies → Create Policy**:

- **Nome**: `s1-backup-policy`
- **Descrizione**: `Permette al server s1 di gestire oggetti nel bucket ${BACKUP_BUCKET_NAME}`
- **Compartment**: il tuo tenancy root
- **Policy** (sostituisci `<nome-tenancy>` con il nome del tuo tenancy — lo trovi in Profile → Tenancy):
  ```
  Allow dynamic-group server-s1 to manage objects in compartment <nome-tenancy> where target.bucket.name='NOME_BUCKET'
  ```
  Il nome bucket è nella variabile `${BACKUP_BUCKET_NAME}`.

## 3. Verificare l'Instance Principal sul server

Connettiti al server e installa la OCI CLI:

**Git Bash / WSL:**
```bash
ssh -i ${S1_SSH_KEY} ${S1_SSH_USER}@${S1_IP}
```

**PowerShell:**
```powershell
ssh -i $env:S1_SSH_KEY $env:S1_SSH_USER@$env:S1_IP
```

Poi sul server:
```bash
# Installa OCI CLI
sudo snap install oci-cli --classic

# Verifica che l'Instance Principal funzioni
oci os object list --bucket-name ${BACKUP_BUCKET_NAME} --auth instance_principal
```

L'output dovrebbe essere `{"data": []}` (bucket vuoto = OK).

Se ricevi un errore di autorizzazione:
1. Verifica che l'OCID dell'istanza nel Dynamic Group sia corretto
2. Verifica che la policy sia stata creata nel compartment giusto
3. Aspetta qualche minuto (la propagazione IAM può richiedere fino a 1-2 minuti)

## 4. Installare la OCI CLI sul server (via Snap)

```bash
# Sul server:
sudo snap install oci-cli --classic

# Verifica
oci --version
```

Dopo questo setup, lo script `10-setup-backup.sh` sul server potrà usare
`oci os object put --auth instance_principal` per caricare i backup.
