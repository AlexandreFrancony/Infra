#!/bin/bash
set -euo pipefail

# === Restic Backup Script — ProDesk → VPS OVH ===
# Runs daily via cron at 03:00

RESTIC_REPOSITORY="sftp:server-ovh:/home/bloster/backups/prodesk"
RESTIC_PASSWORD_FILE="/home/bloster/.restic-password"
RESTIC="/home/bloster/bin/restic"
SQLITE3="/home/bloster/bin/sqlite3"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

LOGFILE="/tmp/backup-$(date +%Y%m%d).log"
BACKUP_OK=true

# notify(): Torgal (Discord), email as fallback
. "$(dirname "$0")/notify.sh"

# Redirect all output to logfile AND stdout
exec > >(tee -a "$LOGFILE") 2>&1

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
echo "=========================================="
echo "Backup started: $TIMESTAMP"
echo "=========================================="

# --- Pre-backup: database dumps ---
echo "[1/4] Dumping databases..."

echo "  - Immich Postgres..."
docker exec immich-postgres pg_dumpall -U postgres > /tmp/immich-db-dump.sql
echo "    Done ($(du -h /tmp/immich-db-dump.sql | cut -f1))"

echo "  - Infra Postgres (central)..."
docker exec postgres pg_dumpall -U bartender > /tmp/infra-db-dump.sql
echo "    Done ($(du -h /tmp/infra-db-dump.sql | cut -f1))"

echo "  - Vaultwarden SQLite..."
$SQLITE3 /home/bloster/Hosting/Vaultwarden/data/db.sqlite3 ".backup /tmp/vaultwarden-backup.sqlite3"
echo "    Done ($(du -h /tmp/vaultwarden-backup.sqlite3 | cut -f1))"

echo "  - Nextcloud Postgres..."
docker exec nextcloud-postgres pg_dumpall -U nextcloud > /tmp/nextcloud-db-dump.sql
echo "    Done ($(du -h /tmp/nextcloud-db-dump.sql | cut -f1))"

echo "  - Nextcloud config..."
docker cp nextcloud:/var/www/html/config/config.php /tmp/nextcloud-config.php
echo "    Done"

# Data that only lives inside containers or in root-owned files, copied out through Docker
STAGE=/tmp/backup-stage
rm -rf "$STAGE" && mkdir -m 700 "$STAGE"
stage() {
  echo "  - $1..."
  if "${@:2}"; then echo "    Done"; else echo "    FAILED"; BACKUP_OK=false; fi
}
torgal_db() {
  docker exec torgal python -c 'import sqlite3; sqlite3.connect("/data/torgal.db").backup(sqlite3.connect("/tmp/torgal-backup.db"))' \
    && docker cp -q torgal:/tmp/torgal-backup.db "$STAGE/torgal.db" \
    && docker exec torgal rm -f /tmp/torgal-backup.db
}
stage "Torgal SQLite" torgal_db
stage "As I've Written uploads" docker cp -q cof_api:/app/uploads "$STAGE/cof-uploads"
stage "Home Assistant config" docker cp -q homeassistant:/config "$STAGE/homeassistant-config"
stage "Triathlon data" docker cp -q triathlon-backend:/data "$STAGE/triathlon-data"

# --- Backup with Restic ---
echo "[2/4] Running restic backup..."
SECONDS=0

set +e
$RESTIC backup \
  /mnt/hdd/immich-upload/ \
  /tmp/immich-db-dump.sql \
  /tmp/vaultwarden-backup.sqlite3 \
  /tmp/infra-db-dump.sql \
  /tmp/nextcloud-db-dump.sql \
  /tmp/nextcloud-config.php \
  /home/bloster/Hosting/Vaultwarden/data/ \
  /home/bloster/Hosting/Syncthing/config/ \
  /home/bloster/Hosting/Infra/ \
  /home/bloster/Hosting/Immich/.env \
  /home/bloster/Hosting/Jellyfin/docker-compose.yml \
  /home/bloster/Hosting/Jellyfin/config/ \
  /home/bloster/Hosting/Immich/docker-compose.yml \
  /home/bloster/Hosting/Nextcloud/docker-compose.yml \
  /home/bloster/Hosting/Nextcloud/.env \
  /home/bloster/Hosting/Bartending/ \
  /home/bloster/Hosting/_archive/ \
  "$STAGE/" \
  /home/bloster/Hosting/Media/ \
  /home/bloster/Hosting/Torgal/.env \
  /home/bloster/Hosting/Triathlon-Dashboard/.env \
  /home/bloster/Hosting/HomeAssistant/docker-compose.yml \
  /home/bloster/Hosting/Syncthing/docker-compose.yml \
  /home/bloster/Hosting/Vaultwarden/docker-compose.yml \
  --exclude="/home/bloster/Hosting/Media/*/config/logs" \
  --exclude="/home/bloster/Hosting/Media/*/config/MediaCover" \
  --exclude="*/.git/*" \
  --exclude="*/node_modules/*" \
  --exclude="*/__pycache__/*" \
  --exclude="*.pyc"
RESTIC_EXIT=$?
set -e

DURATION=$SECONDS

# Exit code 0 = success, 3 = success with warnings (e.g. permission denied on some files)
if [ $RESTIC_EXIT -eq 0 ] || [ $RESTIC_EXIT -eq 3 ]; then
  echo "Backup succeeded in ${DURATION}s (exit code: $RESTIC_EXIT)"
else
  BACKUP_OK=false
  echo "Backup FAILED (exit code: $RESTIC_EXIT)"
fi

# --- Local copy on the USB disk: Nextcloud's files are too big for the VPS ---
echo "[2b/4] Local copy of Nextcloud's files..."
. "$(dirname "$0")/local-restic.sh"
LOCAL_DOCKER_OPTS=(-v /home/bloster/Hosting/Nextcloud/data/userdata:/backup/nextcloud-data:ro
                   -v /tmp/nextcloud-db-dump.sql:/backup/nextcloud-db-dump.sql:ro)
LOCAL_INFO="Copie locale Nextcloud : ECHEC"
if ! mountpoint -q /mnt/hdd; then
  echo "USB disk not mounted, local copy skipped"
  BACKUP_OK=false
elif local_restic backup --host prodesk /backup --exclude "/backup/nextcloud-data/appdata_*/preview" \
    && local_restic forget --host prodesk --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; then
  LOCAL_INFO="Copie locale Nextcloud (disque USB) : OK"
else
  BACKUP_OK=false
fi
echo "$LOCAL_INFO"

# --- Cleanup dumps ---
echo "[3/4] Cleaning up temporary dumps..."
rm -rf "$STAGE"
rm -f /tmp/immich-db-dump.sql /tmp/infra-db-dump.sql /tmp/vaultwarden-backup.sqlite3 /tmp/nextcloud-db-dump.sql /tmp/nextcloud-config.php

# --- Retention policy ---
echo "[4/4] Applying retention policy..."
$RESTIC forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

TIMESTAMP_END=$(date "+%Y-%m-%d %H:%M:%S")
echo "=========================================="
echo "Backup completed: $TIMESTAMP_END"
echo "=========================================="

# --- Send notification ---
if $BACKUP_OK; then
  SNAP_INFO=$($RESTIC snapshots --latest 1 2>&1 | tail -3)
  TOTAL_SIZE=$($RESTIC stats --mode raw-data --json 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
size_gb = d.get("total_size", 0) / (1024**3)
count = d.get("total_file_count", 0)
print("Total: %.2f GB, %d fichiers" % (size_gb, count))
' 2>/dev/null || echo "Stats non disponibles")
  BODY="Backup termine avec succes.
Duree: ${DURATION}s
Date: $(date '+%Y-%m-%d %H:%M')

Dernier snapshot:
${SNAP_INFO}

${TOTAL_SIZE}"
  notify backup_ok false "[OK] Backup ProDesk $(date +%Y-%m-%d)" "$BODY" backup_failed
else
  BODY="Le backup a echoue !
Date: $(date '+%Y-%m-%d %H:%M')

Dernieres lignes du log:
$(tail -50 "$LOGFILE")"
  notify backup_failed true "[FAIL] Backup ProDesk $(date +%Y-%m-%d)" "$BODY"
fi

# Cleanup old logfiles (keep 7 days)
find /tmp -name "backup-*.log" -mtime +7 -delete 2>/dev/null || true
