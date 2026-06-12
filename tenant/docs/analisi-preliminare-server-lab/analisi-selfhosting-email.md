# Self-hosting email su container: analisi e limiti reali

---

## Premessa onesta

Self-hostare email in uscita da un IP cloud (Oracle, AWS, Azure, Hetzner, ecc.) è **estremamente difficile da far funzionare per la posta in uscita**. I grandi provider (Gmail, Outlook, Yahoo, Libero, Alice) giudicano la reputazione dell'IP mittente. Gli IP dei cloud provider sono:

- **Condivisi**: altre VM sullo stesso range potrebbero aver inviato spam
- **Classificati come "datacenter"**: molti filtri antispam penalizzano o rifiutano direttamente le email provenienti da IP di datacenter
- **Senza storia**: un IP appena assegnato non ha reputazione — Gmail lo mette in spam per settimane

**Risultato pratico**: anche con SPF/DKIM/DMARC perfetti, le tue email finiranno in spam su Gmail nel 90% dei casi. Per la posta **in entrata** invece nessun problema.

## Cosa conviene fare

Per il tuo scenario la soluzione pragmatica è **dividere**:

| Direzione | Strumento | Motivo |
|-----------|-----------|--------|
| **Posta in uscita** (invio) | OCI Email Delivery (già previsto) | IP Oracle con reputazione gestita, SPF/DKIM automatici, gratuito fino a 200 email/giorno |
| **Posta in entrata** (ricezione) + webmail | Soluzione containerizzata | Ricevere email non ha problemi di reputazione |

Se vuoi comunque provare a self-hostare tutto, ecco le opzioni.

---

## Soluzioni containerizzate

### 1. Mailcow

**URL**: https://mailcow.email  
**Container**: ~15 (Postfix, Dovecot, SOGo webmail, Rspamd antispam, ClamAV antivirus, Solr search, Redis, MariaDB, ACME, Watchdog, ecc.)

| Pro | Contro |
|-----|--------|
| La più completa: webmail SOGo, admin panel, antispam, antivirus, calendario, contatti | RAM: **4-6 GB** minimi |
| Docker Compose già pronto, auto-configurante | ARM64: non ufficialmente supportato (x86 only, funziona con QEMU ma pesante) |
| Aggiornamenti automatici via script | Overkill per uso personale |
| Community attiva, documentazione in italiano | Porte 25/465/587/993 da tenere aperte e configurare |

**Verdetto**: ❌ Troppo pesante per s1, non ARM-native, overkill per te.

---

### 2. Mailu

**URL**: https://mailu.io  
**Container**: ~8 (Postfix, Dovecot, Roundcube webmail, Rspamd, ClamAV, Redis, Admin)

| Pro | Contro |
|-----|--------|
| Più leggero di Mailcow, Docker Compose ben fatto | RAM: **~2 GB** |
| Roundcube webmail incluso | ARM64: funziona con immagini multi-arch |
| Admin panel web per gestire domini e utenti | Meno completo: no CalDAV/CardDAV nativo |
| Supporta multi-dominio | |

**Verdetto**: ⚠️ Fattibile su s1 (2 GB), ma consuma RAM preziosa. ARM64 funziona.

---

### 3. docker-mailserver

**URL**: https://github.com/docker-mailserver/docker-mailserver  
**Container**: 1

| Pro | Contro |
|-----|--------|
| **Leggerissimo**: un container, 200-300 MB RAM | **Nessuna webmail** (solo SMTP/IMAP/POP3) |
| ARM64 nativo | Nessuna interfaccia admin (si configura via file env e script) |
| Postfix + Dovecot + Rspamd + ClamAV in un container | Curva di apprendimento ripida |
| Manutenzione minima | |

**Verdetto**: ✅ Se vuoi solo ricevere email e leggerle da Thunderbird/Outlook, è perfetto. Se vuoi webmail, devi aggiungere un container Roundcube o SnappyMail a parte.

---

### 4. Stalwart Mail Server

**URL**: https://stalw.art  
**Container**: 1

| Pro | Contro |
|-----|--------|
| **Modernissimo**: scritto in Rust, performance elevatissime | Progetto giovane (2023) |
| ARM64 nativo | Documentazione ancora in evoluzione |
| JMAP, IMAP, SMTP, POP3 in un unico binario (~50 MB RAM) | Nessuna webmail integrata |
| Anti-spam integrato | |

**Verdetto**: ⬜ Molto promettente, da tenere d'occhio.

---

## Raccomandazione per il tuo caso

### Scenario A — Vuoi solo inviare email (es. CineBase: conferme, notifiche)

**Usa OCI Email Delivery** (già previsto nella guida). Zero manutenzione, deliverability garantita, gratuito.

### Scenario B — Vuoi anche ricevere email su `@<DOMINIO_APP>` e leggerle via webmail

Il compromesso migliore:

```
Posta in uscita: OCI Email Delivery (gratuito, deliverability garantita)
Posta in entrata: docker-mailserver (o Mailu se vuoi tutto integrato)
Webmail: SnappyMail (container a parte, leggero, frontend per IMAP/SMTP)
```

SnappyMail è un container da 50 MB con UI moderna:

```yaml
# ~/docker/mail/docker-compose.yml
services:
  snappymail:
    image: djmaze/snappymail:latest
    container_name: snappymail
    restart: unless-stopped
    networks:
      - traefik-net
    volumes:
      - ./snappymail-data:/snappymail/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.webmail.rule=Host(`mail.<DOMINIO_APP>`)"
      - "traefik.http.routers.webmail.entrypoints=websecure"
      - "traefik.http.routers.webmail.tls.certresolver=letsencrypt"
      - "traefik.http.services.webmail.loadbalancer.server.port=8888"

networks:
  traefik-net:
    external: true
```

SnappyMail si collega a qualsiasi server IMAP/SMTP — anche quelli di Aruba. Puoi quindi **continuare a usare le caselle Aruba** ma con una webmail self-hosted più moderna e veloce.

### Scenario C — Vuoi self-hostare tutto (entrata + uscita)

Accetti il rischio che le email in uscita vadano in spam su Gmail, ma per uso interno (studenti, collaboratori) può andare bene.

**Mailu** è il miglior compromesso: 2 GB RAM, ARM64, webmail inclusa, admin panel, multi-dominio, configurazione via Docker Compose.

---

## Riepilogo

| Cosa vuoi fare | Soluzione | RAM |
|----------------|-----------|-----|
| Solo invio email transazionali | OCI Email Delivery | 0 MB |
| Ricevere email + webmail moderna | SnappyMail collegato a caselle Aruba esistenti | 50 MB |
| Ricevere email + self-host completo (entrata) | docker-mailserver + SnappyMail | 300 MB |
| Tutto self-host (entrata + uscita + webmail) | Mailu | 2 GB |
