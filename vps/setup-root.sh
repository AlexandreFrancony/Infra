#!/bin/bash
# Root part of the VPS setup, idempotent: `sudo bash ~/torgal-watch/setup-root.sh` (2026-09-29).
# Everything else is done as bloster, who is in the docker group.
set -euo pipefail
HOME_DIR=/home/bloster

# 2 GB of swap: the VPS had none, and Pangolin's memory leak had left it 300 MB free
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  [ -f /swapfile ] || { fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile > /dev/null; }
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl -q -p /etc/sysctl.d/99-swappiness.conf

# Pangolin's compose file and Traefik's static/dynamic config editable without sudo
chown bloster:bloster "$HOME_DIR/docker-compose.yml" "$HOME_DIR"/config/traefik/*.yml

# Snapshot of Pangolin's config and database, readable by bloster only, before any upgrade
SNAPSHOT="$HOME_DIR/backups/pangolin-config-$(date +%F-%H%M).tar.gz"
# CrowdSec's database and Traefik's logs keep changing and aren't needed to restore Pangolin
tar -czf "$SNAPSHOT" -C "$HOME_DIR" --exclude=config/crowdsec/db --exclude=config/traefik/logs \
  config docker-compose.yml || [ $? -eq 1 ]  # 1 = a file changed while read
chown bloster:bloster "$SNAPSHOT" && chmod 600 "$SNAPSHOT"

echo "OK: swap $(swapon --show=SIZE --noheadings | head -1), snapshot $(du -h "$SNAPSHOT" | cut -f1) in $SNAPSHOT"
