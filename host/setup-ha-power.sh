#!/bin/bash
# Lets Torgal (Home Assistant) act on the ProDesk by voice (shutdown, backup, restart a few apps), idempotent:
# `bash ~/Hosting/Infra/host/setup-ha-power.sh` as bloster (asks for the sudo password once).
# - an SSH key kept in HA's config, allowed only from HA's Docker network and only to run ha-power.sh;
# - a sudo rule for exactly `shutdown -h +1` and `shutdown -c`, nothing else.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
chmod 755 "$HERE/ha-power.sh"

docker exec homeassistant sh -c '
  mkdir -p /config/.ssh && chmod 700 /config/.ssh
  [ -f /config/.ssh/prodesk_power ] || ssh-keygen -q -t ed25519 -N "" -C ha-prodesk-power -f /config/.ssh/prodesk_power'
pubkey=$(docker exec homeassistant cat /config/.ssh/prodesk_power.pub)
grep -qF "$pubkey" ~/.ssh/authorized_keys 2>/dev/null \
  || echo "restrict,from=\"172.25.0.0/16\",command=\"$HERE/ha-power.sh\" $pubkey" >> ~/.ssh/authorized_keys

rule="$USER ALL=(root) NOPASSWD: /usr/sbin/shutdown -h +1, /usr/sbin/shutdown -c"
echo "$rule" | sudo tee /etc/sudoers.d/ha-power > /dev/null
sudo chmod 440 /etc/sudoers.d/ha-power
sudo visudo -cf /etc/sudoers.d/ha-power

# Dry run from HA: an unknown order must be refused (proves the key and the forced command, shuts nothing down)
docker exec homeassistant ssh -i /config/.ssh/prodesk_power -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/config/.ssh/known_hosts bloster@172.25.0.1 ping 2>&1 | tail -1
