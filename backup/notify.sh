# Sourced by backup.sh and disk-alert.sh. Sends to Torgal (Discord) and falls back to email
# only if Torgal can't be reached, so a Torgal outage never hides a failed backup.
# TORGAL_URL lives in notify.env next to this file (gitignored: it holds the hook token).

NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY_EMAIL="alexandre.francony05@gmail.com"
TORGAL_URL=""
[ -f "$NOTIFY_DIR/notify.env" ] && . "$NOTIFY_DIR/notify.env"

send_email() {
  printf "From: Torgal <torgal@francony.fr>\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s" \
    "$NOTIFY_EMAIL" "$1" "$2" | msmtp "$NOTIFY_EMAIL"
}

# notify <event> <severe: true|false> <subject> <body> [<event this one resolves>]
notify() {
  local payload
  payload=$(jq -n --arg event "$1" --argjson severe "$2" --arg message "**$3**"$'\n'"$4" --arg resolves "${5:-}" \
    '{event: $event, severe: $severe, site: "prodesk", message: $message}
     + (if $resolves != "" then {resolves: $resolves} else {} end)')
  if [ -n "$TORGAL_URL" ] && curl -sf -m 15 -X POST -H "Content-Type: application/json" \
       --data-binary "$payload" "$TORGAL_URL" > /dev/null; then
    return 0
  fi
  echo "Torgal unreachable, falling back to email"
  send_email "$3" "$4"
}
