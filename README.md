# Francony Infrastructure

Central reverse proxy, auto-deployment webhook, SSL certificates, and shared services for all *.francony.fr applications.

[![Admin](https://img.shields.io/badge/admin-admin.francony.fr-blue)](https://admin.francony.fr)

## Architecture Overview

```
                              ┌─────────────────────────────────────────┐
                              │            Raspberry Pi 4                │
    ┌──────────┐              ├─────────────────────────────────────────┤
    │  GitHub  │──webhook──►  │  ┌─────────────────────────────────┐    │
    └──────────┘              │  │     Central Infrastructure        │    │
                              │  │  ┌───────────────────────────┐   │    │
    ┌──────────┐              │  │  │    nginx-proxy :80/443    │   │    │
    │ Internet │──HTTPS────►  │  │  │    (SSL termination)      │   │    │
    └──────────┘              │  │  └─────────┬─────────────────┘   │    │
                              │  │            │                      │    │
                              │  │  ┌─────────┼─────────────────┐   │    │
                              │  │  │         │                 │   │    │
                              │  │  ▼         ▼          ▼         │    │
                              │  │ ┌───┐   ┌───┐   ┌────────┐     │    │
                              │  │ │Tip│   │MTG│   │Cash-a- │     │    │
                              │  │ │sy │   │   │   │  lot   │     │    │
                              │  │ └───┘   └───┘   └────────┘     │    │
                              │  │                                  │    │
                              │  │  webhook-server :9000            │    │
                              │  │  (auto-deployment)               │    │
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
~/Hosting/                      # On Raspberry Pi
├── Infra/                      # This repo (central proxy + webhook)
│   ├── nginx/
│   │   └── nginx.conf          # Main proxy configuration
│   ├── certbot/
│   │   └── conf/               # Let's Encrypt certificates
│   ├── admin/
│   │   └── index.html          # Admin dashboard (static)
│   ├── webhook-server/
│   │   ├── server.py           # Flask webhook + monitoring API
│   │   ├── deploy.sh           # Deployment script
│   │   ├── projects/           # Project configs (YAML)
│   │   └── Dockerfile
│   └── docker-compose.yml
├── Bartending/                 # Tipsy app (4 repos)
│   ├── Bartending_DB/
│   ├── Bartending_Back/
│   ├── Bartending_Front/
│   └── Bartending_Deploy/
├── MTG-Collection/             # MTG app (1 repo)
└── Cash-a-lot/                 # AI crypto trading bot
```

## Docker Stack

| Service | Port | Network | Description |
|---------|------|---------|-------------|
| `nginx-proxy` | 80, 443 | proxy-network + app networks | Central reverse proxy |
| `postgres` | 5432 (internal) | proxy + app networks | Central PostgreSQL database |
| `webhook-server` | 9000 (internal) | proxy-network | GitHub webhook receiver |
| `certbot` | - | - | SSL certificate renewal |

## Auto-Deployment

### How it Works

1. Push code to GitHub (main/prod branch)
2. GitHub sends webhook to `webhook.francony.fr/deploy`
3. Webhook server verifies signature and identifies project
4. Runs project's `deploy.sh` script
5. Docker containers are rebuilt and restarted

### Project Configuration

Projects are configured via YAML files in `webhook-server/projects/`:

**bartending.yml**
```yaml
name: Bartending
path: Bartending/Bartending_Deploy
branch:
  - main
  - prod
repos:
  - Bartending_DB
  - Bartending_Back
  - Bartending_Front
  - Bartending_Deploy
```

**mtg.yml**
```yaml
name: MTG-Collection
path: MTG-Collection
branch:
  - main
repos:
  - MTG-Collection
```

### Webhook Endpoints

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/health` | GET | None | Health check |
| `/projects` | GET | None | List configured projects |
| `/status` | GET | None | Deployment lock status |
| `/deploy` | POST | HMAC-SHA256 | GitHub webhook receiver |
| `/reload-config` | POST | None | Reload project configs |

## First Time Setup

### 1. Clone Repositories

```bash
mkdir -p ~/Hosting
cd ~/Hosting

# Central infrastructure
git clone https://github.com/AlexandreFrancony/Infra.git

# Applications
git clone https://github.com/AlexandreFrancony/MTG-Collection.git
# ... clone Bartending repos
```

### 2. Create DNS Records

Add A records pointing to your Raspberry Pi's public IP:
- `admin.francony.fr`
- `tipsy.francony.fr`
- `mtg.francony.fr`
- `crypto.francony.fr`
- `webhook.francony.fr`

### 3. Configure Environment

```bash
cd ~/Hosting/Infra
cp .env.example .env
nano .env  # Set WEBHOOK_SECRET
```

### 4. Generate SSL Certificates

```bash
chmod +x init-ssl.sh
./init-ssl.sh
```

### 5. Start the Stack (Order Matters!)

```bash
# 1. Start apps first (they create their networks)
cd ~/Hosting/Bartending/Bartending_Deploy
docker compose up -d

cd ~/Hosting/MTG-Collection
docker compose up -d

cd ~/Hosting/Cash-a-lot
docker compose up -d

# 2. Start central infrastructure (connects to all networks)
cd ~/Hosting/Infra
docker compose up -d
```

### 6. Configure GitHub Webhooks

For each repository:
1. Go to **Settings** → **Webhooks** → **Add webhook**
2. **Payload URL:** `https://webhook.francony.fr/deploy`
3. **Content type:** `application/json`
4. **Secret:** (same as `WEBHOOK_SECRET` in `.env`)
5. **Events:** Just the push event

## Maintenance

### View Logs

```bash
# Nginx proxy logs
docker compose logs -f nginx-proxy

# Webhook server logs
docker compose logs -f webhook

# All logs
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

# SSL certificates
curl https://admin.francony.fr/api/ssl
```

### Renew SSL Certificates

Certbot auto-renews every 12 hours. To force renewal:

```bash
docker compose run --rm certbot certbot renew --force-renewal
docker compose restart nginx-proxy
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

All domains use Let's Encrypt certificates managed by certbot:

| Certificate | Domains Covered |
|-------------|-----------------|
| `admin.francony.fr` | admin.francony.fr |
| `webhook.francony.fr` | webhook.francony.fr |
| `tipsy.francony.fr` | tipsy.francony.fr, mtg.francony.fr |
| `crypto.francony.fr` | crypto.francony.fr |

Certificates are stored in `certbot/conf/live/` and auto-renewed.

## Related Repositories

- [Bartending_Deploy](https://github.com/AlexandreFrancony/Bartending_Deploy) - Tipsy deployment
- [MTG-Collection](https://github.com/AlexandreFrancony/MTG-Collection) - MTG card tracker
- [Cash-a-lot](https://github.com/AlexandreFrancony/Cash-a-lot) - AI crypto trading bot

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.
