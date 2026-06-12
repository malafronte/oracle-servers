# Tutorial: Permessi chiavi SSH su Windows e Linux

SSH richiede che la chiave privata sia **leggibile solo dal proprietario**. Se altri utenti o gruppi hanno accesso in lettura, SSH rifiuta la chiave con l'errore `bad permissions`.

---

## Windows (PowerShell / icacls)

### Vedere i permessi correnti

```powershell
icacls ".\<NOME_CHIAVE_SSH>"
```

Esempio di output con permessi ereditati (troppo aperti):
```
<HOSTNAME>\AltroGruppo:(I)(RX)   <-- PROBLEMA: altri possono leggere
NT AUTHORITY\SYSTEM:(I)(F)
BUILTIN\Administrators:(I)(F)
<HOSTNAME>\<UTENTE>:(I)(F)
```

Sigle:
- `(I)` = ereditato (inherited)
- `(F)` = controllo completo (full)
- `(RX)` = lettura ed esecuzione (read/execute)
- `(R)` = sola lettura (read)

### Correggere i permessi (solo proprietario, lettura)

```powershell
icacls ".\<NOME_CHIAVE_SSH>" /inheritance:r /grant "$env:USERNAME`:(R)"
```

Cosa fa:
- `/inheritance:r` — rimuove l'ereditarietà dalla cartella padre
- `/grant "$env:USERNAME:(R)"` — concede solo all'utente corrente il permesso di lettura

Output corretto dopo il fix:
```
<HOSTNAME>\<UTENTE>:(R)
```

### Rimuovere un utente o gruppo specifico

```powershell
icacls ".\<NOME_CHIAVE_SSH>" /remove "NOMEGRUPPO"
```

### Ripristinare i permessi ereditati (tornare come prima)

```powershell
icacls ".\<NOME_CHIAVE_SSH>" /reset
```

`/reset` ripristina i permessi ereditati dalla cartella padre (annulla le modifiche fatte con `/inheritance:r`).

### Correggere i permessi su tutte le chiavi nella cartella

```powershell
Get-ChildItem -LiteralPath "." -Filter "*.key" | ForEach-Object { icacls $_.FullName /inheritance:r /grant "$env:USERNAME`:(R)" }
```

---

## Linux / macOS (chmod)

### Vedere i permessi correnti

```bash
ls -l ./<NOME_CHIAVE_SSH>
```

Output corretto:
```
-rw-------  1 utente utente  1679 10 lug 2023  ./<NOME_CHIAVE_SSH>
```

`-rw-------` significa `600`: solo il proprietario può leggere e scrivere.

Output problematico:
```
-rw-r--r--  1 utente utente  1679 10 lug 2023  ./<NOME_CHIAVE_SSH>
```

`-rw-r--r--` significa `644`: anche altri utenti possono leggere la chiave.

### Correggere i permessi (solo proprietario)

```bash
chmod 600 ./<NOME_CHIAVE_SSH>
```

### Correggere i permessi su tutte le chiavi nella cartella

```bash
chmod 600 ./*.key
```

### Ripristinare permessi predefiniti (644, leggibile da tutti)

```bash
chmod 644 ./<NOME_CHIAVE_SSH>
```

> ⚠️ **Attenzione**: `644` rende la chiave leggibile da altri utenti — SSH la rifiuterà. Usare solo se necessario per altri scopi.

---

## Tabella riepilogativa

| Azione                          | Windows (icacls)                                              | Linux/macOS (chmod)    |
|---------------------------------|---------------------------------------------------------------|------------------------|
| Vedere permessi                 | `icacls ".\chiave.key"`                                      | `ls -l chiave.key`     |
| Correggere per SSH (solo owner) | `icacls ".\chiave.key" /inheritance:r /grant "$env:USERNAME`:(R)"` | `chmod 600 chiave.key` |
| Rimuovere un utente/gruppo      | `icacls ".\chiave.key" /remove "NOMEGRUPPO"`                 | `setfacl -x user:utente chiave.key` |
| Ripristinare permessi originali | `icacls ".\chiave.key" /reset`                               | `chmod 644 chiave.key` (o i permessi originali) |
