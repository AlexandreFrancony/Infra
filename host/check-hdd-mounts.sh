#!/bin/bash
# Do the containers see the USB HDD, or the empty /mnt/hdd directory of the SSD under it? (2026-11-02)
# A container started before the drive was mounted keeps the SSD directory until it restarts: same path, other
# inode. No sudo needed: `bash ~/Hosting/Infra/host/check-hdd-mounts.sh`. Exit code 1 if one is wrong.
set -uo pipefail
mount_at=$(systemctl show mnt-hdd.mount -p ActiveEnterTimestampMonotonic --value)
docker_at=$(systemctl show docker.service -p ExecMainStartTimestampMonotonic --value)
if [ "$mount_at" -gt 0 ] && [ "$mount_at" -le "$docker_at" ]; then
  echo "OK  disque monté $(( (docker_at - mount_at) / 1000 )) ms avant le démarrage de Docker"
else
  echo "KO  Docker a démarré avant le montage du disque (ou disque absent)"
fi
bad=0
for c in $(docker ps --format '{{.Names}}'); do
  docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{println}}{{end}}{{end}}' |
    grep '^/mnt/hdd' | while IFS='|' read -r src dst; do
      inside=$(docker exec "$c" stat -c %i "$dst" 2>/dev/null)
      if [ "$inside" = "$(stat -c %i "$src")" ]; then echo "OK  $c $dst"; else echo "KO  $c $dst (dossier du SSD)"; exit 1; fi
    done || bad=1
done
exit $bad
