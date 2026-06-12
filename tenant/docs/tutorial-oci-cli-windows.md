# Tutorial: Configurazione OCI CLI su Windows

Guida passo passo basata sull'esperienza reale di configurazione. L'installazione base segue la [documentazione ufficiale](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm), ma con precisazioni sui passaggi critici omessi o poco chiari.

---

## 1. Installazione OCI CLI

Scarica l'installer MSI dall'ultima release su GitHub:
[https://github.com/oracle/oci-cli/releases](https://github.com/oracle/oci-cli/releases)

Esegui il file `.msi` e segui la procedura guidata.

Al termine, **chiudi e riapri** il terminale per aggiornare il PATH.

Verifica:
```powershell
oci --version
```

---

## 2. Generare chiavi e configurazione con `oci setup config`

Il comando interattivo `oci setup config` guida nella creazione di chiavi e file di configurazione:

```powershell
oci setup config
```

Ti verranno chieste le seguenti informazioni (da recuperare prima dalla console OCI):

| Domanda | Dove trovarlo |
|---------|---------------|
| **Enter a location for your config** | Premi Invio per accettare `~\.oci\config` |
| **User OCID** | Console → Profile → User settings → copia OCID |
| **Tenancy OCID** | Console → Profile → Tenancy → copia OCID |
| **Region** | Regione del tuo tenancy (es. `eu-milan-1`) |
| **Generate a new API Signing RSA key pair?** | Rispondi **Y** |
| **Directory for your keys** | Premi Invio per `~\.oci` |
| **Name for your key** | Premi Invio per `oci_api_key` |
| **Passphrase** | Premi Invio per nessuna (o inseriscine una) |

Al termine il comando genera:
- `~\.oci\oci_api_key.pem` — chiave privata
- `~\.oci\oci_api_key_public.pem` — chiave pubblica
- `~\.oci\config` — file di configurazione

> Se hai già chiavi esistenti e vuoi riutilizzarle, rispondi **N** a "Generate a new API Signing RSA key pair?" e specifica il percorso della chiave privata esistente.

---

## 3. Ottenere il fingerprint della chiave (⚠️ fondamentale)

Il fingerprint lo trovi già nell'output di `oci setup config`. Se ti serve ricalcolarlo, il metodo OCI è specifico: **non** usare `ssh-keygen` (restituisce un valore diverso).

```powershell
# Metodo corretto (su due passaggi per evitare bug di pipe su Windows)
openssl rsa -pubout -outform DER -in "$env:USERPROFILE\.oci\oci_api_key.pem" -out "$env:TEMP\oci_pub.der"
openssl md5 -c "$env:TEMP\oci_pub.der"
```

Output di esempio:
```
MD5(C:\Users\...\oci_pub.der)= <FINGERPRINT_CHIAVE_API>
```

> **Importante su Windows**: non usare la pipe diretta `openssl rsa ... | openssl md5` perché produce un fingerprint errato. Passare sempre da file intermedio.

---

## 4. Caricare la chiave pubblica su OCI 🔑

**Punto critico omesso dalla documentazione ufficiale.** Senza questo passaggio, qualsiasi comando OCI CLI restituirà `401 NotAuthenticated`.

1. Vai su [cloud.oracle.com](https://cloud.oracle.com) e accedi
2. In alto a destra, clicca sull'icona del **profilo** (cerchio con iniziali)
3. Seleziona **User settings** o **My profile**
4. Nel menu laterale sinistro (Resources), clicca su **API Keys** (o **Tokens and keys**)
5. Clicca **Add API Key**
6. Seleziona **Paste a public key**
7. Incolla **tutto** il contenuto di `oci_api_key_public.pem`, inclusi:
   ```
   -----BEGIN PUBLIC KEY-----
   ...contenuto...
   -----END PUBLIC KEY-----
   ```
8. Clicca **Add**

OCI mostrerà il fingerprint confermato e un'anteprima del config. **Verifica che corrisponda** a quello nel tuo file `~\.oci\config`.

---

## 5. Correggere i permessi dei file (Windows)

SSH e OCI CLI richiedono che i file di chiave siano **leggibili solo dal proprietario**.

```powershell
# Rimuovi ereditarietà e tutti gli utenti/gruppi tranne te
icacls "$env:USERPROFILE\.oci\config" /inheritance:r
icacls "$env:USERPROFILE\.oci\config" /grant:r "$env:USERNAME:(R)"
icacls "$env:USERPROFILE\.oci\config" /remove "NT AUTHORITY\SYSTEM" "BUILTIN\Administrators"

icacls "$env:USERPROFILE\.oci\oci_api_key.pem" /inheritance:r
icacls "$env:USERPROFILE\.oci\oci_api_key.pem" /grant:r "$env:USERNAME:(R)"
icacls "$env:USERPROFILE\.oci\oci_api_key.pem" /remove "NT AUTHORITY\SYSTEM" "BUILTIN\Administrators"
```

Verifica:
```powershell
icacls "$env:USERPROFILE\.oci\config"
icacls "$env:USERPROFILE\.oci\oci_api_key.pem"
```

Output corretto (solo il tuo utente):
```
DOMINIO\utente:(R)
```

---

## 6. Bug noto: warning permessi su Windows 🪲

Anche con permessi corretti, la OCI CLI su Windows potrebbe mostrare:
```
WARNING: Permissions on ... are too open.
Get-Acl : ... module could not be loaded ...
```

È un **bug della CLI** (il check interno chiama `Get-Acl` che fallisce in certe configurazioni PowerShell). Il comando funziona comunque, ma per eliminare il warning:

```powershell
# Per la sessione corrente
$Env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING="True"

# Permanente (per tutte le sessioni future)
[Environment]::SetEnvironmentVariable("OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING", "True", "User")
```

---

## 7. Verifica finale

```powershell
oci iam availability-domain list
```

Se tutto è configurato correttamente, restituirà i domini di disponibilità del tuo tenancy.

---

## Riepilogo: cosa manca nella documentazione ufficiale

| Passaggio | Documentazione ufficiale | Realtà |
|-----------|--------------------------|--------|
| Caricare public key | Menzionato solo in sezioni avanzate | **Necessario** altrimenti `401 NotAuthenticated` |
| Percorso console per API Keys | Descritto in modo vago | `Profile → User settings → API Keys` |
| Calcolo fingerprint | Comando Linux funzionante | Su Windows la pipe `openssl ... \| openssl md5` dà risultati errati; scrivere su file intermedio |
| Permessi su Windows | `oci setup repair-file-permissions` | Il comando interno fallisce; usare `icacls` manualmente |
| Warning permessi | Non documentato | Bug noto; serve variabile d'ambiente `OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING` |
