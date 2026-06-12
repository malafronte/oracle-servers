# Rotazione chiavi SSH — Server OCI <NOME_SERVER>

Come aggiungere una passphrase alla chiave esistente o sostituire completamente
la coppia di chiavi SSH per il server Linux su Oracle Cloud.

> **Nota**: i valori come IP, OCID, dominio e percorsi delle chiavi sono centralizzati
> in `tenant/servers/s1/.env`. I comandi sotto usano variabili `${S1_IP}`, `${OCI_COMPARTMENT_ID}`,
> `${OCI_INSTANCE_ID}`, `${S1_SSH_KEY}`, `${S1_SSH_USER}`, `${OCI_SESSION_PROFILE}`, ecc.
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

SSH su Windows richiede che le chiavi private siano accessibili **solo** dal proprietario
e dagli amministratori di sistema. Se vedi questo errore:

```
Bad permissions. Try removing permissions for user: ... on file ...
WARNING: UNPROTECTED PRIVATE KEY FILE!
```

Correggi i permessi con `icacls`:

```powershell
# 1. Disabilita l'ereditarietà (converte gli ACE ereditati in espliciti)
icacls "$env:S1_SSH_KEY" /inheritance:d

# 2. Rimuovi il gruppo che causa l'errore (nell'esempio: CodexSandboxUsers)
icacls "$env:S1_SSH_KEY" /remove "NOMEDOMINIO\GruppoProblema"

# 3. Verifica che l'ACL sia pulita: solo SYSTEM, Administrators e il tuo utente
icacls "$env:S1_SSH_KEY"
```

> L'errore è comune su macchine Windows aggiunte a domini aziendali (Azure AD / Active Directory),
> dove gruppi come `CodexSandboxUsers` o `Domain Users` ereditano permessi di lettura.
> I due comandi sopra risolvono il problema in modo permanente.
> 
> **Git Bash** su Windows eredita gli stessi permessi NTFS, quindi il fix con `icacls`
> risolve il problema per entrambi gli ambienti.

---

## Scenario A: Aggiungere passphrase alla chiave esistente (più semplice)

La chiave pubblica resta identica. Nessuna modifica lato server.

**PowerShell:**
```powershell
ssh-keygen -p -f "$env:S1_SSH_KEY"
```

**Git Bash:**
```bash
ssh-keygen -p -f "$S1_SSH_KEY"
```

Inserisci la nuova passphrase due volte. Da ora in poi:

**PowerShell:**
```powershell
ssh -i $env:S1_SSH_KEY ${env:S1_SSH_USER}@${env:S1_IP}
```

**Git Bash:**
```bash
ssh -i "$S1_SSH_KEY" "${S1_SSH_USER}@${S1_IP}"
```

**Vantaggi**: operazione locale, istantanea, zero rischi.

---

## Scenario B: Sostituire completamente la coppia di chiavi

Generi una nuova coppia, la registri sul server e rimuovi la vecchia.

### B.1 Genera la nuova coppia di chiavi (su Windows)

Il formato standard moderno è quello nativo OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`),
usato di default da `ssh-keygen`. Il formato PEM (`-m PEM`) serve solo per retrocompatibilità
con tool molto vecchi e **non** va usato per chiavi nuove.

**PowerShell:**
```powershell
# Formato standard (OpenSSH nativo) — usa questo
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\oci-s1-ed25519" -C "ubuntu@<NOME_SERVER>"
```

**Git Bash:**
```bash
# Formato standard (OpenSSH nativo) — usa questo
ssh-keygen -t ed25519 -f "$HOME/.ssh/oci-s1-ed25519" -C "ubuntu@<NOME_SERVER>"
```

Output:
- `~/.ssh/oci-s1-ed25519`       ← nuova chiave privata (protetta da passphrase)
- `~/.ssh/oci-s1-ed25519.pub`   ← nuova chiave pubblica

### B.2 Aggiungi la nuova chiave pubblica sul server

**Metodo 1 — Via SSH (con la vecchia chiave ancora attiva):**

**PowerShell:**
```powershell
type "$env:USERPROFILE\.ssh\oci-s1-ed25519.pub" | ssh -i "$env:S1_SSH_KEY" ubuntu@<IP_SERVER> "(echo && cat) >> ~/.ssh/authorized_keys"
```

**Git Bash:**
```bash
cat "$HOME/.ssh/oci-s1-ed25519.pub" | ssh -i "$S1_SSH_KEY" ubuntu@<IP_SERVER> "(echo && cat) >> ~/.ssh/authorized_keys"
```

> `(echo && cat)` assicura che la nuova chiave vada su una riga separata anche se `authorized_keys` non termina con un newline.

**Metodo 2 — Tentativo via OCI CLI (NON funziona su istanze esistenti):**

> **Attenzione**: il campo `ssh_authorized_keys` nei metadati è **immutabile** dopo la
> creazione dell'istanza. OCI restituisce: `The 'ssh_authorized_keys' metadata field
> cannot be updated`. Questo metodo funziona solo al momento del **launch** di una
> nuova istanza, non per istanze già in esecuzione.
>
> **Usa il Metodo 1 (SSH)** per aggiungere chiavi a un'istanza esistente.
>
> Se devi assicurarti che la nuova chiave sopravviva a un rebuild/terminate
> dell'istanza, vedi B.5 per la strategia consigliata.

### B.3 Verifica accesso con la nuova chiave

**PowerShell:**
```powershell
ssh -i "$env:USERPROFILE\.ssh\oci-s1-ed25519" ubuntu@<IP_SERVER>
```

**Git Bash:**
```bash
ssh -i "$HOME/.ssh/oci-s1-ed25519" ubuntu@<IP_SERVER>
```

### B.4 Rimuovi la vecchia chiave pubblica dal server

Prima recupera il contenuto esatto della vecchia chiave pubblica (dal tuo PC Windows):

**PowerShell:**
```powershell
Get-Content "$env:S1_SSH_KEY.pub"
```

**Git Bash:**
```bash
cat "${S1_SSH_KEY}.pub"
```

Poi connettiti al server **con la nuova chiave** ed esegui:

```bash
# Dal server, rimuovi la riga esatta della vecchia chiave pubblica.
# Sostituisci <VECCHIA_CHIAVE_PUBBLICA> con il contenuto letto sopra
# (tutto su una riga: da "ssh-rsa" fino alla fine, incluso l'eventuale commento).
grep -vF "<VECCHIA_CHIAVE_PUBBLICA>" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp && mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

> `grep -vF` con la stringa esatta è più sicuro di `grep -v` con regex parziali.
> In alternativa, se preferisci editare a mano: `nano ~/.ssh/authorized_keys` e cancella la riga.

### B.5 Cosa succede dopo un terminate/rebuild dell'istanza

Il campo `ssh_authorized_keys` nei metadati OCI è **immutabile** dopo la creazione:
contiene per sempre le chiavi impostate al launch originale (nel tuo caso, solo
`<NOME_CHIAVE_SSH>`).

| Scenario | Boot volume | `authorized_keys` | Quale chiave funziona |
|---|---|---|---|
| Stop / Start / Reboot | Conservato | Intatto | Nuova chiave |
| Terminate + nuova istanza da zero | Distrutto | Perso | **Solo la vecchia** (da metadati) |

**Regola pratica**: NON cancellare la vecchia chiave privata da `.secrets/`.
Ti serve come chiave di emergenza. Se l'istanza muore:

1. Lanci una nuova istanza (stessi metadati → la vecchia chiave è già autorizzata)
2. Entri con la vecchia chiave: `ssh -i "$S1_SSH_KEY" ubuntu@<IP>`
3. Riaggiungi la nuova chiave con Metodo 1 (B.2) e ripristini lo stato

> **In `.secrets/s1/` tieni entrambe**: la vecchia come "chiave di ripristino", la nuova come "chiave quotidiana". La nuova vive sul boot volume finché esiste; la vecchia vive nei metadati per sempre.

### B.6 Sposta la nuova chiave nella cartella `.secrets` (opzionale)

**PowerShell:**
```powershell
Copy-Item "$env:USERPROFILE\.ssh\oci-s1-ed25519" "tenant\.secrets\s1\"
Copy-Item "$env:USERPROFILE\.ssh\oci-s1-ed25519.pub" "tenant\.secrets\s1\"

# Aggiorna IpAddress.txt con il nuovo nome chiave
"ssh -i ./oci-s1-ed25519 ubuntu@<IP_SERVER>" | Set-Content "tenant\.secrets\s1\IpAddress.txt"
```

**Git Bash:**
```bash
cp "$HOME/.ssh/oci-s1-ed25519" "tenant/.secrets/s1/"
cp "$HOME/.ssh/oci-s1-ed25519.pub" "tenant/.secrets/s1/"

# Aggiorna IpAddress.txt con il nuovo nome chiave
echo "ssh -i ./oci-s1-ed25519 ubuntu@<IP_SERVER>" > "tenant/.secrets/s1/IpAddress.txt"
```

### B.7 Test finale — verifica che la vecchia chiave NON funzioni più

**PowerShell:**
```powershell
ssh -i "$env:S1_SSH_KEY" ubuntu@<IP_SERVER>
# Expected: Permission denied (publickey)
```

**Git Bash:**
```bash
ssh -i "$S1_SSH_KEY" ubuntu@<IP_SERVER>
# Expected: Permission denied (publickey)
```

---

## Riepilogo comandi rapidi

### Solo passphrase (scenario A) — 1 comando:

**PowerShell:** `ssh-keygen -p -f "$env:S1_SSH_KEY"`
**Git Bash:** `ssh-keygen -p -f "$S1_SSH_KEY"`

### Rotazione completa (scenario B) — sequenza:

**PowerShell:**
```powershell
# 1. Genera nuova coppia
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\oci-s1-ed25519"

# 2. Copia chiave pubblica sul server (Metodo 1)
type "$env:USERPROFILE\.ssh\oci-s1-ed25519.pub" | ssh -i "$env:S1_SSH_KEY" ubuntu@<IP_SERVER> "(echo && cat) >> ~/.ssh/authorized_keys"

# 3. Testa con la nuova chiave
ssh -i "$env:USERPROFILE\.ssh\oci-s1-ed25519" ubuntu@<IP_SERVER>

# 4-6. Vedi B.4, B.5, B.6
```

**Git Bash:**
```bash
# 1. Genera nuova coppia
ssh-keygen -t ed25519 -f "$HOME/.ssh/oci-s1-ed25519"

# 2. Copia chiave pubblica sul server (Metodo 1)
cat "$HOME/.ssh/oci-s1-ed25519.pub" | ssh -i "$S1_SSH_KEY" ubuntu@<IP_SERVER> "(echo && cat) >> ~/.ssh/authorized_keys"

# 3. Testa con la nuova chiave
ssh -i "$HOME/.ssh/oci-s1-ed25519" ubuntu@<IP_SERVER>

# 4-6. Vedi B.4, B.5, B.6
```
