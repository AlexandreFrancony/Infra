#!/bin/bash
# Disk space alert — sends email if usage exceeds threshold
# Cron: 0 8 * * * /home/bloster/Hosting/Infra/backup/disk-alert.sh

THRESHOLD=85
EMAIL="alexandre.francony05@gmail.com"

send_email() {
  local subject="$1"
  local body="$2"
  printf "From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s" \
    "$EMAIL" "$EMAIL" "$subject" "$body" | msmtp "$EMAIL"
}

ALERT=""

while IFS= read -r line; do
  usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
  mount=$(echo "$line" | awk '{print $6}')
  size=$(echo "$line" | awk '{print $2}')
  used=$(echo "$line" | awk '{print $3}')
  avail=$(echo "$line" | awk '{print $4}')

  if [ "$usage" -ge "$THRESHOLD" ]; then
    ALERT="${ALERT}${mount} : ${usage}% utilise (${used}/${size}, ${avail} dispo)\n"
  fi
done < <(df -h / /mnt/hdd 2>/dev/null | tail -n +2)

if [ -n "$ALERT" ]; then
  send_email "[ALERTE] Disque ProDesk - espace faible" \
    "Un ou plusieurs disques depassent ${THRESHOLD}% d'utilisation :\n\n${ALERT}\nVerifiez et liberez de l'espace."
fi
