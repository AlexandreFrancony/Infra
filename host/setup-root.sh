#!/bin/bash
# Root part of the ProDesk's setup, idempotent: `sudo bash ~/Hosting/Infra/host/setup-root.sh` (2026-09-29).
# Nothing here touches the network.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# The system journal had grown to 3.7 GB
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=500M\n' > /etc/systemd/journald.conf.d/size.conf
systemctl restart systemd-journald
journalctl --vacuum-size=500M -q

# Disk health: nothing watched the SSD or the USB disk. Short self-test daily at 03:00 (with the backup: a test at 02:00
# woke the media disk every night), long one on the 15th at 10:00,
# alerts to Torgal through smart-alert.sh.
command -v smartctl > /dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq smartmontools > /dev/null
chmod 755 "$HERE/smart-alert.sh"
echo "DEVICESCAN -a -o on -S on -n standby,q -s (S/../.././03|L/../15/./10) -W 4,55,70 -m root -M exec $HERE/smart-alert.sh" \
  > /etc/smartd.conf
systemctl enable --now smartd > /dev/null 2>&1 || true
systemctl restart smartd

for disk in /dev/nvme0n1 /dev/sda; do
  echo "$disk: $(smartctl -H "$disk" | grep -iE 'overall-health|SMART Health Status' || echo 'état SMART illisible')"
done
echo "Journal: $(journalctl --disk-usage | grep -oE '[0-9.]+[KMG]')"
