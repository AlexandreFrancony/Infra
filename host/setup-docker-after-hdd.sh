#!/bin/bash
# Docker waits for the USB HDD, idempotent: `sudo bash ~/Hosting/Infra/host/setup-docker-after-hdd.sh` (2026-11-02).
# After the 2026-10-28 reboot the drive was mounted after Docker had started: Immich, Jellyfin, Bazarr, rdtclient and
# webhook-server bound the empty /mnt/hdd directory of the SSD and wrote there for 5 days. Wants (not Requires): if
# the drive is missing, Docker still starts after the device timeout (fstab nofail), the sites stay up.
set -euo pipefail
unit=$(systemd-escape --path --suffix=mount /mnt/hdd)
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/after-hdd.conf <<EOF
[Unit]
Wants=$unit
After=$unit
EOF
systemctl daemon-reload
echo "docker.service attend maintenant $unit : $(systemctl show docker.service -p After | grep -o "$unit")"
