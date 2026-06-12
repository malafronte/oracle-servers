# Portainer – Casi d'uso nel contesto multi-progetto

Scenario: server ARM singolo, più progetti docker-compose, Traefik come reverse proxy.

---

## Cos'è Portainer

Un'interfaccia web che ti permette di gestire Docker senza usare il terminale. Si installa come container e si raggiunge via browser. **Non sostituisce** docker-compose o Traefik — li **affianca** per comodità visiva.

---

## Caso 1 – Vedere tutti i container e il loro stato

Da **Home → Local → Containers** vedi l'elenco completo:

- Nome del container
- Stato (running, stopped, unhealthy)
- Porte esposte
- Reti a cui è connesso
- Immagine e tag

Da qui puoi cliccare su un container e:
- Vedere i **log in tempo reale**
- Aprire una **console shell** dentro il container
- **Riavviare / fermare / rimuovere** il container
- Ispezionare variabili d'ambiente, volumi, rete

Utile per diagnosticare: _"Questo container è partito? Su che porta sta ascoltando? Che errori ci sono nei log?"_

---

## Caso 2 – Vedere e gestire le immagini Docker

**Home → Local → Images** mostra tutte le immagini scaricate. Puoi:

- Vedere tag, dimensione, data creazione
- **Pull** (scaricare) nuove immagini
- **Rimuovere** immagini inutilizzate per liberare spazio
- **Importare** immagini da file tar

Utile per fare pulizia: `docker system prune` ha l'equivalente grafico.

---

## Caso 3 – Gestire reti e volumi

**Home → Local → Networks** e **Volumes** mostrano:

- Reti Docker create (`traefik-net`, reti interne dei progetti, bridge, ecc.)
- Volumi Docker (dati persistenti di database, upload, ecc.)
- Spazio occupato da ciascun volume

Puoi creare, rimuovere, ispezionare. Comodo per capire _"dove sono finiti i dati del database?"_ o _"quale progetto sta usando quel volume orfano?"_.

---

## Caso 4 – Vedere i log aggregati

In **Home → Local → Containers** clicchi sul nome del container e apri la tab **Logs**. Vedi i log in tempo reale, con ricerca full-text e opzioni di refresh automatico.

Alternativa al terminale `docker logs -f nome-container`, ma con:
- Evidenziazione automatica error/warning
- Possibilità di copiare porzioni di log
- Filtro per data/ora

---

## Caso 5 – Eseguire comandi dentro un container (shell interattiva)

Sempre dalla scheda del container, **Console** → **Connect** apre un terminale dentro il container. Utile per:

- Verificare file di configurazione generati (`cat /etc/nginx/nginx.conf`)
- Controllare connettività di rete (`ping altro-container`, `curl localhost:3000`)
- Ispezionare file system del container
- Debuggare senza fare SSH sul server e poi `docker exec -it`

---

## Caso 6 – Deploy da docker-compose via Portainer (Stacks)

**Home → Local → Stacks** ti permette di caricare un `docker-compose.yml` direttamente dall'interfaccia web:

1. Clicchi **Add stack**
2. Dai un nome (es. `cinebase`)
3. Incolli il contenuto del docker-compose.yml
4. Clicchi **Deploy the stack**

Portainer carica il file, fa `docker compose up -d` e inizia a monitorarlo. Puoi:

- **Modificare** lo stack e ri-deployare
- **Fermare / rimuovere** lo stack (equivalente a `docker compose down`)
- Vedere i container creati da quello stack

⚠️ **Attenzione**: se hai già il docker-compose in una directory su disco, caricarlo via Portainer **crea una copia gestita da Portainer**. Le modifiche successive vanno fatte da Portainer, non dal file su disco. Meglio scegliere un approccio e mantenerlo:

- **Opzione A**: tutto da terminale + docker compose (più controllo)
- **Opzione B**: tutto da Portainer Stacks (più comodo, meno adatto a CI/CD)

---

## Caso 7 – Passare una variabile d'ambiente al volo

Da **Containers → nome container → Duplicate/Edit** puoi modificare variabili d'ambiente senza riscrivere il docker-compose. Utile per test rapidi:

- Cambiare `DEBUG=true` al volo
- Modificare una URL di un'API esterna
- Testare una configurazione prima di scriverla nel file

Poi se funziona, riporti la modifica nel docker-compose.

---

## Caso 8 – Monitorare uso risorse (CPU, RAM, rete)

Da **Home → Local** il dashboard mostra in tempo reale:

- Numero container in esecuzione / fermi
- Numero immagini, volumi, reti
- CPU e RAM totali usati da Docker

Cliccando su un container, tab **Stats**: grafico di CPU, RAM, I/O rete e disco di quel singolo container. Utile per trovare chi sta consumando risorse.

---

## Caso 9 – Gestire più ambienti Docker (endpoints)

Portainer può gestire **più server Docker** da un'unica interfaccia. Nel tuo caso puoi:

- Aggiungere un endpoint per il server locale (già attivo di default)
- Se un domani avessi un secondo VPS, lo aggiungi come endpoint remoto e gestisci tutto dalla stessa UI

**Settings → Environments → Add environment** → scegli Docker (via socket proxy o TCP con TLS).

---

## Caso 10 – Backup e restore di volumi

Portainer non ha un sistema di backup integrato, ma puoi usarlo per identificare cosa backuppare:

1. **Volumes** → vedi tutti i volumi e la loro data di creazione
2. Annoti quali volumi contengono dati importanti (es. `cinebase_pgdata`)
3. Fai backup da terminale:
   ```bash
   docker run --rm -v cinebase_pgdata:/data -v $(pwd):/backup alpine tar czf /backup/cinebase-db-backup.tar.gz -C /data .
   ```

Portainer ti dà la visibilità su **cosa** backuppare; il backup vero lo fai via script o a mano.

---

## Quando usare Portainer vs Terminale

| Situazione | Portainer | Terminale |
|------------|-----------|-----------|
| Vedere se un container è partito | ✅ Rapido | `docker ps` |
| Leggere log | ✅ Comodo, con ricerca | `docker logs -f` |
| Deploy iniziale di un progetto | ❌ Meglio docker compose da file | ✅ `docker compose up -d` |
| Modificare una variabile d'ambiente | ✅ Test rapido | ❌ Modificare file, riavviare |
| Debuggare dentro un container | ✅ Shell dal browser | ✅ `docker exec -it` |
| Backup automatizzato | ❌ Non è il suo ruolo | ✅ Script + cron |
| Configurazioni complesse (label Traefik) | ✅ Visibilità | ✅ Scrivere file YAML |
| Monitorare CPU/RAM | ✅ Grafico in tempo reale | `docker stats` |

---

## Riepilogo

Portainer nel tuo stack serve a:

1. **Vedere** lo stato di tutto senza lanciare comandi
2. **Debuggare** container e reti con l'interfaccia
3. **Monitorare** risorse e log
4. **Modificare** parametri al volo per test
5. **Non** per deploy iniziali, CI/CD, o backup — per quelli restano migliori docker compose + script
