#!/bin/bash
# Disk space alert — notifies (Torgal, email fallback) if usage exceeds threshold
# Cron: 0 8 * * * /home/bloster/Hosting/Infra/backup/disk-alert.sh

THRESHOLD=85
# Present while an alert is open, so the next run below the threshold reports the recovery
STATE_FILE="$HOME/.cache/disk-alert.active"

. "$(dirname "$0")/notify.sh"

ALERT=""

while IFS= read -r line; do
  usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
  mount=$(echo "$line" | awk '{print $6}')
  size=$(echo "$line" | awk '{print $2}')
  used=$(echo "$line" | awk '{print $3}')
  avail=$(echo "$line" | awk '{print $4}')

  if [ "$usage" -ge "$THRESHOLD" ]; then
    ALERT="${ALERT}${mount} : ${usage} % utilisés (${used} sur ${size}, ${avail} libres)\n"
  fi
done < <(df -h / /mnt/hdd 2>/dev/null | tail -n +2)

if [ -n "$ALERT" ]; then
  notify disk_space true "Disque presque plein" "$(printf '%b' "${ALERT}Libère de la place.")"
  mkdir -p "$(dirname "$STATE_FILE")" && touch "$STATE_FILE"
elif [ -f "$STATE_FILE" ]; then
  notify disk_space_ok false "Place disque retrouvée" "Tous les disques sont repassés sous ${THRESHOLD} %." disk_space \
    && rm -f "$STATE_FILE"
fi
