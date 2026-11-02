#!/bin/bash
# Do the containers see the USB HDD, or the empty /mnt/hdd directory of the SSD under it? (2026-11-02)
# A container started before the drive was mounted keeps the SSD directory until it restarts: same path, other
# inode. No sudo needed: `bash ~/Hosting/Infra/host/check-hdd-mounts.sh`. Exit code 1 if one is wrong.
# --notify (cron, after each boot): only the KO lines, posted to Torgal.
set -uo pipefail
if [ "${1:-}" = --notify ]; then
  out=$("$0") && exit 0
  . "$(dirname "$(readlink -f "$0")")/../backup/notify.sh"
  notify hdd_mounts true "Disque dur : des applis ne le voient pas" \
    "$(grep '^KO' <<< "$out")"$'\n'"Elles écrivent sur le SSD : \`docker restart\` de celles en KO."
  exit 1
fi
mount_at=$(systemctl show mnt-hdd.mount -p ActiveEnterTimestampMonotonic --value)
docker_at=$(systemctl show docker.service -p ExecMainStartTimestampMonotonic --value)
if [ "$mount_at" -gt 0 ] && [ "$mount_at" -le "$docker_at" ]; then
  echo "OK  disque monté $(( (docker_at - mount_at) / 1000 )) ms avant le démarrage de Docker"
  bad=0
else
  echo "KO  Docker a démarré avant le montage du disque (ou disque absent)"
  bad=1
fi
for c in $(docker ps --format '{{.Names}}'); do
  docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{println}}{{end}}{{end}}' |
    { grep '^/mnt/hdd' || true; } | while IFS='|' read -r src dst; do
      inside=$(docker exec "$c" stat -c %i "$dst" 2>/dev/null)
      if [ "$inside" = "$(stat -c %i "$src")" ]; then echo "OK  $c $dst"; else echo "KO  $c $dst (dossier du SSD)"; exit 1; fi
    done || bad=1
done
exit $bad
