#!/bin/bash
set -uo pipefail

# === Monthly restore test: are the backups on the VPS actually readable? ===
# Cron: 2nd of the month at 04:30, well after the 03:00 backup (restic check locks the repository).
# Reads a different twelfth of the data each month (all of it over a year), restores the latest snapshot's
# critical files into a private temporary directory and checks them. Production is never touched.

RESTIC_REPOSITORY="sftp:server-ovh:/home/bloster/backups/prodesk"
RESTIC_PASSWORD_FILE="/home/bloster/.restic-password"
RESTIC="/home/bloster/bin/restic"
SQLITE3="/home/bloster/bin/sqlite3"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
MAX_SNAPSHOT_AGE_HOURS=36
DUMPS=(infra nextcloud immich)
UNCHANGED_FILE=/home/bloster/Hosting/Infra/docker-compose.yml  # rarely edited: compared with its restored copy

. "$(dirname "$0")/notify.sh"

LOGFILE="/tmp/backup-verify-$(date +%Y%m).log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== Restore test started: $(date '+%Y-%m-%d %H:%M:%S') ==="
STARTED=$(date +%s)
PROBLEMS=()
REPORT=()

fail() {
  PROBLEMS+=("$1")
  echo "FAIL: $1"
}

# 1. The whole repository's structure, plus this month's twelfth of the data read back from the VPS
SLICE="$((10#$(date +%m)))/12"
if $RESTIC check --read-data-subset="$SLICE"; then
  REPORT+=("Dépôt intègre, tranche $SLICE des données relue depuis le VPS")
else
  fail "restic check en erreur (tranche $SLICE)"
fi

# 2. The latest snapshot is recent
LATEST_JSON=$($RESTIC snapshots --latest 1 --json)
LATEST_ID=$(jq -r '.[-1].short_id' <<< "$LATEST_JSON")
LATEST_TIME=$(jq -r '.[-1].time' <<< "$LATEST_JSON")
AGE_HOURS=$(( ($(date +%s) - $(date -d "$LATEST_TIME" +%s)) / 3600 ))
if [ "$AGE_HOURS" -gt "$MAX_SNAPSHOT_AGE_HOURS" ]; then
  fail "dernier instantané vieux de ${AGE_HOURS} h ($LATEST_ID)"
fi

# 3. Restore its critical files and check them
RESTORE_DIR=$(mktemp -d /home/bloster/restore-verify.XXXX)
chmod 700 "$RESTORE_DIR"
trap 'rm -rf "$RESTORE_DIR"' EXIT
INCLUDES=(--include /tmp/vaultwarden-backup.sqlite3 --include "$UNCHANGED_FILE")
for dump in "${DUMPS[@]}"; do INCLUDES+=(--include "/tmp/$dump-db-dump.sql"); done
if ! $RESTIC restore "$LATEST_ID" --target "$RESTORE_DIR" "${INCLUDES[@]}"; then
  fail "restauration de l'instantané $LATEST_ID impossible"
fi

VAULT="$RESTORE_DIR/tmp/vaultwarden-backup.sqlite3"
if [ -f "$VAULT" ] && [ "$($SQLITE3 "$VAULT" 'PRAGMA integrity_check;')" = "ok" ]; then
  REPORT+=("Vaultwarden : base intègre, $($SQLITE3 "$VAULT" 'SELECT count(*) FROM ciphers;') éléments")
else
  fail "base Vaultwarden absente ou corrompue"
fi

for dump in "${DUMPS[@]}"; do
  file="$RESTORE_DIR/tmp/$dump-db-dump.sql"
  if [ -f "$file" ] && tail -c 300 "$file" | grep -q "dump complete"; then
    REPORT+=("Dump PostgreSQL $dump : complet ($(du -h "$file" | cut -f1), $(grep -c '^CREATE TABLE' "$file") tables)")
  else
    fail "dump PostgreSQL $dump absent ou tronqué"
  fi
done

RESTORED_FILE="$RESTORE_DIR$UNCHANGED_FILE"
if [ ! -f "$RESTORED_FILE" ]; then
  fail "$(basename "$UNCHANGED_FILE") absent de l'instantané"
elif cmp -s "$RESTORED_FILE" "$UNCHANGED_FILE"; then
  REPORT+=("Fichier de config restauré identique à l'actuel")
else
  REPORT+=("Fichier de config restauré différent de l'actuel (modifié depuis la sauvegarde ?)")
fi

DURATION=$(( $(date +%s) - STARTED ))
echo "=== Restore test finished in ${DURATION}s: ${#PROBLEMS[@]} problem(s) ==="

SUMMARY="Instantané $LATEST_ID ($(date -d "$LATEST_TIME" '+%d/%m %H:%M')), vérifié en $((DURATION / 60)) min."
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  notify backup_verify_ok false "[OK] Test de restauration ProDesk $(date +%m/%Y)" \
    "$SUMMARY"$'\n'"$(printf -- '- %s\n' "${REPORT[@]}")" backup_verify_failed
else
  notify backup_verify_failed true "[FAIL] Test de restauration ProDesk $(date +%m/%Y)" \
    "$SUMMARY"$'\n'"$(printf -- '- %s\n' "${PROBLEMS[@]}")"$'\n'"Journal : $LOGFILE"
fi

find /tmp -name "backup-verify-*.log" -mtime +90 -delete 2>/dev/null || true
