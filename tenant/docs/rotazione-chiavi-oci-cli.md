# Protezione e rotazione chiave API OCI CLI

La chiave API OCI è usata dalla CLI per autenticare le richieste via firma RSA.

Questa guida copre:
- Aggiungere una passphrase alla chiave esistente
- Consolidare i segreti nella cartella `.secrets/` del repository
- Ruotare completamente la coppia di chiavi

> **Nota**: i valori OCID, fingerprint, percorso chiave e regione sono centralizzati
> in `tenant/servers/s1/.env`. I comandi sotto usano variabili `${OCI_KEY_FILE}`,
> `${OCI_FINGERPRINT}`, `${OCI_USER_ID}`, `${OCI_TENANCY_ID}`, `${OCI_REGION}`,
> `${OCI_SESSION_PROFILE}`, `${OCI_COMPARTMENT_ID}`.
> Carica il `.env` prima di eseguire:
> ```powershell
> Get-Content tenant\servers\s1\.env | ForEach-Object { if ($_ -match '^([^#].+?)=(.+)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
> ```
> **Git Bash**:
> ```bash
> set -a; source tenant/servers/s1/.env; set +a
> ```

---

## Permessi file su Windows (prerequisito)

Su Windows, alcune applicazioni (OpenSSL, OCI CLI, SSH) possono rifiutare chiavi private
con permessi troppo larghi. Se vedi errori di tipo `bad permissions` o `UNPROTECTED PRIVATE KEY`:

```powershell
# 1. Disabilita l'ereditarietà (converte gli ACE ereditati in espliciti)
icacls "tenant\.secrets\oci-cli\oci_api_key.pem" /inheritance:d

# 2. Rimuovi il gruppo che causa l'errore (es. CodexSandboxUsers)
icacls "tenant\.secrets\oci-cli\oci_api_key.pem" /remove "NOMEDOMINIO\GruppoProblema"

# 3. Verifica: solo SYSTEM, Administrators e il tuo utente
icacls "tenant\.secrets\oci-cli\oci_api_key.pem"
```

> L'errore è comune su macchine Windows aggiunte a domini aziendali (Azure AD / Active Directory).
> Il fix va applicato a ogni file di chiave privata (`.pem`, `.key`) prima dell'uso.
> **Git Bash** eredita gli stessi permessi NTFS — il fix con `icacls` copre entrambi gli ambienti.
>
> Se invece il file ha solo permesso di **lettura** (`(R)`), `openssl` non potrà scrivere il file
> criptato. Concedi il permesso di modifica:
>
> **PowerShell:**
> ```powershell
> icacls "tenant\.secrets\oci-cli\oci_api_key.pem" /grant "$env:USERNAME`:M"
> ```
>
> **Git Bash:**
> ```bash
> icacls "tenant/.secrets/oci-cli/oci_api_key.pem" /grant "$USERNAME:M"
> ```

---

## Scenario A: Aggiungere passphrase alla chiave esistente

La chiave pubblica resta identica. Nessuna modifica lato OCI.

### A.1 Aggiungi la passphrase con OpenSSL

**PowerShell:**
```powershell
openssl rsa -aes256 -in "<PERCORSO_OCI_CLI_KEYS>\oci_api_key.pem" -out "<PERCORSO_OCI_CLI_KEYS>\oci_api_key.pem"
```

**Git Bash:**
```bash
openssl rsa -aes256 -in "<PERCORSO_OCI_CLI_KEYS>/oci_api_key.pem" -out "<PERCORSO_OCI_CLI_KEYS>/oci_api_key.pem"
```

Inserisci la passphrase due volte. L'header del file diventerà:
```
-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-256-CBC,...
```

Dopo aver criptato la chiave, aggiungi la riga `OCI_API_KEY` in fondo al file.
È una raccomandazione OCI per marcare il file come chiave API (sopprime un warning della CLI):

**PowerShell:**
```powershell
Add-Content "<PERCORSO_OCI_CLI_KEYS>\oci_api_key.pem" "OCI_API_KEY"
```

**Git Bash:**
```bash
echo "OCI_API_KEY" >> "<PERCORSO_OCI_CLI_KEYS>/oci_api_key.pem"
```

### A.2 Verifica che la CLI funzioni ancora

```powershell
# Stesso comando per entrambi gli ambienti
oci iam region list
# Ti chiederà la passphrase. Se vedi l'elenco delle region, funziona.
```

### A.3 Ridurre la frequenza di richiesta passphrase

La OCI CLI chiede la passphrase a **ogni** comando. Soluzioni:

1. **Autenticazione browser-based** (salta completamente la chiave API):
   ```powershell
   oci session authenticate --region eu-milan-1
   # Apre il browser, fai login OCI.
   # Ti chiederà un nome profilo (es. <NOME_PROFILO>). Scegline uno e ricordalo.
   # Il token vale 1 ora e viene salvato in ~/.oci/config.
   ```
   (Comando identico in PowerShell e Git Bash)

   Dopo il login, tutti i comandi OCI vanno eseguiti con:
   ```powershell
   oci ... --profile <NOME_PROFILO> --auth security_token
   ```
   Esempio di verifica:
   ```powershell
   oci iam region list --profile <NOME_PROFILO> --auth security_token
   ```
   Il token scade dopo 1 ora. Per rinnovarlo, ripeti `oci session authenticate`.

2. **Passphrase in variabile d'ambiente** (meno sicuro, ma comodo per script):

   **PowerShell:**
   ```powershell
   $env:OCI_CLI_KEY_PASSPHRASE = "tua-passphrase"
   ```

   **Git Bash:**
   ```bash
   export OCI_CLI_KEY_PASSPHRASE="tua-passphrase"
   ```

   Attenzione: la passphrase finisce nella history della shell. Usalo solo in sessione interattiva.

3. **Configura `oci_cli_rc`** (da OCI CLI v3):

   **PowerShell:**
   ```powershell
   oci setup oci-cli-rc --file "$env:USERPROFILE\.oci\oci_cli_rc"
   ```

   **Git Bash:**
   ```bash
   oci setup oci-cli-rc --file "$HOME/.oci/oci_cli_rc"
   ```

   Poi modifica il file e imposta: `pass_phrase = <tua-passphrase>`, oppure lascialo vuoto e la CLI chiederà la passphrase a ogni comando.

---

## Scenario B: Consolidare i segreti nella cartella `.secrets/`

Sposta la chiave OCI dentro `.secrets/` in modo che sia protetta dal `.gitignore`
e facilmente reperibile insieme agli altri segreti del progetto.

### B.1 Copia le chiavi nella cartella `.secrets/`

**PowerShell:**
```powershell
# Dalla root del repository
New-Item -ItemType Directory -Force -Path "tenant\.secrets\oci-cli"

Copy-Item "<PERCORSO_OCI_CLI_KEYS>\oci_api_key.pem" "tenant\.secrets\oci-cli\"
Copy-Item "<PERCORSO_OCI_CLI_KEYS>\oci_api_key_public.pem" "tenant\.secrets\oci-cli\"
```

**Git Bash:**
```bash
# Dalla root del repository
mkdir -p "tenant/.secrets/oci-cli"

cp "<PERCORSO_OCI_CLI_KEYS>/oci_api_key.pem" "tenant/.secrets/oci-cli/"
cp "<PERCORSO_OCI_CLI_KEYS>/oci_api_key_public.pem" "tenant/.secrets/oci-cli/"
```

### B.2 Aggiungi passphrase (vedi Scenario A)

**PowerShell:**
```powershell
openssl rsa -aes256 -in "tenant\.secrets\oci-cli\oci_api_key.pem" -out "tenant\.secrets\oci-cli\oci_api_key.pem"
```

**Git Bash:**
```bash
openssl rsa -aes256 -in "tenant/.secrets/oci-cli/oci_api_key.pem" -out "tenant/.secrets/oci-cli/oci_api_key.pem"
```

### B.3 Aggiorna il config OCI CLI con il nuovo percorso

Modifica `<HOME>\\.oci\config` (percorso identico in entrambi gli ambienti):

```ini
[DEFAULT]
user=<OCID_USER>
fingerprint=<FINGERPRINT_CHIAVE_API>
key_file=<PERCORSO_LOCALE>\tenant\.secrets\oci-cli\oci_api_key.pem
tenancy=<OCID_TENANCY>
region=eu-milan-1
```

> **Importante per Git Bash**: il percorso nel config OCI deve usare backslash Windows (`\`), non forward slash. Il file `config` è letto dalla CLI OCI in modalità Windows.

### B.4 Verifica

```powershell
oci iam region list
# Deve chiedere la passphrase e mostrare le region
```
(Comando identico in PowerShell e Git Bash)

---

## Scenario C: Rotazione completa della chiave API OCI

Generi una nuova coppia, carichi la nuova chiave pubblica su OCI, elimini la vecchia.

### C.1 Genera la nuova coppia di chiavi

**PowerShell:**
```powershell
# Genera nuova chiave RSA 2048 con passphrase (formato PKCS#8)
openssl genpkey -algorithm RSA -out "tenant\.secrets\oci-cli\oci_api_key_nuova.pem" -pkeyopt rsa_keygen_bits:2048 -aes256

# Estrai la chiave pubblica (usa pkey, non rsa, perché la chiave è PKCS#8)
openssl pkey -pubout -in "tenant\.secrets\oci-cli\oci_api_key_nuova.pem" -out "tenant\.secrets\oci-cli\oci_api_key_nuova_public.pem"
```

**Git Bash:**
```bash
# Genera nuova chiave RSA 2048 con passphrase (formato PKCS#8)
openssl genpkey -algorithm RSA -out "tenant/.secrets/oci-cli/oci_api_key_nuova.pem" -pkeyopt rsa_keygen_bits:2048 -aes256

# Estrai la chiave pubblica
openssl pkey -pubout -in "tenant/.secrets/oci-cli/oci_api_key_nuova.pem" -out "tenant/.secrets/oci-cli/oci_api_key_nuova_public.pem"
```

### C.2 Carica la nuova chiave pubblica su OCI

**PowerShell:**
```powershell
$newFingerprint = oci iam user api-key upload `
  --user-id <OCID_USER> `
  --key-file "tenant\.secrets\oci-cli\oci_api_key_nuova_public.pem" `
  --query "data.fingerprint" --raw-output

Write-Host "Nuovo fingerprint: $newFingerprint"
```

**Git Bash:**
```bash
newFingerprint=$(oci iam user api-key upload \
  --user-id <OCID_USER> \
  --key-file "tenant/.secrets/oci-cli/oci_api_key_nuova_public.pem" \
  --query "data.fingerprint" --raw-output)

echo "Nuovo fingerprint: $newFingerprint"
# Esempio output: ab:12:cd:34:ef:56:gh:78:ij:90:kl:12:mn:34:op:56
```

> Il flag `--query "data.fingerprint" --raw-output` estrae solo il fingerprint, pronto per essere copiato nel config.
> La vecchia chiave **non** viene cancellata: ora hai due chiavi API attive sul tuo utente OCI.

### C.3 Aggiorna il config OCI CLI con il nuovo percorso e fingerprint

Modifica `<HOME>\\.oci\config` **sostituendo** il fingerprint e key_file:

```ini
[DEFAULT]
user=<OCID_USER>
fingerprint=<NUOVO_FINGERPRINT>    ← incolla qui l'output di C.2
key_file=<PERCORSO_LOCALE>\tenant\.secrets\oci-cli\oci_api_key_nuova.pem
tenancy=<OCID_TENANCY>
region=eu-milan-1
```

### C.4 Verifica che la nuova chiave funzioni

```powershell
oci iam region list
# Deve chiedere la passphrase e funzionare
```
(Comando identico in PowerShell e Git Bash)

### C.5 Elimina la vecchia chiave pubblica da OCI

**PowerShell:**
```powershell
# Elenca le chiavi API del tuo utente
oci iam user api-key list --user-id <OCID_USER>

# Elimina la vecchia (usa il vecchio fingerprint <FINGERPRINT_CHIAVE_API>)
oci iam user api-key delete --user-id <OCID_USER> --fingerprint <FINGERPRINT_CHIAVE_API>
```

**Git Bash:**
```bash
# Elenca le chiavi API del tuo utente
oci iam user api-key list --user-id <OCID_USER>

# Elimina la vecchia (usa il vecchio fingerprint)
oci iam user api-key delete --user-id <OCID_USER> --fingerprint <FINGERPRINT_CHIAVE_API>
```

### C.6 Pulisci i vecchi file e aggiorna il config (opzionale)

**PowerShell:**
```powershell
# Elimina i vecchi file
Remove-Item "tenant\.secrets\oci-cli\oci_api_key.pem" -Force
Remove-Item "tenant\.secrets\oci-cli\oci_api_key_public.pem" -Force

# Rinomina i nuovi file
Rename-Item "tenant\.secrets\oci-cli\oci_api_key_nuova.pem" "oci_api_key.pem"
Rename-Item "tenant\.secrets\oci-cli\oci_api_key_nuova_public.pem" "oci_api_key_public.pem"

# AGGIORNA il config OCI CLI! Il key_file ora punta a oci_api_key.pem (non più _nuova)
# Modifica <HOME>\\.oci\config, riga key_file:
#   key_file=<PERCORSO_LOCALE>\tenant\.secrets\oci-cli\oci_api_key.pem
```

**Git Bash:**
```bash
# Elimina i vecchi file
rm -f "tenant/.secrets/oci-cli/oci_api_key.pem" "tenant/.secrets/oci-cli/oci_api_key_public.pem"

# Rinomina i nuovi file
mv "tenant/.secrets/oci-cli/oci_api_key_nuova.pem" "tenant/.secrets/oci-cli/oci_api_key.pem"
mv "tenant/.secrets/oci-cli/oci_api_key_nuova_public.pem" "tenant/.secrets/oci-cli/oci_api_key_public.pem"

# AGGIORNA il config OCI CLI! Il key_file ora punta a oci_api_key.pem (non più _nuova)
# Modifica <HOME>\\.oci\config, riga key_file:
#   key_file=<PERCORSO_LOCALE>\tenant\.secrets\oci-cli\oci_api_key.pem
```

> Dopo il rename, il file `oci_api_key_nuova.pem` non esiste più. Se non aggiorni il config, la CLI fallirà.

---

## Riepilogo comandi rapidi

### Solo passphrase (scenario A):

**PowerShell:**
```powershell
openssl rsa -aes256 -in "<PERCORSO_OCI_CLI_KEYS>\oci_api_key.pem" -out "<PERCORSO_OCI_CLI_KEYS>\oci_api_key.pem"
Add-Content "<PERCORSO_OCI_CLI_KEYS>\oci_api_key.pem" "OCI_API_KEY"
```

**Git Bash:**
```bash
openssl rsa -aes256 -in "<PERCORSO_OCI_CLI_KEYS>/oci_api_key.pem" -out "<PERCORSO_OCI_CLI_KEYS>/oci_api_key.pem"
echo "OCI_API_KEY" >> "<PERCORSO_OCI_CLI_KEYS>/oci_api_key.pem"
```

### Passphrase + consolida in `.secrets/` (scenario B):

**PowerShell:**
```powershell
New-Item -ItemType Directory -Force -Path "tenant\.secrets\oci-cli"
Copy-Item "<PERCORSO_OCI_CLI_KEYS>\*" "tenant\.secrets\oci-cli\"
openssl rsa -aes256 -in "tenant\.secrets\oci-cli\oci_api_key.pem" -out "tenant\.secrets\oci-cli\oci_api_key.pem"
Add-Content "tenant\.secrets\oci-cli\oci_api_key.pem" "OCI_API_KEY"
# Poi aggiorna il percorso key_file in <HOME>\\.oci\config (vedi B.3)
```

**Git Bash:**
```bash
mkdir -p "tenant/.secrets/oci-cli"
cp "<PERCORSO_OCI_CLI_KEYS>/"* "tenant/.secrets/oci-cli/"
openssl rsa -aes256 -in "tenant/.secrets/oci-cli/oci_api_key.pem" -out "tenant/.secrets/oci-cli/oci_api_key.pem"
echo "OCI_API_KEY" >> "tenant/.secrets/oci-cli/oci_api_key.pem"
# Poi aggiorna il percorso key_file in <HOME>\\.oci\config (vedi B.3)
```

### Rotazione completa (scenario C) — vedi C.1 → C.5 nel corpo del documento.
