#!/bin/bash
# Runs on the VPS every 5 min (cron). Watches Torgal from outside and alerts through a Discord webhook,
# never through Torgal or the ProDesk: it exists for the day those are the ones down.
# Config next to this script (not in git): webhook.url (600) and optionally mention (a Discord user ID).
DIR="$(cd "$(dirname "$0")" && pwd)"
HEALTH_URL="${HEALTH_URL:-https://torgal.francony.fr/health}"
STATE="$DIR/watch.state"
REMIND_EVERY=36  # checks, i.e. every 3 h while it lasts

[ -s "$DIR/webhook.url" ] || { echo "torgal-watch: no webhook.url, nothing to alert through"; exit 0; }
WEBHOOK=$(cat "$DIR/webhook.url")
MENTION=$([ -s "$DIR/mention" ] && echo "<@$(cat "$DIR/mention")> ")

post() {
  jq -n --arg content "$MENTION$1" '{username: "Veille VPS", content: $content}' \
    | curl -s -m 15 -H "Content-Type: application/json" --data-binary @- "$WEBHOOK" > /dev/null
}

response=$(curl -s -m 20 -w '\n%{http_code}' "$HEALTH_URL")
code=${response##*$'\n'}
body=${response%$'\n'*}
read -r failures since 2> /dev/null < "$STATE" || { failures=0; since=0; }

if [ "$code" = "200" ]; then
  [ "$failures" -ge 2 ] && post "✅ Torgal répond de nouveau (panne d'environ $(( ($(date +%s) - since) / 60 )) min)."
  echo "0 0" > "$STATE"
  exit 0
fi

failures=$((failures + 1))
[ "$since" = 0 ] && since=$(date +%s)
echo "$failures $since" > "$STATE"
# Two failures in a row (~10 min) absorb a Torgal redeploy or a tunnel blip
if [ "$failures" -eq 2 ] || [ $((failures % REMIND_EVERY)) -eq 0 ]; then
  reason=$(jq -r '.problem // empty' <<< "$body" 2> /dev/null)
  post "🚨 **Torgal ne répond plus** depuis ~$(( ($(date +%s) - since) / 60 + 5 )) min (HTTP ${code:-000}${reason:+ : $reason}). Le ProDesk, le tunnel ou Torgal est en panne : aucune autre alerte n'arrivera tant que ça dure."
fi
