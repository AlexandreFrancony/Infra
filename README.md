# Francony Infrastructure

Central reverse proxy, auto-deployment, and shared services for all *.francony.fr applications.

## Architecture

```
[Internet] → [nginx-proxy:80/443] → [Apps]
                    │
                    ├── admin.francony.fr    → Static dashboard
                    ├── tipsy.francony.fr    → Bartending app (bartending_network)
                    ├── mtg.francony.fr      → MTG Collection (mtg_network)
                    ├── status.francony.fr   → Uptime Kuma
                    ├── logs.francony.fr     → Dozzle
                    └── webhook.francony.fr  → Auto-deployment webhook

[GitHub] → webhook.francony.fr → deploy.sh → docker compose up
```

## Directory Structure on Raspberry Pi

```
~/Hosting/
├── Infra/                  ← This repo (central proxy + webhook)
│   ├── nginx/
│   ├── certbot/
│   └── webhook-server/
├── Bartending/             ← Tipsy app
│   ├── Bartending_DB/
│   ├── Bartending_Back/
│   ├── Bartending_Front/
│   └── Bartending_Deploy/
└── MTG-Collection/         ← MTG app
```

## Services

| Service | URL | Description |
|---------|-----|-------------|
| Admin | https://admin.francony.fr | Central dashboard |
| Tipsy | https://tipsy.francony.fr | Bartending app |
| MTG | https://mtg.francony.fr | Card collection tracker |
| Status | https://status.francony.fr | Uptime monitoring |
| Logs | https://logs.francony.fr | Container logs viewer |
| Webhook | https://webhook.francony.fr | GitHub webhook receiver |

## Auto-Deployment

The webhook server automatically deploys apps when you push to GitHub:

1. **Configure GitHub Webhook** on each repo:
   - URL: `https://webhook.francony.fr/deploy`
   - Content type: `application/json`
   - Secret: (same as `WEBHOOK_SECRET` in `.env`)
   - Events: Just the push event

2. **Project Configs** are in `webhook-server/projects/`:
   - `bartending.yml` - Tipsy app (4 repos)
   - `mtg.yml` - MTG Collection (1 repo)

3. **Add new projects** by creating a new YAML file:
   ```yaml
   name: My-Project
   path: My-Project
   branch:
     - main
   repos:
     - My-Project
   ```

## First Time Setup

### 1. Clone all repos

```bash
mkdir -p ~/Hosting
cd ~/Hosting
git clone https://github.com/AlexandreFrancony/Infra.git
git clone https://github.com/AlexandreFrancony/MTG-Collection.git
# Clone Bartending repos...
```

### 2. Create DNS records in OVH

Add A records pointing to your Raspberry Pi's public IP:
- `admin.francony.fr`
- `tipsy.francony.fr`
- `mtg.francony.fr`
- `status.francony.fr`
- `logs.francony.fr`
- `webhook.francony.fr`

### 3. Configure environment

```bash
cd ~/Hosting/Infra
cp .env.example .env
# Edit .env and set WEBHOOK_SECRET
```

### 4. Generate SSL Certificates

```bash
cd ~/Hosting/Infra
chmod +x init-ssl.sh
./init-ssl.sh
```

### 5. Start the apps (order matters!)

```bash
# 1. Start Tipsy first (creates bartending_network)
cd ~/Hosting/Bartending/Bartending_Deploy
docker compose up -d

# 2. Start MTG (creates mtg_network)
cd ~/Hosting/MTG-Collection
docker compose up -d

# 3. Start the central proxy (connects to both networks)
cd ~/Hosting/Infra
docker compose up -d
```

## Maintenance

### View logs
```bash
cd ~/Hosting/Infra
docker compose logs -f nginx-proxy
docker compose logs -f webhook
```

### Check webhook status
```bash
curl https://webhook.francony.fr/health
curl https://webhook.francony.fr/projects
```

### Trigger manual deployment (for testing)
```bash
curl -X POST https://webhook.francony.fr/deploy \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_WEBHOOK_SECRET" \
  -d '{"ref":"refs/heads/main","repository":{"name":"MTG-Collection"},"pusher":{"name":"manual"}}'
```

### Renew SSL certificates
Certbot auto-renews every 12 hours. To force renewal:
```bash
docker compose run --rm certbot certbot renew --force-renewal
docker compose restart nginx-proxy
```

### Update an app manually
```bash
cd ~/Hosting/MTG-Collection
git pull
docker compose up -d --build
```
