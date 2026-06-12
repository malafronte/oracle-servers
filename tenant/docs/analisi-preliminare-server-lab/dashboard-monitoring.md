# Dashboard di monitoring per container Docker su ARM64

---

## Confronto rapido

| | Prometheus + Grafana | Netdata | Beszel | Dozzle |
|---|---|---|---|---|
| **RAM** | 500 MB - 1 GB | 200-300 MB | ~50 MB | ~30 MB |
| **Container** | 3 (Prometheus, Grafana, cAdvisor) | 1 | 2 (hub + agent) | 1 |
| **Cosa monitora** | Metriche container, sistema, applicative (custom) | **Tutto**: CPU, RAM, rete, dischi, container, processi, allarmi | CPU, RAM, dischi, container, storico | Solo log dei container |
| **Storico** | Sì, retention configurabile | Sì, retention configurabile | Sì | No (live streaming) |
| **Allarmi** | Sì (Prometheus Alertmanager) | **Sì** (integrato, notifiche su decine di canali) | No | No |
| **Curva setup** | Alta — 3 container, file di config, dashboards | **Bassa** — un container, 5 righe di compose | Media | Minima |
| **ARM64** | ✅ (immagini ufficiali) | ✅ (immagini ARM64 native) | ✅ | ✅ |
| **Adatto a te** | ⚠️ Overkill per un server solo | ✅ Raccomandato | ⬜ Buono per CPU/RAM, no logs | ❌ Solo log |

---

## Raccomandazione: Netdata

Motivi:
- **Un container**, setup in 30 secondi
- **Scoperta automatica** dei container Docker: li rileva e inizia a monitorarli senza configurazione
- **Allarmi integrati**: CPU alta, disco pieno, container down, con notifiche su email/Discord/Slack/Telegram
- **Dashboard web** completa con grafici real-time e storico
- **ARM64 nativo**, 200-300 MB RAM costanti
- **Zero configurazione**: si auto-configura. L'unica cosa da impostare sono gli allarmi (via file di config o API)
- **Esporta metriche Prometheus** se un giorno vorrai Grafana

---

## Installazione

Aggiungi al `~/docker/traefik/docker-compose.yml` **oppure** crea un file separato `~/docker/netdata/docker-compose.yml`:

```yaml
# ~/docker/netdata/docker-compose.yml
services:
  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    restart: unless-stopped
    hostname: s1
    pid: host                          # accesso ai processi di sistema
    cap_add:
      - SYS_PTRACE                     # per monitorare processi
      - SYS_ADMIN                      # per monitorare dischi
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./config:/etc/netdata:ro
      - netdata-lib:/var/lib/netdata
      - netdata-cache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro   # per scoprire container
    environment:
      - NETDATA_CLAIM_TOKEN=          # opzionale, per Cloud (vedi sotto)
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.netdata.rule=Host(`monitor.<DOMINIO>`)"
      - "traefik.http.routers.netdata.entrypoints=websecure"
      - "traefik.http.routers.netdata.tls.certresolver=letsencrypt"
      - "traefik.http.services.netdata.loadbalancer.server.port=19999"
      # Proteggi con basic auth
      - "traefik.http.routers.netdata.middlewares=netdata-auth"
      - "traefik.http.middlewares.netdata-auth.basicauth.users=admin:$$2y$$05$$..."

volumes:
  netdata-lib:
  netdata-cache:

networks:
  traefik-net:
    external: true
```

### Password per basic auth

```bash
echo $(htpasswd -nbB admin "TuaPasswordSicura") | sed -e s/\\$/\\$\\$/g
# Incolla l'output nella label basic auth sopra
```

### DNS

Aggiungi record A: `monitor.<DOMINIO>` → `129.152.30.86`

### Avvio

```bash
mkdir -p ~/docker/netdata && cd ~/docker/netdata
docker compose up -d
```

### Primo accesso

`https://monitor.<DOMINIO>` → login basic auth → dashboard completa.

---

## Con Portainer hai già...

Portainer mostra già per ogni container: CPU, RAM, rete, I/O disco in tempo reale (tab **Stats**). Se questo ti basta, non serve Netdata. Netdata lo aggiungi se vuoi:

- **Storico** delle metriche (Portainer mostra solo live)
- **Allarmi** via email/Telegram quando qualcosa va male
- **Dashboard unica** con tutti i container + sistema in una pagina
- **Esportazione Prometheus** per integrazioni future

---

## Opzione 2 — Dozzle (solo log, leggerissimo)

Se vuoi solo vedere i log dei container in una bella UI senza installare nulla di complesso:

```yaml
# ~/docker/dozzle/docker-compose.yml
services:
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - traefik-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dozzle.rule=Host(`logs.<DOMINIO>`)"
      - "traefik.http.routers.dozzle.entrypoints=websecure"
      - "traefik.http.routers.dozzle.tls.certresolver=letsencrypt"
      - "traefik.http.services.dozzle.loadbalancer.server.port=8080"

networks:
  traefik-net:
    external: true
```

30 MB di RAM. Log in tempo reale, ricerca full-text, split-screen per confrontare più container.

---

## Opzione 3 — Prometheus + Grafana + cAdvisor

Solo se un giorno vorrai dashboard custom e metriche applicative. Per ora non ti serve, ma se vuoi esplorarlo:

- **cAdvisor**: raccoglie metriche da Docker (`google/cadvisor:latest`)
- **Prometheus**: le immagazzina e le espone via API (`prom/prometheus:latest`)
- **Grafana**: le visualizza (`grafana/grafana:latest`)

Template dashboard Docker già pronto: [ID 193](https://grafana.com/grafana/dashboards/193-docker-monitoring/) su grafana.com.

RAM: 500 MB - 1 GB.

---

## Schema finale con Netdata

```
s1 (Ampere 24 GB)
├── Traefik (:80/:443)
├── Portainer (portainer.dominio)
├── Netdata (monitor.dominio)      ← ← dashboard monitoring
├── Docker Registry
├── Forgejo + PostgreSQL + 2 runner
├── CineBase stack
├── Blog stack
└── Progetti futuri...

RAM totale infrastruttura: ~4.2 GB (con Netdata incluso)
RAM libera per progetti: ~19.8 GB
```
