# Francony Infrastructure

Central reverse proxy and shared services for all *.francony.fr applications.

## Architecture

```
[Internet] → [nginx-proxy:80/443] → [Apps]
                    │
                    ├── admin.francony.fr    → Static dashboard
                    ├── tipsy.francony.fr    → Bartending app (bartending_network)
                    ├── mtg.francony.fr      → MTG Collection (mtg_network)
                    ├── status.francony.fr   → Uptime Kuma
                    └── logs.francony.fr     → Dozzle
```

## Directory Structure on Raspberry Pi

```
~/
├── infra/              ← This repo (central proxy)
├── bartending/         ← Tipsy app
│   ├── Bartending_DB/
│   ├── Bartending_Back/
│   ├── Bartending_Front/
│   └── Bartending_Deploy/
└── MTG-Collection/     ← MTG app
```

## First Time Setup

### 1. Clone all repos

```bash
cd ~
git clone https://github.com/AlexandreFrancony/Infra.git infra
git clone https://github.com/AlexandreFrancony/MTG-Collection.git
# Tipsy repos should already be in ~/bartending/
```

### 2. Create DNS records in OVH

Add A records pointing to your Raspberry Pi's public IP:
- `admin.francony.fr`
- `tipsy.francony.fr`
- `mtg.francony.fr`
- `status.francony.fr`
- `logs.francony.fr`

### 3. Generate SSL Certificates

```bash
cd ~/infra
./init-ssl.sh
```

### 4. Copy Google credentials for MTG

```bash
# From your PC:
scp google-credentials.json pi@<RASP_IP>:~/MTG-Collection/backend/
```

### 5. Start the apps (order matters!)

```bash
# 1. Start Tipsy first (creates bartending_network)
cd ~/bartending/Bartending_Deploy
docker compose up -d

# 2. Start MTG (creates mtg_network)
cd ~/MTG-Collection
docker compose up -d

# 3. Start the central proxy (connects to both networks)
cd ~/infra
docker compose up -d
```

## Maintenance

### View logs
```bash
docker compose logs -f nginx-proxy
```

### Renew SSL certificates
Certbot auto-renews every 12 hours. To force renewal:
```bash
docker compose exec certbot certbot renew --force-renewal
docker compose exec nginx-proxy nginx -s reload
```

### Update an app
```bash
cd ~/MTG-Collection  # or ~/bartending/Bartending_Deploy
git pull
docker compose up -d --build
```

## Services

| Service | URL | Description |
|---------|-----|-------------|
| Admin | https://admin.francony.fr | Central dashboard |
| Tipsy | https://tipsy.francony.fr | Bartending app |
| MTG | https://mtg.francony.fr | Card collection tracker |
| Status | https://status.francony.fr | Uptime monitoring |
| Logs | https://logs.francony.fr | Container logs viewer |
