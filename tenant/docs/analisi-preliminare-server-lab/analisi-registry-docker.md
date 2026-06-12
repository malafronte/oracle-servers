# Analisi tecnica: Docker Registry vs Harbor vs Gitea Container Registry

Scenario: sviluppatore singolo, server ARM Ampere 24 GB, 3-4 progetti dockerizzati, stack Traefik + Portainer + docker-compose multipli.

---

## 1. Docker Registry (ufficiale)

Il registry ufficiale mantenuto da Docker/CNCF. Immagine `registry:2`.

| Caratteristica | Dettaglio |
|----------------|-----------|
| **RAM a riposo** | ~15-30 MB |
| **Dipendenza DB** | Nessuna (file system locale) |
| **Autenticazione** | htpasswd (basic auth) o token server esterno |
| **TLS** | Nativamente, o delegato a Traefik |
| **Garbage collection** | Comando manuale (`registry garbage-collect`) |
| **UI** | No (esistono UI terze parti, es. `joxit/docker-registry-ui`) |
| **API** | Docker Registry HTTP API V2 (standard) |
| **Cleanup policy** | Nessuna (manuale o via script) |
| **Vulnerability scanning** | No |
| **Replica / mirror** | Supporta pull-through cache verso Docker Hub |
| **Complessità** | Minima — un container, due volumi, 30 righe di config |
| **Licenza** | Apache 2.0 |
| **Aggiornamenti** | `docker compose pull && docker compose up -d` (nessuna migrazione DB) |

### Pregi

- **Leggerissimo**: lascia 23.97 GB di RAM alle applicazioni
- **Zero manutenzione**: niente database, niente upgrade path complessi
- **Standard**: qualsiasi client Docker lo supporta nativamente
- **Pull-through cache**: configurabile per fare da cache locale di Docker Hub, riducendo traffico e latenza

### Difetti

- Nessuna UI (risolvibile con `docker-registry-ui` come container aggiuntivo)
- Nessuna pulizia automatica delle immagini vecchie (si fa con script + `registry garbage-collect`)
- Autenticazione base (nessun RBAC, ruoli, team)

### Quando usarlo

Sviluppatore singolo o piccolo team che vuole un registry privato senza overhead.

---

## 2. Harbor

Progetto CNCF graduato, standard enterprise per registry container on-premise.

| Caratteristica | Dettaglio |
|----------------|-----------|
| **RAM a riposo** | ~2 GB (9 container: core, portal, jobservice, registry, trivy, postgres, redis, log, registryctl) |
| **Dipendenza DB** | PostgreSQL (incluso nel deploy) |
| **Autenticazione** | Database locale, LDAP, OIDC, OAuth2 |
| **TLS** | Nativamente o delegato |
| **Garbage collection** | Automatica, schedulabile |
| **UI** | Portale web completo con dashboard, progetti, log |
| **API** | Docker Registry HTTP API V2 + API REST Harbor |
| **Cleanup policy** | Retention policy per tag (es. mantieni ultimi 10, elimina tag >= 30 giorni) |
| **Vulnerability scanning** | Trivy integrato (scan automatico a ogni push) |
| **Replica / mirror** | Replica tra istanze Harbor, proxy cache verso registry esterni |
| **Complessità** | Alta — 9 container, migrazioni DB a ogni upgrade |
| **Licenza** | Apache 2.0 |
| **Aggiornamenti** | Richiedono migrazione DB (script automatici ma da seguire con attenzione) |

### Pregi

- **Interfaccia web completa**: progetti, membri, ruoli (guest/developer/master/admin), log audit
- **Vulnerability scanning automatico**: Trivy scansiona le immagini a ogni push e blocca il deploy se trovi CVE critiche (configurabile)
- **Retention policy**: "tieni ultimi 5 tag per progetto, cancella il resto" — si imposta e si dimentica
- **Replica e proxy cache**: se hai due server in region diverse, Harbor sincronizza le immagini
- **Robot account**: token per CI/CD con permessi granulari per progetto
- **OCI-compliant**: può servire anche Helm chart, CNAB, OPA bundles

### Difetti

- **Pesante**: 2 GB di RAM solo per esistere, su un server da 24 GB è il 8% fisso, non scalabile verso il basso
- **Complesso**: 9 container da gestire, upgrade con migrazioni DB, downtime pianificato
- **Over-provisioning**: il 90% delle funzionalità (RBAC, LDAP, audit log, replica) è irrilevante per un singolo sviluppatore
- **Boot lento**: ~30 secondi per avviarsi (PostgreSQL + Redis + tutti i servizi)

### Quando usarlo

Team da 5+ persone, ambienti di produzione, compliance aziendale (SOC2, ISO27001), multi-tenancy.

---

## 3. Gitea Container Registry

Integrato in Gitea (forge Git leggera, alternativa a GitHub/GitLab). Dalla versione 1.20 il registry container è nativo.

| Caratteristica | Dettaglio |
|----------------|-----------|
| **RAM a riposo** | ~150-200 MB (Gitea + registry integrato) |
| **Dipendenza DB** | PostgreSQL o SQLite (scelta in installazione) |
| **Autenticazione** | Login Gitea (ereditata dai permessi dei repository) |
| **TLS** | Delegato a Traefik |
| **Garbage collection** | Integrata in Gitea |
| **UI** | Interfaccia Gitea (tab "Packages" nei repository) |
| **API** | Docker Registry HTTP API V2 |
| **Cleanup policy** | Pulizia legata ai branch/tag Git |
| **Vulnerability scanning** | No |
| **Replica / mirror** | No |
| **Complessità** | Bassa (un binario Go o due container) |
| **Licenza** | MIT |
| **Aggiornamenti** | Via Gitea (migrazioni DB automatiche) |

### Pregi

- **Unico login**: stesso utente per codice Git e immagini Docker
- **Permessi ereditati**: se puoi pushare su un repo, puoi pushare l'immagine corrispondente
- **Leggero**: 200 MB invece di 2 GB
- **Tutto in uno**: Git + CI/CD (Gitea Actions) + Registry container

### Difetti

- Il registry esiste solo se usi Gitea come forge. Montare Gitea solo per il registry non ha senso.
- Meno funzionalità di Harbor (nessuno scanning, nessuna retention policy granulare, nessuna replica)
- Tag organization: le immagini sono organizzate per owner/progetto Git, non per progetti arbitrari

### Quando usarlo

Hai già Gitea o vuoi una singola piattaforma per codice + immagini + CI/CD.

---

## Tabella comparativa

| | Docker Registry | Harbor | Gitea Registry |
|---|---|---|---|
| RAM (minima) | 30 MB | 2 GB | 200 MB |
| Container | 1 | 9 | 1-2 |
| DB esterno | Nessuno | PostgreSQL | SQLite/PostgreSQL |
| UI web | Solo con container aggiuntivo | Sì (completa) | Sì (tab Packages) |
| RBAC / ruoli | No (solo htpasswd) | Sì (guest/dev/master/admin) | Ereditato da Gitea |
| Vulnerability scan | No | Sì (Trivy) | No |
| Retention policy | No | Sì (per tag, giorni, conteggio) | No |
| Pull-through cache | Sì | Sì | No |
| Replica multi-sito | No | Sì | No |
| Upgrade path | Nessuno | Migrazioni DB | Via Gitea |
| Adatto a te | ✅ Perfetto | ❌ Overkill | ✅ Solo se usi già Gitea |

---

## Raccomandazione per lo scenario attuale

**Docker Registry ufficiale** con comando:

```
docker compose ──pull──► registry.<DOMINIO>/mio-progetto:latest
                           │
                           └── Docker Registry (:5000)
                               volume ./data (immagini)
                               auth htpasswd (credenziali)
                               Traefik: HTTPS + certificato
```

Eventualmente affiancato da `joxit/docker-registry-ui` se vuoi una UI minimale per sfogliare le immagini.

Harbor si valuterà se un giorno:
- Lavorerai con un team
- Avrai bisogno di vulnerability scanning obbligatorio
- Dovrai gestire decine di progetti con retention policy diverse
