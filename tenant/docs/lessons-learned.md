# Lessons Learned — Setup server OCI ARM64 con infrastruttura DevOps

Cose che ho imparato (e che rifarei diversamente) se dovessi ricominciare questo progetto da zero.

---

## 1. Password e caratteri speciali: il flagello dell'encoding

### `$` nelle password
Docker Compose interpreta `$VAR` come variabile. Se una password contiene `$`, va escapato come `$$`. Esempio reale: `qwwkkl457Q£$LK#123` → Docker Compose cerca la variabile `${LK}` e produce warning. **Morale**: usare password **senza `$`** nei file `.env` caricati da Docker Compose.

### `è` e altri caratteri accentati nelle password
Il problema non è Docker, è la **shell**: `docker login -p 'passwordconè'` fallisce perché la shell interpreta `è` in modo diverso a seconda del terminale. **La soluzione**: usare sempre `--password-stdin` con pipe:
```bash
echo "$PASSWORD" | docker login -u user --password-stdin
```
Perfetto sia da shell interattiva che da CI/CD. Mai usare `-p` da script.

### Emoji nei messaggi Telegram via shell
Il terminale SSH **distrugge** l'encoding UTF-8 delle emoji. Invece di passarle direttamente a `curl -d "text=...emoji..."`, salvare il payload JSON in un file:
```bash
printf '{"chat_id":"%s","text":"emoqui"}' "$CHAT_ID" > /tmp/msg.json
curl -d @/tmp/msg.json ...
```
Il file preserva l'encoding perché non passa attraverso l'interpretazione della shell.

---

## 2. Netdata: non sottovalutare la migrazione v1 → v2

Netdata v2 ha cambiato profondamente la sintassi degli health check. **Errori fatti**:

| Sbagliato (v1) | Corretto (v2) | Spiegazione |
|---|---|---|
| `on: disk_space._` | `on: disk.space` | I chart name usano `.` non `_` in v2 |
| `alarm:` | `template:` | `alarm` si attacca a un chart ID specifico; per contesti condivisi (es. tutti i mount point) serve `template` |
| `lookup:` + `warn: $used > 20` | `calc:` + `warn: $this > 80` | `$used` è il valore raw (probabilmente MB); `calc` + `$this` sono prevedibili |
| `units: GB` con `lookup` | `units: %` con `calc` | `units` non converte il valore — serve solo per display. La conversione va fatta nel `calc` |

**Morale**: testare sempre con `grep -n "9000\|9500"` dopo aver caricato un health check; verificare nella UI che appaia; se possibile, usare percentuali invece di valori assoluti.

---

## 3. Traefik: file provider vs label inline

### La regola d'oro
**Mai mettere bcrypt hash nelle label Docker Compose.** Il problema `$$` con bcrypt (ogni `$` va escapato come `$$`, e gli hash bcrypt ne hanno molti) rende le label illeggibili e fragili. Inoltre, se lo script viene eseguito due volte, l'espansione delle variabili Shell può corrompere l'hash.

**La soluzione**: usare sempre **file provider Traefik** per i middleware basic auth:
```yaml
# File provider: ~/docker/traefik/config/middleware-netdata.yml
http:
  middlewares:
    netdata-auth:
      basicAuth:
        users:
          - "admin:$2y$05$..."
```
```yaml
# Label Docker Compose (nessun $, solo riferimento)
- "traefik.http.routers.netdata.middlewares=netdata-auth@file"
```

Il suffisso `@file` è **obbligatorio** quando router (provider `docker`) e middleware (provider `file`) sono in provider diversi.

---

## 4. Runner Forgejo CI/CD: la strada giusta al primo colpo

### Configurazione runner
La configurazione che **funziona** è:
```yaml
runner:
  labels:
    - ubuntu-latest:docker://node:22-bookworm
container:
  docker_host: "automount"
```

### Cosa NON fare
- **Non usare `:host`**: i job girano dentro il container runner (Alpine), che non ha Node.js, apt-get, docker CLI. È un vicolo cieco.
- **Non usare `node:20`**: GitHub Actions ha migrato a Node 22; Forgejo segue lo stesso standard.
- **Non omettere `container.docker_host: "automount"`**: senza, il container job non ha accesso al Docker socket dell'host.

### Pipeline workflow
1. **Primo step**: `apt-get install -y docker.io openssh-client` — il container `node:22-bookworm` non ha Docker CLI
2. **Deploy**: SEMPRE via SSH, mai `docker compose` diretto dal container job. Il container non ha il filesystem dell'host.
3. **SSH key**: GENERARE UNA CHIAVE DEDICATA SENZA PASSPHRASE. La chiave personale con passphrase non funziona in pipeline. Due chiavi coesistono in `authorized_keys`.

### Errori prevedibili e le loro soluzioni
| Errore | Causa certa | Fix certo |
|---|---|---|
| `no matching online runner` | `runs-on: ubuntu-24.04` vs label `ubuntu-latest` | Usare `ubuntu-latest` nel workflow |
| `docker: command not found` | Container job senza Docker CLI | Step `apt-get install docker.io` |
| `401 Unauthorized` al registry | Password con `è` via `-p` | `--password-stdin` con pipe |
| `cd: /root/docker/...: No such file` | Il container non vede il filesystem host | Deploy via SSH |
| `Permission denied (publickey)` | Chiave SSH con passphrase | Generare chiave senza passphrase |
| `Push to create is not enabled` | Repo non esiste su Forgejo | Creare repo vuoto via UI |

---

## 5. File `.env`: merge, non duplicazione

CineBase ha **due** file di configurazione:
- `.env.docker.example` — template con **tutte** le variabili e default di sviluppo
- `.env.docker` — solo i **segreti** (SMTP, Stripe, OAuth) con valori reali

Per il deploy in produzione serve un **terzo** file (`.env`) con:
- URL di produzione (da `.env.example` del repo oracle-servers)
- Segreti reali (da `.env.docker` del repo CineBase)

**Approccio giusto**: merge automatico. `.env.docker` sovrascrive le variabili corrispondenti in `.env.example`. Le variabili non presenti in `.env.docker` (es. `MYSQL_ROOT_PASSWORD`, `JWT_SECRET`) vanno impostate manualmente una tantum.

**Approccio sbagliato**: copiare `.env.docker` direttamente — mancano gli URL di produzione e si usano `localhost:5000` che in produzione non funzionano.

---

## 6. MariaDB vs PostgreSQL: coesistono senza problemi

Il server aveva già **PostgreSQL 16** per Forgejo. CineBase richiede **MariaDB 10.11**. Si possono eseguire entrambi contemporaneamente senza conflitti:
- Reti Docker separate (`forgejo-internal` vs `cinebase-net`)
- Porte interne (3306 vs 5432) non esposte sull'host
- Nessuna interferenza

**Morale**: non serve migrare un'applicazione a un database diverso. Container Docker isolano perfettamente servizi con requisiti diversi.

---

## 7. Backup: non backuppare ciò che è ricostruibile

Domanda da porsi: **posso rigenerare questo dato dal codice sorgente?**

| Directory | Ricostruibile? | Backup? |
|---|---|---|
| `forgejo/data` | ❌ repo Git, utenti, issue | **SÌ** |
| `postgres/` | ❌ database Forgejo | **SÌ** |
| `registry/data` | ✅ le immagini si rebuildano dal codice | **NO** |
| Configurazioni Traefik, script | ✅ già versionati su Forgejo | **NO** |

Backuppare `registry/data` spreca spazio prezioso (quota OCI 10 GB) per dati che il CI/CD ricostruisce automaticamente.

---

## 8. Network Docker: pattern a due reti

Per ogni progetto applicativo, usare **due reti**:
```yaml
networks:
  cinebase-net:      # interna: comunicazione tra servizi del progetto
    driver: bridge
  traefik-net:       # esterna: solo i servizi esposti al reverse proxy
    external: true
```

Solo i container che devono essere raggiungibili da Traefik (frontend, API) si connettono a **entrambe** le reti. Il database sta **solo** sulla rete interna. Nessuna porta esposta sull'host — tutto il traffico passa da Traefik.

---

## 9. Script: idempotenza fin dall'inizio

Ogni script deve poter essere eseguito N volte producendo lo stesso risultato:

```bash
# Pattern idempotenza
if [ -f "$DIR/docker-compose.yml" ]; then
  if container_running; then
    echo "Già installato. Aggiorno..."
    docker compose pull && docker compose up -d
    exit 0
  fi
fi
# Prima installazione
...
```

**Eccezione**: gli script che generano file di configurazione (es. `check-backup-size.sh`) devono **sempre** rigenerarli, anche se il servizio è già attivo. La generazione va messa **prima** del check di idempotenza.

---

## 10. Testing: forzare le soglie invece di aspettare

Non aspettare che i dati reali raggiungano le soglie. Per testare un alert:

```bash
# Abbassa la soglia temporaneamente
sed -i 's/9000/20/' ~/docker/netdata/check-backup-size.sh
./check-backup-size.sh   # Scatta subito
sed -i 's/20/9000/' ~/docker/netdata/check-backup-size.sh  # Ripristina
```

Per testare API Telegram senza toccare lo script:
```bash
printf '{"chat_id":"%s","text":"Test"}' "$CHAT_ID" > /tmp/msg.json
curl -d @/tmp/msg.json ...
```

---

## 11. Git e segreti: cosa DEVE essere gitignorato

```gitignore
# Questi SÌ (contengono segreti)
**/.secrets/
.env
*.pem
*.key
id_*

# Questi NO (servono per il setup)
!.env.example      # template con placeholder, versionato
```

Prima di rendere pubblico un repo, verificare che:
- `.env.example` abbia **solo placeholder**, mai valori reali
- OCID e fingerprint siano anonimizzati (es. `<OCID_TENANCY>`)
- Path locali siano anonimizzati (es. `<PERCORSO_LOCALE>`)
- Nessuna password, token o chiave sia mai stata committata nella history

---

## 12. Sequenza cronologica ideale (se ricominciassi)

```
1. Script 01-03: prerequisiti, Docker, struttura directory
2. Script 04: Traefik (reverse proxy + Let's Encrypt)
3. Script 05: Portainer (monitoring container)
4. Script 06: Docker Registry privato + UI
5. Script 07-07b: Forgejo + PostgreSQL + 2 runner (CON LABEL docker://node:22-bookworm)
6. Script 08: Netdata v2 + allarmi + check-backup-size.sh + Telegram
7. Script 09: CineBase stack (primo deploy)
8. Configurazione CI/CD: workflow, secrets, chiave SSH deploy
9. Primo push → pipeline funzionante
10. Script 10: Backup OCI Object Storage
```

**Non fare**:
- Il CI/CD prima del primo deploy. Servono immagini nel registry.
- Il backup prima di sapere cosa è critico e cosa è ricostruibile.
- I runner in `:host` mode — è una perdita di tempo.
