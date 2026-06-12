# Sicurezza OCI — Firewall e controllo accessi per server s1

Panoramica dei livelli di sicurezza che proteggono il server `<NOME_SERVER>`
e istruzioni per gestire l'apertura/chiusura delle porte.

> **Nota**: tutti gli OCID e i nomi delle risorse sono referenziati da `.env`.
> Caricare le variabili prima di eseguire i comandi:
> ```bash
> # Dalla root del repository (Git Bash)
> set -a; source tenant/servers/s1/.env; set +a
> ```
> ```powershell
> # Dalla root del repository (PowerShell)
> Get-Content tenant\servers\s1\.env | ForEach-Object { if ($_ -match '^([^#].+?)=(.+)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
> ```

---

## Livelli di sicurezza (dal più esterno al più interno)

```
Internet
  │
  ▼
┌─────────────────────────────────────────────────┐
│ 1. OCI VCN Security List                         │
│    Regole di ingresso/uscita a livello di subnet │
│    Gestione: Console OCI o CLI                    │
└─────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────┐
│ 2. OCI Network Security Group (NSG) — opzionale  │
│    Regole granulari per VNIC specifica           │
│    Attualmente NON configurato su s1             │
└─────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────┐
│ 3. Firewall di sistema (iptables / ufw)          │
│    Regole a livello di sistema operativo         │
│    Ubuntu 24.04 usa nftables/ufw                 │
└─────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────┐
│ 4. Controllo accessi SSH (authorized_keys)       │
│    Solo le chiavi pubbliche autorizzate          │
└─────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────┐
│ 5. Traefik (reverse proxy)                       │
│    Gestisce TLS, routing e basic auth            │
│    Espone solo le porte 80 e 443                 │
└─────────────────────────────────────────────────┘
  │
  ▼
┌─────────────────────────────────────────────────┐
│ 6. Container Docker (reti isolate)               │
│    I container interni (db, registry) non sono   │
│    esposti direttamente a Internet               │
└─────────────────────────────────────────────────┘
```

---

## 1. VCN Security List

### 1.1 Cos'è

La Security List è un insieme di regole di firewall **stateful** applicate a tutte le
VNIC nella subnet. Le regole di ingresso (ingress) controllano il traffico in entrata,
quelle di uscita (egress) il traffico in uscita.

Essendo **stateful**, se permetti il traffico in ingresso su una porta, la risposta
in uscita è automaticamente consentita (senza bisogno di una regola esplicita).

### 1.2 Risorse attuali

| Risorsa | Variabile `.env` | Descrizione |
|---|---|---|
| VCN | `${OCI_VCN_ID}` | Rete virtuale che contiene la subnet |
| Subnet | `${OCI_SUBNET_ID}` | Sottorete dove risiede l'istanza s1 |
| Security List | `${OCI_SECURITY_LIST_ID}` | Regole firewall applicate alla subnet |

### 1.3 Regole configurate

Dopo il fix effettuato il 10/06/2026:

| Direzione | Source | Protocollo | Porta | Descrizione |
|---|---|---|---|---|
| Ingress | `0.0.0.0/0` | TCP | 22 | SSH |
| Ingress | `0.0.0.0/0` | TCP | 80 | HTTP (Traefik) |
| Ingress | `0.0.0.0/0` | TCP | 443 | HTTPS (Traefik) |
| Ingress | `0.0.0.0/0` | ICMP (type 3, code 4) | — | Path MTU discovery |
| Ingress | `10.0.0.0/16` | ICMP (type 3) | — | MTU discovery interno |
| Egress | `0.0.0.0/0` | All | — | Tutto il traffico in uscita |

### 1.4 Visualizzare le regole attuali

**PowerShell:**
```powershell
oci network security-list get --security-list-id $env:OCI_SECURITY_LIST_ID --profile $env:OCI_SESSION_PROFILE --auth security_token | ConvertFrom-Json | ForEach-Object { $_.data.'ingress-security-rules' | Select-Object source, protocol, description, @{N='port';E={$_.'tcp-options'.'destination-port-range'.max}} | Format-Table -AutoSize }
```

**Git Bash:**
```bash
oci network security-list get \
  --security-list-id $OCI_SECURITY_LIST_ID \
  --profile $OCI_SESSION_PROFILE --auth security_token \
  --query "data.\"ingress-security-rules\"[*].{source:source,protocol:protocol,port:\"tcp-options\".\"destination-port-range\".max,description:description}" \
  --output table
```

### 1.5 Aggiungere una nuova porta

Esempio: aprire la porta 2222 per SSH di Forgejo.

**PowerShell:**
```powershell
# 1. Recupera le regole esistenti
$sl = oci network security-list get --security-list-id $env:OCI_SECURITY_LIST_ID --profile $env:OCI_SESSION_PROFILE --auth security_token | ConvertFrom-Json
$ingress = $sl.data.'ingress-security-rules'

# 2. Crea la nuova regola
$newRule = @{
  source = "0.0.0.0/0"
  protocol = "6"
  description = "Forgejo SSH"
  'tcp-options' = @{ 'destination-port-range' = @{ min = 2222; max = 2222 } }
}

# 3. Concatena con le esistenti
$allRules = @($ingress) + @($newRule)
$rulesJson = $allRules | ConvertTo-Json -Depth 4 -Compress

# 4. Aggiorna
oci network security-list update `
  --security-list-id $env:OCI_SECURITY_LIST_ID `
  --ingress-security-rules $rulesJson `
  --profile $env:OCI_SESSION_PROFILE --auth security_token `
  --force
```

**Git Bash:**
```bash
# jq richiesto
currentRules=$(oci network security-list get \
  --security-list-id $OCI_SECURITY_LIST_ID \
  --profile $OCI_SESSION_PROFILE --auth security_token \
  --query 'data."ingress-security-rules"' --raw-output)

newRule='{"source":"0.0.0.0/0","protocol":"6","description":"Forgejo SSH","tcp-options":{"destination-port-range":{"min":2222,"max":2222}}}'

allRules=$(echo "$currentRules" | jq ". + [$newRule]")

oci network security-list update \
  --security-list-id $OCI_SECURITY_LIST_ID \
  --ingress-security-rules "$allRules" \
  --profile $OCI_SESSION_PROFILE --auth security_token \
  --force
```

### 1.6 Rimuovere una porta

Stessa procedura di sopra, ma usa `jq` per filtrare la regola da rimuovere:

```bash
# Rimuovi la regola sulla porta 2222
filteredRules=$(echo "$currentRules" | jq '[.[] | select(.description != "Forgejo SSH")]')
oci network security-list update \
  --security-list-id $OCI_SECURITY_LIST_ID \
  --ingress-security-rules "$filteredRules" \
  --profile $OCI_SESSION_PROFILE --auth security_token \
  --force
```

### 1.7 Comandi da console OCI

In alternativa alla CLI, dalla console web OCI:

1. Apri `https://console.eu-milan-1.oraclecloud.com/`
2. Vai su **Networking → Virtual Cloud Networks**
3. Clicca sul VCN (`vcn-<NOME_VCN>`, `${OCI_VCN_ID}`)
4. Clicca su **Security Lists** nel menu a sinistra
5. Clicca sulla security list (`Default Security List for vcn-<NOME_VCN>`)
6. **Add Ingress Rules** per aggiungere, o clicca sui tre puntini per rimuovere

---

## 2. Network Security Group (NSG)

Gli NSG sono un'alternativa (o complemento) alle Security List. Si applicano
a **singole VNIC** anziché all'intera subnet.

Attualmente l'istanza s1 **non** ha NSG configurati — tutta la sicurezza di rete
è gestita tramite la Security List della subnet.

### 2.1 Quando usarli

- Vuoi regole diverse per istanze diverse nella stessa subnet
- Vuoi isolare il traffico tra container/servizi sulla stessa VCN
- Scenario multi-server: s1 e s2 sulla stessa subnet ma con regole diverse

### 2.2 Creare un NSG (se necessario in futuro)

**PowerShell:**
```powershell
$nsg = oci network nsg create `
  --compartment-id $env:OCI_COMPARTMENT_ID `
  --vcn-id $env:OCI_VCN_ID `
  --display-name "s1-nsg" `
  --profile $env:OCI_SESSION_PROFILE --auth security_token | ConvertFrom-Json

# Associa alla VNIC
oci network vnic update `
  --vnic-id $env:OCI_VNIC_ID `
  --nsg-ids "[\"$($nsg.data.id)\"]" `
  --profile $env:OCI_SESSION_PROFILE --auth security_token `
  --force
```

---

## 3. Firewall di sistema (UFW / iptables)

Ubuntu 24.04 usa `ufw` (Uncomplicated Firewall) come frontend per `nftables`.

### 3.1 Verificare lo stato attuale

```bash
sudo ufw status verbose
```

### 3.2 Configurazione consigliata

Di default su Ubuntu 24.04, `ufw` è **inattivo** perché Oracle Cloud gestisce
il firewall a livello di VCN. Tuttavia, per difesa in profondità:

```bash
# Abilita UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Consenti SSH (sempre!)
sudo ufw allow 22/tcp

# Consenti HTTP/HTTPS (Traefik)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Consenti SSH Forgejo (porta alternativa)
sudo ufw allow 2222/tcp

# Attiva
sudo ufw enable
```

> **Attenzione**: se abiliti UFW senza prima aprire la porta 22, perdi l'accesso SSH.
> Su OCI, verifica sempre di avere la console VNC di emergenza disponibile.

### 3.3 Verifica porte aperte

```bash
sudo ufw status numbered
sudo ss -tlnp   # porte in ascolto
```

---

## 4. Controllo accessi SSH

Vedi `tenant/docs/rotazione-chiavi-ssh.md` per la gestione completa.

Principi:
- Chiave privata **sempre** protetta da passphrase
- Solo le chiavi pubbliche autorizzate in `~/.ssh/authorized_keys`
- Autenticazione via password **disabilitata** (default su OCI)
- Accesso root via SSH **disabilitato** (solo utente `ubuntu` con sudo)

---

## 5. Traefik — Reverse Proxy

### 5.1 Porte esposte

Traefik è l'unico servizio che espone porte su Internet:

| Porta | Protocollo | Uso |
|---|---|---|
| 80 | HTTP | Redirezione automatica a HTTPS + ACME challenge |
| 443 | HTTPS | Tutti i servizi (dashboard, Portainer, Forgejo, ecc.) |

### 5.2 Sicurezza applicativa

- **Dashboard**: protetta da basic auth (`htpasswd` bcrypt)
- **Certificati**: Let's Encrypt con rinnovo automatico
- **Rete interna**: `traefik-net` (bridge Docker), i container si connettono a questa rete
- **Provider Docker**: Traefik scopre automaticamente i container con label `traefik.enable=true`

### 5.3 Versione Traefik

⚠️ **Usare `traefik:v3.6` o successivo**. La versione `v3.4` ha un bug noto
(issue [#12253](https://github.com/traefik/traefik/issues/12253)):
hardcoda l'API Docker v1.24 e fallisce con Docker 28+ che richiede API >= 1.40.
La v3.6 implementa l'auto-negotiation dell'API Docker (PR [#12256](https://github.com/traefik/traefik/pull/12256)).

Lo script `04-setup-traefik.sh` usa `traefik:v3.6`.

---

## 6. Container Docker — Reti isolate

### 6.1 Architettura delle reti

```
Internet
  │
  ├── :80, :443 → traefik-net (Traefik)
  │                 │
  │    ┌────────────┼────────────────┐
  │    ▼            ▼                ▼
  │  portainer   registry         forgejo
  │  (traefik)   (traefik)    (traefik + forgejo-internal)
  │                                │
  │                           ┌────┴────┐
  │                           ▼         ▼
  │                      postgres   runners
  │                    (solo rete    (solo rete
  │                     interna)     interna)
  │
  └── :2222 → forgejo (SSH Git)
```

### 6.2 Principi

- I container di database (PostgreSQL) sono su reti interne (`forgejo-internal`, `internal`)
  e **mai** esposti direttamente a Internet
- Solo Traefik è connesso sia alla rete interna `traefik-net` sia alle porte host 80/443
- I progetti applicativi usano la stessa architettura: rete interna isolata + `traefik-net`
- Il Registry è accessibile solo via HTTPS tramite Traefik, con autenticazione htpasswd

---

## 7. Riepilogo porte e relativi livelli

| Porta | Servizio | Security List | UFW | Traefik | Note |
|---|---|---|---|---|---|
| 22 | SSH | ✅ | ✅ | — | Accesso amministrativo |
| 80 | HTTP | ✅ | ✅ | ✅ | Redirezione HTTPS |
| 443 | HTTPS | ✅ | ✅ | ✅ | Tutti i servizi web |
| 2222 | Forgejo SSH | ❌ (chiusa) | ❌ | — | Aprire se serve Git via SSH |
| 9000 | Portainer | ❌ | — | ✅ | Solo via Traefik (HTTPS) |
| 5000 | Registry | ❌ | — | ✅ | Solo via Traefik (HTTPS) |
| 3000 | Forgejo | ❌ | — | ✅ | Solo via Traefik (HTTPS) |
| 19999 | Netdata | ❌ | — | ✅ | Solo via Traefik (HTTPS) |
| 5432 | PostgreSQL | ❌ | — | ❌ | Solo rete interna Docker |

---

## 8. Comandi rapidi

### Login OCI

```powershell
oci session authenticate --region eu-milan-1
```

### Verifica regole security list

```powershell
oci network security-list get --security-list-id $env:OCI_SECURITY_LIST_ID --profile $env:OCI_SESSION_PROFILE --auth security_token | ConvertFrom-Json | ForEach-Object { $_.data.'ingress-security-rules' | ForEach-Object { "$($_.description): $($_.source) TCP $($_.'tcp-options'.'destination-port-range'.max)" } }
```

### Verifica porte in ascolto sul server

```bash
sudo ss -tlnp | grep -E ':(22|80|443|2222|3000|5000|9000|19999)'
```

### Test connettività da locale

```bash
curl -sk https://traefik.${DOMAIN} | head -5
```

---

## 9. Problema noto: `$$` double escape in Traefik

### Contesto

Nelle configurazioni Traefik, il carattere `$` ha un significato speciale in due contesti diversi:

| Contesto | Escape richiesto | Esempio |
|---|---|---|
| **Label Docker Compose** | `$$` → `$` letterale | `basicauth.users=admin:$$2y$$05$$...` |
| **File provider** (YAML statico) | `$` singolo | `users: "admin:$2y$05$..."` |

### Bug corretto

Lo script `04-setup-traefik.sh` usava `$$` nel file `dashboard.yml` (file provider),
impedendo il riconoscimento della password. Il file provider **non** processa `$$`
come escape — lo interpreta letteralmente, rendendo l'hash bcrypt non valido.

**Fix**: `dashboard.yml` ora riceve l'hash con `$` singolo. Le label Docker Compose
(es. in `08-setup-netdata.sh`) continuano a usare `$$`, che è corretto per quel contesto.
