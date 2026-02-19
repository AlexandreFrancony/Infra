# Francony Infrastructure

Central database, auto-deployment webhook, and shared services for all *.francony.fr applications.

[![Admin](https://img.shields.io/badge/admin-admin.francony.fr-blue)](https://admin.francony.fr)

## Architecture Overview

```
                    ┌──────────┐
                    │  GitHub  │──webhook──┐
                    └──────────┘           │
                                           ▼
┌──────────┐     ┌─────────────────────────────────────────┐
│ Internet │────►│          VPS (OVH, Debian 13)           │
└──────────┘     │  Pangolin (Traefik + Gerbil + CrowdSec) │
                 │  SSL termination (Let's Encrypt)         │
                 └──────────────┬──────────────────────────┘
                                │ WireGuard tunnel
                                ▼
                 ┌─────────────────────────────────────────┐
                 │       HP ProDesk 400 G5 (Debian 13)     │
                 │  ┌─────────────────────────────────┐    │
                 │  │     Docker Containers (9)        │    │
                 │  │                                  │    │
                 │  │  ┌───────┐ ┌───┐ ┌──────────┐   │    │
                 │  │  │ Tipsy │ │MTG│ │Cash-a-lot│   │    │
                 │  │  └───────┘ └───┘ └──────────┘   │    │
                 │  │                                  │    │
                 │  │  ┌──────────┐                    │    │
                 │  │  │Calv-a-lot│ (copy-trading)     │    │
                 │  │  └──────────┘                    │    │
                 │  │                                  │    │
                 │  │  ┌──────────┐ ┌────────┐        │    │
                 │  │  │ postgres │ │ webhook │        │    │
                 │  │  └──────────┘ └────────┘        │    │
                 │  │                                  │    │
                 │  │  ┌──────┐                        │    │
                 │  │  │ newt │  (WireGuard client)    │    │
                 │  │  └──────┘                        │    │
                 │  └─────────────────────────────────┘    │
                 └─────────────────────────────────────────┘
```

## Services

| Domain | Service | Description |
|--------|---------|-------------|
| `admin.francony.fr` | Admin Dashboard | Central control panel with system stats |
| `tipsy.francony.fr` | Tipsy | Cocktail ordering application |
| `mtg.francony.fr` | MTG Collection | Magic card collection tracker |
| `crypto.francony.fr` | Cash-a-lot | AI crypto trading bot (Claude Haiku) |
| `webhook.francony.fr` | Webhook Server | GitHub webhook receiver for auto-deploy |
| `calv.francony.fr` | Calv-a-lot | Copy-trading follower for Cash-a-lot |

## Admin Dashboard

The admin dashboard (`admin.francony.fr`) provides:

- **System Monitoring**: CPU, RAM, Disk usage, Temperature
- **Docker Status**: All containers with health status
- **SSL Certificates**: Expiry tracking for all domains
- **Quick Links**: Access to all services (Tipsy, MTG, Cash-a-lot)

### API Endpoints

| Endpoint | Description |
|----------|-------------|
| `/api/system` | CPU, RAM, Disk, Temperature, Uptime |
| `/api/docker` | Docker container status |
| `/api/ssl` | SSL certificate expiry info |

## Directory Structure

```
~/Hosting/                          # On ProDesk
├── Infra/                          # This repo
│   ├── admin/
│   │   └── index.html              # Admin dashboard (static)
│   ├── compose/
│   │   ├── bartending.yml          # Bartending full stack (api + frontend)
│   │   └── bartending.env          # Bartending environment variables
│   ├── database/
│   │   ├── 00-create-mtg-database.sh
│   │   └── 01-create-cashalot-database.sh
│   ├── newt/
│   │   ├── docker-compose.yml      # Newt tunnel client (WireGuard → VPS)
│   │   └── .env
│   ├── webhook-server/
│   │   ├── server.py               # Flask webhook + monitoring API
│   │   ├── deploy.sh               # Deployment script
│   │   ├── projects/               # Project configs (YAML)
│   │   └── Dockerfile
│   └── docker-compose.yml          # Central: postgres + webhook-server
├── Bartending/                     # Tipsy app (3 repos)
│   ├── Bartending_DB/
│   ├── Bartending_Back/
│   └── Bartending_Front/
├── MTG-Collection/                 # MTG app (1 repo)
├── Cash-a-lot/                     # AI crypto trading bot
└── Calv-a-lot/                     # Copy-trading follower
```

## Docker Stack

| Service | Port (internal) | Network | Description |
|---------|------|---------|-------------|
| `postgres` | 5432 | all app networks | Central PostgreSQL (bartending + mtg + cashalot) |
| `webhook-server` | 9000 | proxy-network | GitHub webhook receiver + admin API |
| `newt` | 2112 | all networks | WireGuard tunnel client to VPS (Pangolin) |

> Reverse proxy and SSL are handled by **Pangolin (Traefik)** on the VPS. No local proxy needed.

## Auto-Deployment

### How it Works

1. Push code to GitHub (main/prod branch)
2. GitHub sends webhook to `webhook.francony.fr/deploy`
3. Webhook server verifies HMAC-SHA256 signature and identifies project
4. Acquires deployment lock (prevents concurrent deploys)
5. Runs `deploy.sh`: git pull → docker compose build → up -d --force-recreate
6. Releases lock, prunes old images

### Project Configuration

Projects are configured via YAML files in `webhook-server/projects/`:

**bartending.yml**
```yaml
name: Bartending
path: Bartending
compose_file: /home/bloster/Hosting/Infra/compose/bartending.yml
branch: [prod, main]
repos: [Bartending_DB, Bartending_Back, Bartending_Front]
```

**mtg.yml**
```yaml
name: MTG-Collection
path: MTG-Collection
branch: [master, main]
repos: [MTG-Collection]
```

**cashalot.yml**
```yaml
name: Cash-a-lot
path: Cash-a-lot
branch: [main]
repos: [Cash-a-lot]
```

**calvalot.yml**
```yaml
name: Calv-a-lot
path: Calv-a-lot
branch: [main]
repos: [Calv-a-lot]
```

**infra.yml**
```yaml
name: Infra
path: Infra
branch: [master, main]
repos: [Infra]
```

### Webhook Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/health` | GET | None | Health check |
| `/projects` | GET | HMAC-SHA256 | List configured projects |
| `/status` | GET | None | Deployment lock status |
| `/deploy` | POST | HMAC-SHA256 | GitHub webhook receiver |
| `/reload-config` | POST | HMAC-SHA256 | Reload project configs |

## First Time Setup

### 1. Prerequisites

- HP ProDesk (or any Debian server) with Docker + Docker Compose
- OVH VPS running Pangolin (Traefik + Gerbil + CrowdSec)
- Newt tunnel configured between ProDesk and VPS
- DNS records pointing to VPS IP (Pangolin handles routing)

### 2. Clone Repositories

```bash
mkdir -p ~/Hosting
cd ~/Hosting

# Central infrastructure
git clone https://github.com/AlexandreFrancony/Infra.git

# Applications
mkdir -p Bartending
cd Bartending
git clone https://github.com/AlexandreFrancony/Bartending_DB.git
git clone https://github.com/AlexandreFrancony/Bartending_Back.git
git clone https://github.com/AlexandreFrancony/Bartending_Front.git
cd ..

git clone https://github.com/AlexandreFrancony/MTG-Collection.git
git clone https://github.com/AlexandreFrancony/Cash-a-lot.git
git clone https://github.com/AlexandreFrancony/Calv-a-lot.git
```

### 3. Configure Environment

```bash
cd ~/Hosting/Infra
cp .env.example .env
nano .env  # Set POSTGRES_PASSWORD, WEBHOOK_SECRET, etc.

cd newt
cp .env.example .env
nano .env  # Set PANGOLIN_ENDPOINT, NEWT_ID, NEWT_SECRET
```

### 4. Start the Stack (Order Matters!)

```bash
# 1. Start Newt tunnel first (connects to VPS)
cd ~/Hosting/Infra/newt
docker compose up -d

# 2. Start apps (they create their networks)
cd ~/Hosting/Bartending/Bartending_Front
docker compose up -d  # Creates bartending_network

cd ~/Hosting/MTG-Collection
docker compose up -d  # Creates mtg_network

cd ~/Hosting/Cash-a-lot
docker compose up -d  # Creates cashalot_network

cd ~/Hosting/Calv-a-lot
docker compose up -d  # Creates calv-a-lot_default

# 3. Start central infrastructure (connects to all networks)
cd ~/Hosting/Infra
docker compose up -d

# 4. Start Bartending full stack (uses centralized compose)
docker compose -f compose/bartending.yml --env-file compose/bartending.env up -d
```

### 5. Configure GitHub Webhooks

For each repository:
1. Go to **Settings** → **Webhooks** → **Add webhook**
2. **Payload URL:** `https://webhook.francony.fr/deploy`
3. **Content type:** `application/json`
4. **Secret:** (same as `WEBHOOK_SECRET` in `.env`)
5. **Events:** Just the push event

## Maintenance

### View Logs

```bash
# Webhook server logs
docker compose logs -f webhook

# Deployment logs (inside webhook container)
docker exec webhook-server cat /var/log/infra/deploy.log

# Newt tunnel logs
cd ~/Hosting/Infra/newt && docker compose logs -f

# All infrastructure logs
docker compose logs -f
```

### Check Status

```bash
# Webhook health
curl https://webhook.francony.fr/health

# List projects
curl https://webhook.francony.fr/projects

# System stats
curl https://admin.francony.fr/api/system

# Docker status
curl https://admin.francony.fr/api/docker
```

### Manual Deployment

```bash
# Trigger deployment for a specific project
curl -X POST https://webhook.francony.fr/deploy \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_WEBHOOK_SECRET" \
  -d '{"ref":"refs/heads/main","repository":{"name":"MTG-Collection"},"pusher":{"name":"manual"}}'
```

## SSL Certificates

SSL is managed by **Traefik** (part of Pangolin) on the VPS. Certificates are automatically provisioned and renewed via Let's Encrypt TLS-ALPN-01 challenge. No local certbot or certificate management is needed on the ProDesk.

## Related Repositories

- [Bartending_Back](https://github.com/AlexandreFrancony/Bartending_Back) - Tipsy API (Express.js)
- [Bartending_Front](https://github.com/AlexandreFrancony/Bartending_Front) - Tipsy frontend (React)
- [Bartending_DB](https://github.com/AlexandreFrancony/Bartending_DB) - Tipsy database (PostgreSQL)
- [MTG-Collection](https://github.com/AlexandreFrancony/MTG-Collection) - MTG card tracker
- [Cash-a-lot](https://github.com/AlexandreFrancony/Cash-a-lot) - AI crypto trading bot
- [Calv-a-lot](https://github.com/AlexandreFrancony/Calv-a-lot) - Copy-trading follower for Cash-a-lot

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.
