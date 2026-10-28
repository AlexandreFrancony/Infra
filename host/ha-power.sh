#!/bin/sh
# Forced command of Home Assistant's SSH key (see setup-ha-power.sh): the only two things Torgal may ask of the
# ProDesk. The minute of delay leaves time to say "annule l'arrêt du ProDesk".
case "$SSH_ORIGINAL_COMMAND" in
  poweroff) exec sudo -n /usr/sbin/shutdown -h +1 ;;
  cancel) exec sudo -n /usr/sbin/shutdown -c ;;
  *) echo "refused: $SSH_ORIGINAL_COMMAND" >&2; exit 1 ;;
esac
