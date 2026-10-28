#!/bin/sh
# Forced command of Home Assistant's SSH key (see setup-ha-power.sh): the only things Torgal may ask of the ProDesk.
# poweroff waits a minute, which leaves time to say "annule l'arrêt du ProDesk".
HERE="$(cd "$(dirname "$0")" && pwd)"
# Apps that can be restarted by voice when they get stuck; nothing else
RESTARTABLE="jellyfin nextcloud immich-server pihole"

case "$SSH_ORIGINAL_COMMAND" in
  poweroff) exec sudo -n /usr/sbin/shutdown -h +1 ;;
  cancel) exec sudo -n /usr/sbin/shutdown -c ;;
  backup)
    # Same script and log as the 03:00 cron; it reports to Torgal when done. Detached: the SSH session ends now.
    setsid nohup "$HERE/../backup/backup.sh" >> "$HERE/../backup/backup.log" 2>&1 < /dev/null &
    echo started ;;
  "restart "*)
    name="${SSH_ORIGINAL_COMMAND#restart }"
    for allowed in $RESTARTABLE; do
      [ "$name" = "$allowed" ] && exec docker restart "$name"
    done
    echo "refused: $name" >&2; exit 1 ;;
  *) echo "refused: $SSH_ORIGINAL_COMMAND" >&2; exit 1 ;;
esac
