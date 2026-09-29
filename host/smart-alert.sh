#!/bin/bash
# Called by smartd (as root, see setup-root.sh) when a disk reports a problem: posted to Torgal, email as fallback.
. "$(dirname "$(readlink -f "$0")")/../backup/notify.sh"
notify "smart_$(basename "${SMARTD_DEVICE:-disk}")" true "[SMART] Disque ${SMARTD_DEVICE:-?} : ${SMARTD_FAILTYPE:-problème}" \
  "${SMARTD_MESSAGE:-Voir journalctl -u smartd}"
