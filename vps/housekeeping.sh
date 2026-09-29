#!/bin/bash
# Runs on the VPS every Sunday (systemd user timer): keeps its 75 GB disk from filling up.
set -uo pipefail
KEEP_WEEKS=8

# CrowdSec leaves a 10 MB temporary file in its /tmp now and then and never removes it (1 000 of them by 2026-09)
docker exec crowdsec find /tmp -maxdepth 1 -name 'crzmp*' -mmin +60 -delete

# Traefik's access log (read by CrowdSec) is never rotated. Both keep it open, so it's copied then truncated in place;
# the copy is compressed and 8 weeks are kept.
docker exec traefik sh -c "cd /var/log/traefik && [ -s access.log ] || exit 0
  week=access-\$(date +%F).log
  cp access.log \$week && : > access.log && gzip -f \$week
  ls -t access-*.log.gz | tail -n +$((KEEP_WEEKS + 1)) | xargs -r rm -f"

docker image prune -af --filter until=168h > /dev/null
echo "housekeeping: $(df -h / | awk 'NR==2 {print $5 " used, " $4 " free"}')"
