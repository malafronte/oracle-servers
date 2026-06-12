# Confronto soluzioni DevOps self-hosted per ARM Ampere 24 GB

Scenario: server singolo ARM64, stack Docker + Traefik, sviluppatore singolo con possibilità di piccoli team (2-5 persone). Necessità: hosting codice Git, issue tracker, pull request, CI/CD compatibile con GitHub Actions.

---

## 1. GitLab CE

| Caratteristica | Dettaglio |
|----------------|-----------|
| **RAM minima / consigliata** | 4 GB / 8 GB |
| **Container** | ~10 (GitLab Rails, Sidekiq, PostgreSQL, Redis, Gitaly, GitLab Shell, Registry, Prometheus, NGINX) |
| **CI/CD** | GitLab CI integrato (sintassi YAML propria, **non** compatibile con GitHub Actions) |
| **Container Registry** | Integrato |
| **Issues / PR** | Merge Requests, Issues, Epics, Board Kanban, Milestones |
| **Wiki** | Sì |
| **ARM64** | Supportato, ma pesante — la RAM è il collo di bottiglia |
| **Complessità** | Alta: upgrade con migrazioni DB, backup PostgreSQL, tuning continuo |
| **Licenza** | MIT (Community Edition) |

### Pregi

- **Completissimo**: code review, CI/CD, registry, wiki, issues, tutto integrato
- **GitLab CI** potente: pipeline multi-stage, parallel jobs, ambienti, deploy board, Auto DevOps
- **Standard enterprise**: se un giorno passi a un team di 10+, hai già lo strumento giusto

### Difetti

- **Pesante**: 4 GB RAM minimi reali, ~8 GB per usarlo decentemente. Sul tuo server da 24 GB toglie 1/3 della RAM solo per esistere
- **Overkill**: il 90% delle funzionalità enterprise (epics, compliance pipeline, security dashboard, Kubernetes integration) non ti serve
- **Sintassi pipeline diversa**: GitLab CI non è GitHub Actions. Se hai già workflow Actions definiti, li devi riscrivere
- **Manutenzione**: upgrade ogni mese con downtime, backup PostgreSQL, tuning memoria per i worker Sidekiq
- **Non ottimizzato per ARM**: funziona ma è pensato per x86 con molta RAM

---

## 2. Gitea

| Caratteristica | Dettaglio |
|----------------|-----------|
| **RAM minima / consigliata** | 256 MB / 512 MB |
| **Container** | 1-3 (Gitea + DB + runner CI opzionale) |
| **CI/CD** | **Gitea Actions** (compatibile con GitHub Actions! Stessa sintassi YAML) |
| **Container Registry** | Integrato nativamente (dalla 1.20) |
| **Issues / PR** | Pull Request, Issues, Milestones, Board Kanban, Labels |
| **Wiki** | Sì, integrata come repo Git |
| **ARM64** | Supporto nativo, binario Go compilato per ARM64 |
| **Complessità** | Minima: un binario Go, SQLite o PostgreSQL come DB |
| **Licenza** | MIT |

### Pregi

- **Leggerissimo**: 300-500 MB RAM totali (Gitea + PostgreSQL + 2 runner CI). Lascia 23+ GB alle app
- **GitHub Actions compatibile**: i workflow file `.gitea/workflows/*.yml` usano la **stessa sintassi** di GitHub Actions (`runs-on`, `steps`, `uses`, `actions/checkout`, ecc.). Puoi migrare da Actions senza riscrivere nulla
- **Integrato**: Git + Issues + PR + Registry + CI/CD in un unico prodotto
- **Nativo ARM64**: scritto in Go, cross-compilato per ARM, nessun overhead di emulazione
- **Manutenzione bassa**: aggiornamento via `docker compose pull && up -d`, nessuna migrazione DB complessa
- **Community attiva**: 46k+ stelle GitHub, rilasci frequenti
- **Forgejo** (fork mantenuto da una community indipendente) esiste come alternativa se vuoi evitare il modello commerciale di Gitea Ltd.

### Difetti

- **Meno funzionalità di GitLab**: niente Auto DevOps, meno metriche CI, meno integrazioni enterprise
- **CI/CD ancora in evoluzione**: Gitea Actions è maturo ma non ha tutte le feature di GitLab CI (es. deploy environments, approval gates)
- **Interfaccia semplice**: meno curata di GitLab, ma funzionale e veloce
- **Runner separati**: i runner CI vanno installati e registrati (come GitHub Actions self-hosted runner)

---

## 3. Gitea vs Forgejo – confronto approfondito

Forgejo è nato nell'ottobre 2022 come fork di Gitea dopo che il dominio e il trademark di Gitea furono trasferiti a una società a scopo di lucro (Gitea Ltd.) senza approvazione della community. Da inizio 2024 Forgejo è diventato un **hard fork** con codebase divergente.

### Differenze fondamentali

| | Gitea | Forgejo |
|---|---|---|
| **Governance** | Controllato da Gitea Ltd. (società for-profit) | Sotto Codeberg e.V. (associazione non-profit tedesca) |
| **Licenza** | MIT (con cessione copyright obbligatoria per contribuire) | GPL v3+ (dalla v9.0, prima MIT) |
| **Sviluppo** | Su GitHub, test e release via GitHub Actions | Su Forgejo stesso, test e release via Forgejo Actions |
| **Localizzazione** | Su Crowdin (piattaforma proprietaria) | Su Weblate (open source) |
| **Modello economico** | Open Core: feature aggiuntive dietro licenza commerciale | Interamente Free Software, sostenuto da donazioni e grant |
| **Vulnerabilità** | Preavviso solo per clienti paganti | Preavviso pubblico per chiunque |
| **Federazione** | Nessun lavoro in corso | Sviluppo attivo di ForgeFed/ActivityPub |
| **Test di stabilità** | No end-to-end, no upgrade test | End-to-end, upgrade test, test browser con accessibility |

### Cosa significa per te

#### Per progetti con collaboratori

**Forgejo è la scelta migliore** perché:
- Non esiste il rischio che feature vengano messe dietro paywall (modello Open Core di Gitea Ltd.)
- Governance trasparente e community-driven: le decisioni non sono prese da una singola azienda per massimizzare il profitto
- Licenza GPL v3+: protegge il progetto da takeover ostili e garantisce che tutte le modifiche rimangano libere
- Le vulnerabilità vengono comunicate pubblicamente, non solo ai clienti paganti

#### Per ambiente scolastico / studenti

**Forgejo è nettamente superiore** per questi motivi:

1. **Valori allineati con l'istruzione**: organizzazione non-profit, software libero, trasparenza. Insegni agli studenti non solo a usare un tool, ma anche i principi del Free Software. Non stai promuovendo un prodotto commerciale.

2. **Federazione** (in sviluppo): immagina ogni studente con la propria istanza Forgejo che federa con l'istanza del corso. Pull request tra istanze diverse senza mai passare da un server centrale. Come email, ma per il codice. Questo è il futuro della collaborazione decentrata ed è un concetto didatticamente potente.

3. **Nessuna cessione di copyright**: Gitea richiede che i contributor firmino un *Contributor License Agreement* (CLA) cedendo i diritti a Gitea Ltd. Con Forgejo, gli studenti mantengono la proprietà del loro codice.

4. **Zero lock-in**: se un giorno Gitea Ltd. decidesse di cambiare licenza o rendere feature a pagamento, chi usa Gitea è bloccato. Forgejo, essendo GPL e sotto non-profit, garantisce che il software rimanga libero per sempre.

5. **Stesso identico prodotto**: a livello funzionale oggi sono quasi identici (stessa UI, stesse feature, stessa compatibilità GitHub Actions). La differenza è la governance, non il software.

### Perché Gitea ha perso fiducia

La community open source ha reagito male al takeover del 2022. Esempi concreti:
- I domini `gitea.com` e `gitea.io` sono ora controllati da una società commerciale
- Gitea Ltd. ha speso risorse per un audit SOC2 (certificazione per il loro SaaS a pagamento) mentre c'erano vulnerabilità critiche da patchare
- La documentazione di Gitea è stata modificata per rimuovere riferimenti alla community e mettere in evidenza i prodotti commerciali

### Tabella riepilogativa Gitea vs Forgejo

| Criterio | Gitea | Forgejo |
|----------|-------|---------|
| **Rischio commerciale** | Alto (Open Core, paywall possibili) | Nessuno (non-profit, GPL) |
| **Adatto a team** | Sì | Sì |
| **Adatto a scuola** | No (CLA, governance for-profit) | **Sì** (valori FOSS, licenza GPL) |
| **Federazione** | No | In sviluppo |
| **GitHub Actions compatibile** | Sì | Sì |
| **RAM / Carico** | 300-500 MB | 300-500 MB |
| **Migrazione futura** | Migrare da Gitea a Forgejo è facile (stesso DB). Il contrario potrebbe non esserlo in futuro | — |

---

## 4. Alternative minori

### OneDev
**URL**: https://onedev.io  
Git + Issues + CI/CD integrato in Java. Supporta ARM64. Circa 1 GB RAM. Meno conosciuto ma con una UI pulita e alcune idee interessanti (analisi simbolica del codice, query language per le issue).

### Gogs + Woodpecker CI
- **Gogs**: progetto originale da cui Gitea è stato forkato. Sviluppo molto più lento.
- **Woodpecker CI**: fork del vecchio Drone CI, leggero, ottimizzato per Gitea/Forgejo, sintassi pipeline `.woodpecker.yml`.

### Drone CI
CI/CD in Go, integrabile con Gitea/GitHub/GitLab via webhook. Sintassi `.drone.yml`. Leggero (200 MB RAM). Alternativa se vuoi CI/CD separato dalla forge.

---

## 5. Tabella comparativa

| | GitLab CE | Gitea | Forgejo | OneDev |
|---|---|---|---|---|
| **RAM** | 4-8 GB | 300-500 MB | 300-500 MB | 1 GB |
| **Container** | ~10 | 1-3 | 1-3 | 1 |
| **CI/CD** | GitLab CI (sintassi propria) | Actions (compatibile GitHub Actions) | Actions (compatibile GitHub Actions) | OneDev CI (proprio) |
| **Registry Docker** | Integrato | Integrato | Integrato | No |
| **Issues / PR** | Completo | Completo | Completo | Completo |
| **ARM64 nativo** | Funziona via container | Sì (Go) | Sì (Go) | Sì (Java) |
| **Curva apprendimento** | Alta | Bassa | Bassa | Media |
| **Manutenzione** | Alta | Bassa | Bassa | Media |
| **Licenza** | MIT | MIT (CLA obbligatorio) | GPL v3+ | MIT |
| **Governance** | GitLab Inc. (for-profit) | Gitea Ltd. (for-profit) | Codeberg e.V. (non-profit) | Indipendente |
| **Adatto a te** | ❌ Troppo pesante | ⚠️ Rischio commerciale | ✅ Ideale | ⬜ Alternativa |

---

## 6. Raccomandazione finale

**Forgejo + PostgreSQL + 2 runner CI** è la scelta giusta perché:

1. **RAM**: 300-500 MB totali. Lasci ~23 GB ai tuoi container
2. **Compatibilità Actions**: stessi workflow YAML. Se un giorno migri a GitHub, non riscrivi nulla
3. **ARM64 nativo**: binario Go, massima efficienza sulla Ampere
4. **Nessun rischio commerciale**: non-profit, GPL v3+. Il software rimarrà libero per sempre
5. **Pronto per il team**: 2-5 persone, repository privati/pubblici, permessi granulari
6. **Perfetto per la scuola**: insegni Free Software, federazione per il futuro, nessun CLA
7. **Facile da mantenere**: `docker compose pull && docker compose up -d` per aggiornare

### Schema proposto

```
s1 (Ampere 24 GB)
├── Traefik (:80/:443)
├── Portainer (gestione visiva)
├── Docker Registry (:5000)
├── Forgejo (git.dominio.com)
│   ├── PostgreSQL (DB di Forgejo)
│   ├── Forgejo runner 1 (CI/CD)
│   └── Forgejo runner 2 (CI/CD)
├── CineBase stack
├── Blog stack
└── Progetti futuri...
```

Consumo RAM totale stimato con tutto attivo: ~4-5 GB, lasciando ~19 GB per i container applicativi.
