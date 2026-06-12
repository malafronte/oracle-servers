# Guida completa alle risorse Always Free di Oracle Cloud Infrastructure

Documento riepilogativo di tutte le risorse incluse nel piano [OCI Always Free](https://www.oracle.com/it/cloud/free/#always-free), con riferimenti alla documentazione ufficiale e note pratiche per il tuo scenario (sviluppatore singolo, 2 VM ARM/AMD, stack Docker + Traefik + Portainer).

---

## Infrastruttura

### 1. Compute – 2 VM AMD (1/8 OCPU, 1 GB RAM ciascuna)

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Compute/Concepts/computeoverview.htm

VM x86 con processore AMD EPYC, 1 GB RAM, ideali per micro-servizi o bastion host. Nel tuo caso: **<NOME_SERVER2>** è una di queste (VM.Standard.E2.1.Micro, 1 OCPU, 1 GB).

**Utile per te**: Sì (già in uso come s2). Puoi usarla per Docker Registry o servizi leggeri.

---

### 2. Compute – Ampere A1 ARM (4 OCPU, 24 GB RAM totali)

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Compute/References/arm.htm

Processore ARM Neoverse-N1. I 24 GB e 4 OCPU possono essere usati come **1 VM unica** o **fino a 4 VM** (es. 4x1 OCPU/6 GB). Include 3.000 ore OCPU/mese e 18.000 GB-ore/mese (una VM sempre accesa consuma circa 720 ore/mese, quindi fino a 4 VM).

**Nel tuo caso**: **<NOME_SERVER>** usa tutti i 4 OCPU e 24 GB come VM unica. Perfetta per Docker + Traefik + tutti i tuoi progetti.

---

### 3. Block Storage – 2 volumi, 200 GB totali

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Block/Concepts/overview.htm

Storage a blocchi (come un disco SSD di rete) attaccabile alle VM. I volumi di boot sono già inclusi nelle VM e non contano nel limite. I 200 GB sono per volumi **aggiuntivi**.

**Nel tuo caso**: se un domani un container ha bisogno di storage persistente più performante di un volume Docker su disco root, attacchi un block volume alla VM.

---

### 4. Object Storage – Standard (10 GB)

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Object/Concepts/objectstorageoverview.htm

Storage oggetti ad alta durabilità, accessibile via API S3-compatibile, HTTP, CLI. Ideale per backup, asset statici, log.

**Nel tuo caso**: già pianificato per il backup automatico del Docker Registry.

---

### 5. Object Storage – Infrequent Access (10 GB)

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Object/Concepts/understandingstoragetiers.htm

Stesso servizio Object Storage ma con costo di storage inferiore e costo di recupero più alto. Per dati a cui accedi **raramente** (log storici, backup vecchi).

**Nel tuo caso**: backup mensili del registry oltre i 7 giorni, log storici dei container.

---

### 6. Archive Storage (10 GB)

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Archive/Concepts/archivestorageoverview.htm

Dati archiviati a lungo termine. Il recupero **non è istantaneo** (può richiedere ore). Costa pochissimo.

**Nel tuo caso**: snapshot annuali, backup che speri di non dover mai recuperare.

---

### 7. Resource Manager – Terraform gestito

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resourcemanager.htm

Servizio che esegue Terraform senza installare nulla in locale. Gli fornisci i file `.tf`, lui esegue `plan`, `apply`, `destroy` e mantiene lo stato. Supporta GitHub/GitLab/Bitbucket come fonte delle configurazioni.

**Nel tuo caso**: se definisci l'infrastruttura OCI come codice (VCN, subnet, compute, IAM), Resource Manager la gestisce senza che tu debba occuparti del file `.tfstate`.

---

### 8. OCI Bastions (fino a 5)

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Bastion/Concepts/bastionoverview.htm

Tunnel SSH temporaneo gestito da OCI per accedere a risorse **senza IP pubblico**. Tre tipi di sessione: Managed SSH (richiede OCI Cloud Agent), Port Forwarding (tunnel TCP), SOCKS5 proxy (accesso dinamico alla subnet).

**Nel tuo caso**: se metti una VM in subnet privata (niente IP pubblico), usi un Bastion per connetterti via SSH invece di esporre la porta 22 a internet.

---

## Database

### 9. Autonomous Database – 2 istanze, 1 OCPU, 20 GB ciascuna

**Documentazione**: https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-always-free.html

**Workload disponibili**: Transaction Processing, Lakehouse, JSON, APEX Service. **Versioni**: Oracle 19c o 26ai (solo in alcune region).

**Limitazioni Always Free**:
- Max 30 sessioni simultanee
- Nessun backup (manuale o automatico)
- Inattività > 7 giorni → arresto automatico; > 90 giorni spento → **eliminazione definitiva**
- Solo endpoint pubblico (non dentro VCN)
- Solo nella home region del tenancy

**Nel tuo caso**: usabile come database di sviluppo/test. Per produzione con utenti reali, meglio MariaDB/PostgreSQL nei container Docker.

---

### 10. NoSQL Database – 25 GB storage, fino a 3 tabelle

**Documentazione**: https://docs.oracle.com/en-us/iaas/nosql-database/index.html

Database NoSQL serverless con modello chiave-valore e documenti. 133 milioni di letture/mese, 133 milioni di scritture/mese, fino a 3 tabelle.

**Nel tuo caso**: utile se un progetto ha bisogno di un NoSQL per dati semi-strutturati (es. sessioni utente, cache, configurazioni dinamiche). Alternativa a Redis per dati persistenti.

---

## Osservabilità e gestione

### 11. Monitoring – 500M ingestion, 1B retrieval datapoints

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Monitoring/Concepts/monitoringoverview.htm

Piattaforma di monitoring per metriche e allarmi. Raccoglie dati da tutte le risorse OCI (Compute, Object Storage, Load Balancer, ecc.) e supporta metriche custom via API.

**Caratteristiche**:
- **Metrics**: raccolta e visualizzazione metriche (CPU, RAM, rete, dischi)
- **Alarms**: notifiche quando le metriche superano soglie (es. CPU > 90%)
- **MQL**: Monitoring Query Language per interrogare le metriche

**Nel tuo caso**: monitorare CPU/RAM delle VM, creare allarmi che ti avvisano via email se la RAM di s1 supera il 90%.

---

### 12. Application Performance Monitoring (APM) – 1000 eventi/ora

**Documentazione**: https://docs.oracle.com/en-us/iaas/application-performance-monitoring/index.html

Tracciamento distribuito delle applicazioni (simile a Datadog APM). Traccia chiamate HTTP, query database, errori tra microservizi.

**Nel tuo caso**: utile quando CineBase avrà frontend + backend + database e vuoi capire dove sono i colli di bottiglia.

---

### 13. Logging – 10 GB/mese

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Logging/Concepts/loggingoverview.htm

Servizio centralizzato per log. Tre tipi:
- **Audit logs**: log automatici di tutte le chiamate API OCI
- **Service logs**: log dai servizi OCI (VCN Flow Logs, Load Balancer, Object Storage, ecc.)
- **Custom logs**: log dalle tue applicazioni via API o Unified Monitoring Agent

I 10 GB sono **condivisi** tra VCN Flow Logs, service logs e custom logs.

**Nel tuo caso**: abilitare VCN Flow Logs per tracciare tutto il traffico di rete, e inviare i log dei container al logging centralizzato.

---

### 14. Notifications – 1M HTTPS/mese, 1.000 email/mese

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Notification/Concepts/notificationoverview.htm

Servizio di notifiche tramite topic e sottoscrizioni. Supporta: **Email**, **SMS**, **Slack**, **PagerDuty**, **HTTPS (webhook)**, **Oracle Functions**.

**Nel tuo caso**: abbinato a Monitoring, ricevi una notifica email se la CPU della VM supera il 90%. O abbinato a Events, ricevi una notifica quando un container si ferma inaspettatamente.

---

### 15. Connector Hub – 2 connettori

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/connector-hub/overview.htm

Bus di messaggi che sposta dati tra servizi OCI. Configuri una **source** (es. Logging), un **target** (es. Object Storage), e connettori opzionali (es. Functions per elaborare i dati).

**Esempi di flusso**:
- Logging → Object Storage: archivia i log automaticamente su bucket
- Monitoring → Notifications: invia metriche come notifiche
- Streaming → Functions → Object Storage: elabora stream di dati e salva risultati

**Nel tuo caso**: archiviare automaticamente i log su Object Storage senza scrivere codice.

---

## Servizi aggiuntivi

### 16. Load Balancer flessibile – 1 istanza, 10 Mbps

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Balance/Concepts/balanceoverview.htm

Bilanciatore Layer 7 (HTTP/HTTPS) con SSL termination, session persistence, health check, routing per hostname/path.

**Nel tuo caso**: ❌ Traefik fa già da reverse proxy L7 + terminazione SSL. Non ti serve.

---

### 17. Flexible Network Load Balancer – 1 istanza, 10 Mbps

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/NetworkLoadBalancer/introduction.htm

Bilanciatore Layer 3-4 (TCP/UDP/ICMP) a bassissima latenza. Tre modalità: Full NAT, Source Preservation, Transparent (bump-in-the-wire).

**Nel tuo caso**: ⬜ Servirebbe se avessi più VM da bilanciare a livello TCP (es. più backend dietro un unico IP). Per ora non ti serve.

---

### 18. Trasferimento dati in uscita – 10 TB/mese

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/overview.htm

I primi **10 TB al mese** di traffico in uscita dalle tue VM verso internet sono gratuiti. Il traffico in ingresso è sempre gratuito. Il traffico tra VM nella stessa region OCI non conta.

**Nel tuo caso**: più che sufficiente per 3-4 progetti web. 10 TB sono circa 30 milioni di pagine HTML servite al mese.

---

### 19. Virtual Cloud Network (VCN) – massimo 2

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/overview.htm

Rete privata virtuale con subnet, security list, route table, gateway (Internet, NAT, Service). Supporta IPv4 e IPv6.

**Nel tuo caso**: hai già una VCN attiva. La seconda può servire per isolare ambienti (es. test vs produzione).

---

### 20. VCN Flow Logs – 10 GB/mese (condivisi con Logging)

Documentazione: vedi **Logging** (punto 13).

Registra tutto il traffico di rete accettato e rifiutato nella VCN. Utile per diagnosticare connettività e rilevare tentativi di accesso.

---

### 21. VPN Site-to-Site – 50 connessioni IPSec

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/managingIPsec.htm

Collega la rete di casa/ufficio alla VCN tramite tunnel VPN crittografato. Richiede un Dynamic Routing Gateway (DRG). Supporta anche connessioni ad AWS, Azure, Google Cloud.

**Nel tuo caso**: se volessi accedere alle VM senza esporre SSH su internet, colleghi il router di casa via VPN.

---

### 22. Content Management Starter Edition – 5.000 asset/mese

**Documentazione**: https://docs.oracle.com/en/cloud/paas/content-cloud/index.html

Piattaforma di content management headless con API REST per gestire documenti, immagini, video.

**Nel tuo caso**: ❌ Non ti serve oggi. I tuoi asset (immagini, PDF) li servi direttamente dai container.

---

### 23. Certificati – 5 CA private, 150 certificati TLS privati

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/certificates/overview.htm

Certificate Authority privata interna a OCI. Emette certificati TLS fidati solo all'interno della tua infrastruttura, non riconosciuti dai browser pubblici.

**Usi tipici**:
- mTLS tra servizi interni
- Autenticazione tra container
- Test TLS prima di passare a certificati pubblici

**Nel tuo caso**: ⬜ Traefik usa già Let's Encrypt per certificati pubblici. Le CA private servirebbero per HTTPS interno tra container (es. Traefik → backend via HTTPS con certificati interni).

---

### 24. Email Delivery – 3.000 email/mese

**Documentazione**: https://docs.oracle.com/en-us/iaas/Content/Email/Concepts/overview.htm
**Guida introduttiva**: https://docs.oracle.com/en-us/iaas/Content/Email/Reference/gettingstarted.htm

Servizio SMTP gestito per email **transazionali** (registrazione, reset password, notifiche). **Non** è una casella di posta personale.

**Limiti**:
- **200 email/giorno**, max 10/minuto
- Max 2 MB per messaggio (inclusi allegati)
- Richiede configurazione **SPF** e **DKIM** sul dominio

#### Come si configura (una volta sola)

1. **Console OCI** → Developer Services → Email Delivery
2. Crea un **Email Domain** (es. `<DOMINIO>`)
3. Aggiungi i record **SPF** e **DKIM** al tuo DNS (te li fornisce la console OCI)
4. Crea un **Approved Sender** (l'indirizzo mittente, es. `noreply@<DOMINIO>`)
5. Genera le **SMTP credentials**: ottieni username e password (diversi dal login OCI)

#### Connessione SMTP

```
Host:     smtp.email.eu-milan-1.oci.oraclecloud.com
Porta:    465 (TLS implicito)
Username: <OCID_USER>.credential...@<OCID_TENANCY>.   (generato al punto 5)
Password: la password generata al punto 5
TLS:      obbligatorio (non funziona senza)
```

> Il mittente (`From`) deve corrispondere esattamente a un **Approved Sender** configurato. Puoi crearne fino a 2.000.

#### Esempio con MailKit (.NET)

```csharp
using var client = new SmtpClient();
await client.ConnectAsync(
    "smtp.email.eu-milan-1.oci.oraclecloud.com",
    465,
    SecureSocketOptions.SslOnConnect
);
await client.AuthenticateAsync("<OCID_USER>.cred...", "la-password-smtp");

var message = new MimeMessage();
message.From.Add(new MailboxAddress("CineBase", "noreply@<DOMINIO>"));
message.To.Add(new MailboxAddress("", "utente@email.com"));
message.Subject = "Conferma prenotazione";
message.Body = new TextPart("html") { Text = "<h1>Grazie!</h1>" };

await client.SendAsync(message);
await client.DisconnectAsync(true);
```

Stesso codice che useresti con Gmail SMTP o SendGrid — cambi solo host, porta e credenziali.

**Nel tuo caso**: ✅ CineBase e le tue app useranno Email Delivery per inviare email di conferma, recupero password, notifiche. Gratuito, già integrato in OCI, reputation gestita da Oracle.

---

## Riepilogo: cosa conviene usare subito

| Risorsa | Priorità | Motivo |
|---------|----------|--------|
| Compute Ampere A1 (s1) | ✅ In uso | Tutti i container Docker |
| Compute AMD Micro (s2) | ✅ In uso | Seconda VM free |
| Object Storage Standard | ✅ Alta | Backup registry, log |
| Email Delivery | ✅ Alta | Email da CineBase e app |
| Logging + VCN Flow Logs | ✅ Media | Audit e diagnostica |
| Monitoring + Notifications | ✅ Media | Allarmi CPU/RAM |
| Bastion | ⬜ Futura | Se sposti VM in subnet privata |
| Autonomous Database | ⬜ Test | Database di sviluppo |
| NoSQL Database | ⬜ Test | Dati semi-strutturati |
| VPN Site-to-Site | ⬜ Futura | Accesso privato da casa |
| Certificate private | ⬜ Futura | mTLS interno |
| Load Balancer | ❌ No | Traefik lo fa già |
| Content Management | ❌ No | Non ti serve |
