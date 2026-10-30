# Slashlight statistics server

This folder holds the collector, the aggregator and the public dashboard for Slashlight's opt-in anonymous statistics. The design, every collected field and the privacy rules are in [docs/telemetry.md](../docs/telemetry.md).

| File | Job |
|---|---|
| `collector.py` | `POST /v1/report`: validates a report, keys the install ID with HMAC and stores one row per install per day (SQLite) |
| `aggregate.py` | Hourly: computes `stats.json` (with the 5-install threshold) and deletes raw reports older than 90 days |
| `dashboard/` | The static public dashboard; it reads `stats.json` and makes no other requests |
| `demo.py` | Fake data for trying the dashboard |

Everything uses the Python standard library only; there is nothing to `pip install`.

## Try it locally

```bash
cd server
export SECRET=dev DATA_DIR=demo-data PUBLIC_DIR=demo-public
python3 demo.py && python3 aggregate.py && cp -R dashboard/. demo-public/
python3 -m http.server -d demo-public 8000      # open http://localhost:8000
python3 -m unittest discover -s tests            # tests
```

## Deploy on AWS

Any Linux machine with Docker works. On AWS the cheapest fit is a **Lightsail** instance or an **EC2 t4g.nano/micro** (ARM, about $3–5 a month).

1. **Create the instance.**
   - Image: Ubuntu 24.04 or Amazon Linux 2023.
   - Open ports 22, 80 and 443 in the firewall or security group.
   - Attach a static IP: an Elastic IP on EC2, a Static IP on Lightsail.
2. **Point DNS at it.** Create an `A` record such as `stats.yourdomain.com` → the static IP. In Route 53 this is a simple record in your hosted zone.
3. **Install Docker:**
   ```bash
   curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER && newgrp docker
   ```
4. **Configure and start:**
   ```bash
   git clone https://github.com/burinworks/slashlight.git && cd slashlight/server
   cp .env.example .env
   sed -i "s/^DOMAIN=.*/DOMAIN=stats.yourdomain.com/; s/^SECRET=.*/SECRET=$(openssl rand -hex 32)/" .env
   docker compose up -d
   ```
   Caddy gets a Let's Encrypt certificate on first start. Check `https://stats.yourdomain.com/health`; the dashboard appears after the first aggregation, which runs within a minute.
5. **Connect the app.** Set the repository variable `TELEMETRY_URL` to `https://stats.yourdomain.com/v1/report`. Then `release.yml` builds it into releases:
   ```bash
   gh variable set TELEMETRY_URL --body https://stats.yourdomain.com/v1/report
   ```

**Backups.** The SQLite database lives in the `data` Docker volume. To back it up:

```bash
docker compose exec collector python -c "import sqlite3; sqlite3.connect('/data/stats.db').backup(sqlite3.connect('/data/backup.db'))"
```

Or snapshot the instance's disk on a schedule (Lightsail and EC2 both support this).

**Updates.**

```bash
git pull && docker compose up -d --build
```

**Never change `SECRET` after launch.** A new secret makes every install look new and breaks retention numbers.
