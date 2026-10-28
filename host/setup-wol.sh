#!/bin/bash
# Wake-on-LAN for the ProDesk, idempotent: `sudo bash ~/Hosting/Infra/host/setup-wol.sh` (2026-10-28).
# The BIOS already allows it (Wake On LAN = Boot to Hard Drive, S5 Maximum Power Savings = Disable); Linux left the
# network card unarmed. NetworkManager arms it again each time it brings the connection up.
# To wake it: a magic packet to 04:0e:3c:c2:60:be, broadcast 192.168.1.255, port 9, from the home network.
set -euo pipefail
conn=$(nmcli -g GENERAL.CONNECTION device show enp2s0)
nmcli connection modify "$conn" 802-3-ethernet.wake-on-lan magic
nmcli device reapply enp2s0
echo "Connexion « $conn » : wake-on-lan = $(nmcli -g 802-3-ethernet.wake-on-lan connection show "$conn")," \
  "carte : $(cat /sys/class/net/enp2s0/device/power/wakeup)"
