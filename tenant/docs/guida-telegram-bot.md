# Guida Bot Telegram — Setup, test curl e integrazione Netdata

**Server**: <NOME_SERVER> (ARM Ubuntu 24.04)

---

## 1. Creare il bot con BotFather

1. Su Telegram, cerca **[@BotFather](https://t.me/BotFather)**
2. Scrivi `/newbot`
3. Segui le istruzioni:
   - Nome del bot (es. `<NOME_BOT>`)
   - Username del bot (deve finire con `bot`, es. `<USERNAME_BOT>`)
4. Riceverai un messaggio con il **token**:
   ```
   Done! Congratulations on your new bot.
   Use this token to access the HTTP API:
   <TELEGRAM_BOT_TOKEN>
   ```
5. **Salva il token** — è la password del bot, non condividerlo

## 2. Ottenere il chat_id

1. Cerca il tuo bot su Telegram (es. `@<USERNAME_BOT>`)
2. Scrivigli `/start` (o un messaggio qualsiasi)
3. Visita nel browser:
   ```
   https://api.telegram.org/bot<IL-TUO-TOKEN>/getUpdates
   ```
4. Nel JSON di risposta, cerca `"chat"` → `"id"`:
   ```json
   {
     "update_id": 123456789,
     "message": {
       "chat": {
          "id": <CHAT_ID>,
         ...
       }
     }
   }
   ```
5. **Il `id` è il tuo chat_id** — salvalo

## 3. Test invio messaggio

### 3.1 Messaggio semplice (test base)

```bash
curl -s -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>" \
  -d "text=Test messaggio da <NOME_SERVER>"
```

Con variabili `.env`:
```bash
source <(sed 's/\r$//' ~/scripts/.env)
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "text=Test messaggio da <NOME_SERVER>"
```

### 3.2 Messaggio con emoji (API JSON)

**Problema**: quando si esegue `curl` da shell, i caratteri emoji (🟡🔴🧪) vengono persi perché il terminale SSH non preserva UTF-8 completo.

**Soluzione**: salvare il payload in un file JSON separato e passarlo a curl via `-d @file`:

```bash
# Salva il messaggio JSON in un file (emoji preservate)
printf '{"chat_id":"%s","text":"🔴 CRITICAL: Backup superato 9.5 GB"}' "${TELEGRAM_CHAT_ID}" > /tmp/telegram_msg.json

# Invia via API JSON
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d @/tmp/telegram_msg.json

# Pulisci
rm -f /tmp/telegram_msg.json
```

Il file JSON preserva l'encoding UTF-8, evitando che la shell corroda le emoji.

### 3.3 Test rapido con un comando

```bash
source <(sed 's/\r$//' ~/scripts/.env)
printf '{"chat_id":"%s","text":"🧪 Test emoji da s1"}' "${TELEGRAM_CHAT_ID}" > /tmp/test_msg.json
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d @/tmp/test_msg.json && rm -f /tmp/test_msg.json
```

## 4. Integrazione con Netdata

### 4.1 Variabili d'ambiente

In `~/scripts/.env`:
```env
TELEGRAM_BOT_TOKEN=<TOKEN>
TELEGRAM_CHAT_ID=<CHAT_ID>
```

### 4.2 Docker Compose Netdata

Lo script `08-setup-netdata.sh` aggiunge automaticamente queste env var al container Netdata se rileva `TELEGRAM_BOT_TOKEN`:

```yaml
environment:
  - NETDATA_HEALTHCHECK_TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
  - NETDATA_HEALTHCHECK_TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
```

Netdata v2 usa queste variabili per inviare notifiche di allarme (CPU, RAM, disco) direttamente su Telegram.

### 4.3 Allarmi preconfigurati

Attivi subito dopo l'avvio:
- CPU > 80% per 10 minuti
- RAM < 10% libera
- Disco > 90% pieno
- `disk_space_low` — personalizzato (warn >80%, crit >95%)
- Container fermo o servizio down

## 5. Script check-backup-size.sh (quota OCI)

Lo script monitora la dimensione cumulativa delle directory di backup e invia alert Telegram quando si avvicina alla quota OCI Object Storage (10 GB).

### 5.1 Logica

1. Se esiste `~/backup/` con archivi compressi (`*.tar.gz`, `*.zip`), usa la loro dimensione (valore reale)
2. Altrimenti, stima la dimensione dalle directory raw (`~/docker/postgres`, `~/docker/forgejo/data`)
3. Confronta con le soglie e invia via API JSON

### 5.2 Soglie

| Stato | Soglia | Messaggio |
|---|---|---|
| WARNING | > 9 GB (9000 MB) | `🟡 WARNING: Backup <label>: <totale> GB — superato 9 GB` |
| CRITICAL | > 9.5 GB (9500 MB) | `🔴 CRITICAL: Backup <label>: <totale> GB — superato 9.5 GB` |

### 5.3 Cron

Lo script gira ogni ora:
```
0 * * * * /home/ubuntu/docker/netdata/check-backup-size.sh
```

### 5.4 Test forzato dell'allarme

Per simulare il superamento della soglia senza avere dati reali:

```bash
# 1. Backup dello script originale
cp ~/docker/netdata/check-backup-size.sh /tmp/check-backup-size.sh.bak

# 2. Abbassa la soglia a 20 MB per forzare WARNING
sed -i 's/9000/20/' ~/docker/netdata/check-backup-size.sh

# 3. Esegui — riceverai un messaggio Telegram con emoji
~/docker/netdata/check-backup-size.sh

# 4. Ripristina la soglia originale
mv /tmp/check-backup-size.sh.bak ~/docker/netdata/check-backup-size.sh
```

## 6. Comandi API Telegram utili

### Verifica che il bot funzioni
```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"
```
Restituisce nome, username e ID del bot.

### Lista degli ultimi messaggi ricevuti
```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates"
```

### Invia messaggio formattato (Markdown)
```bash
printf '{"chat_id":"%s","text":"*Attenzione*: backup superato soglia","parse_mode":"Markdown"}' "${CHAT_ID}" > /tmp/msg.json
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d @/tmp/msg.json
```

### Invia messaggio con link
```bash
printf '{"chat_id":"%s","text":"Dashboard: [Netdata](https://monitor.<DOMINIO>)","parse_mode":"Markdown","disable_web_page_preview":true}' "${CHAT_ID}" > /tmp/msg.json
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d @/tmp/msg.json
```

### Elimina i pending updates (se il bot si blocca)
```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates?offset=-1"
```

## 7. Riepilogo file coinvolti

| File | Ruolo |
|---|---|
| `~/scripts/.env` | Contiene `TELEGRAM_BOT_TOKEN` e `TELEGRAM_CHAT_ID` (gitignorato) |
| `~/scripts/.env.example` | Template con placeholder (versionato) |
| `~/docker/netdata/docker-compose.yml` | Passa le env var a Netdata |
| `~/docker/netdata/check-backup-size.sh` | Script di monitoraggio backup via cron |
| `~/docker/netdata/config/health.d/disk-backup.conf` | Allarme Netdata personalizzato |

## 8. Errori comuni

| Errore | Causa | Fix |
|---|---|---|
| Messaggio ricevuto senza emoji (`??`) | La shell SSH distrugge l'encoding UTF-8 | Usare API JSON (`-d @file.json` invece di `-d "text=...`) |
| `401 Unauthorized` | Token sbagliato o scaduto | Rigenerare il token con `/newbot` su BotFather |
| `400 Bad Request: chat not found` | Chat ID sbagliato o mai avviato | Inviare `/start` al bot, poi `/getUpdates` |
| Nessuna notifica da Netdata | `TELEGRAM_BOT_TOKEN` vuoto nel `.env` | Verificare con `grep TELEGRAM ~/scripts/.env` |
| Emoji funzionano in chat privata ma non in gruppo | I bot nei gruppi non vedono i messaggi per default | Disabilitare la privacy mode con `/setprivacy` su BotFather |
