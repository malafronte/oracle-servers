# Traefik vs Nginx Proxy Manager per s1

Confronto pratico nel contesto del tuo server: ARM64, 3-4 progetti docker-compose indipendenti, multi-dominio, HTTPS automatico.

---

## Tabella comparativa

| | Traefik | Nginx Proxy Manager (NPM) |
|---|---|---|
| **RAM** | ~50 MB | ~30 MB |
| **Container** | 1 | 1 (+ MariaDB se non usi SQLite) |
| **ARM64** | ✅ Immagine multi-arch ufficiale | ✅ `jc21/nginx-proxy-manager` supporta ARM64 |
| **Configurazione** | Label Docker nei container | UI web (clicchi, compili form) |
| **Service discovery** | **Automatica**: rileva container avviati/spenti in tempo reale | **Manuale**: aggiungi ogni dominio/proxy a mano dalla UI |
| **Certificati** | Let's Encrypt automatico, rinnovo incluso | Let's Encrypt automatico, rinnovo incluso |
| **Multi-progetto** | ✅ Ideale: ogni docker-compose ha le sue label, Traefik scopre tutto da solo | ❌ Macchinoso: ogni nuovo progetto = nuova entry manuale nella UI |
| **Curva di apprendimento** | Media (sintassi label, concetti router/middleware/service) | Bassa (interfaccia punta-e-clicca, metafora "aggiungi proxy host") |
| **Middleware** | Ricchissimo: rate limit, basic auth, redirect, IP whitelist, strip prefix, compressione, header sicurezza, circuit breaker | Base: access list (IP + basic auth), custom Nginx config (avanzata, fuori dalla UI) |
| **Dashboard** | Sì (solo monitoring, non si configura da lì) | Sì (monitoring + configurazione, tutto da UI) |
| **Backup configurazione** | File YAML (versionabili, riproducibili) | Database SQLite/MySQL (backup DB, non versionabile come testo) |
| **Sticky sessions** | Sì | No (nella UI) |
| **TCP/UDP proxying** | Sì (entrypoint TCP/UDP) | Solo nella versione "streams" (più complesso) |
| **Wildcard certificati** | Sì | Sì |

---

## Scenario pratico: aggiungere un nuovo progetto

### Con Traefik

Nel `docker-compose.yml` del progetto aggiungi le label e avvii:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.progetto.rule=Host(`progetto.<DOMINIO>`)"
  - "traefik.http.routers.progetto.entrypoints=websecure"
  - "traefik.http.routers.progetto.tls.certresolver=letsencrypt"
  - "traefik.http.services.progetto.loadbalancer.server.port=3000"
```

`docker compose up -d` → certificato generato, dominio attivo. **Fine**.

### Con NPM

1. Apri `https://npm.<DOMINIO>`
2. Login
3. **Hosts → Proxy Hosts → Add Proxy Host**
4. Inserisci `progetto.<DOMINIO>`
5. Inserisci IP e porta del container (es. `172.18.0.5:3000`)
6. Attiva SSL → Let's Encrypt
7. **Save**

Ripeti manualmente per ogni nuovo container. Se il container viene ricreato e l'IP cambia, devi aggiornare l'entry a mano.

---

## Quando NPM è migliore

- Hai **pochi servizi fissi** (es. Portainer, Plex, Home Assistant) che non cambiano mai
- Vuoi **configurare tutto con la UI** senza scrivere file
- Non hai intenzione di aggiungere/rimuovere servizi frequentemente
- Preferisci un approccio **punta-e-clicca** tipo pannello hosting

## Quando Traefik è migliore

- Hai **molti progetti docker-compose indipendenti** (il tuo caso)
- I container vanno e vengono (sviluppo, CI/CD, deploy frequenti)
- Vuoi **infrastruttura come codice** (tutto versionato in Git, riproducibile)
- Hai bisogno di **middleware** su servizi specifici (rate limit sulle API, basic auth sulle dashboard)
- Vuoi che un nuovo progetto si **auto-configuri** senza passare da una UI

---

## Per il tuo scenario s1

**Traefik vince**, per tre motivi decisivi:

1. **Service discovery automatica**: quando fai `docker compose up -d` su un nuovo progetto, Traefik lo vede, genera il certificato, inizia a servire. Con NPM devi entrare nella UI e configurare a mano ogni volta.

2. **Infrastruttura come codice**: ogni docker-compose contiene già tutto ciò che serve per il routing. Cloni il repo su un altro server, fai `docker compose up -d`, funziona. Con NPM devi anche esportare/importare il database di configurazione.

3. **Middleware per servizio**: puoi mettere rate limiting solo sull'API di CineBase, basic auth solo su Netdata e Portainer, IP whitelist sulle dashboard. Con NPM le access list sono globali o duplicate a mano.

**NPM sarebbe la scelta giusta se** avessi 3 servizi fissi che non tocchi mai. Ma tu hai progetti in sviluppo attivo con CI/CD — il discovery automatico di Traefik ti fa risparmiare tempo ogni giorno.
