#!/bin/bash
# Initialize SSL certificates for all domains
# Run this once on first setup

set -e

DOMAINS=(
    "admin.francony.fr"
    "tipsy.francony.fr"
    "mtg.francony.fr"
    "status.francony.fr"
    "logs.francony.fr"
)

EMAIL="alex@francony.fr"  # Change to your email

echo "=== Francony SSL Certificate Setup ==="
echo ""

# Create directories
mkdir -p certbot/conf certbot/www

# Start nginx temporarily for ACME challenge
echo "Starting temporary nginx for ACME challenge..."
docker compose up -d nginx-proxy

# Wait for nginx to start
sleep 5

# Generate certificates for each domain
for domain in "${DOMAINS[@]}"; do
    echo ""
    echo "=== Generating certificate for $domain ==="

    docker compose run --rm certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email $EMAIL \
        --agree-tos \
        --no-eff-email \
        -d $domain
done

echo ""
echo "=== All certificates generated! ==="
echo ""
echo "Restarting nginx with SSL..."
docker compose restart nginx-proxy

echo ""
echo "Done! Your sites should now be accessible via HTTPS."
