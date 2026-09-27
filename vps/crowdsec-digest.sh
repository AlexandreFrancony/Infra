#!/bin/bash
# Runs on the VPS every Monday (cron): a week of CrowdSec activity, posted to Torgal (#journal).
# Config next to this script (not in git): torgal.url (600), Torgal's hook URL for the "vps" source.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -s "$DIR/torgal.url" ] || { echo "crowdsec-digest: no torgal.url"; exit 1; }

# --limit 0: cscli otherwise stops at 50 alerts
alerts=$(docker exec crowdsec cscli alerts list --since 168h --limit 0 -o json) || exit 1
bans=$(docker exec crowdsec cscli decisions list --limit 0 -o json | jq '[.[]?.decisions[]?] | length')
count=$(jq 'length' <<< "$alerts")
scenarios=$(jq -r '[.[].scenario | sub("^crowdsecurity/"; "")] | group_by(.) | map({n: length, s: .[0]})
  | sort_by(-.n) | .[:5] | map("\(.n) × \(.s)") | join(", ")' <<< "$alerts")
origins=$(jq -r '[.[].source.cn // "?"] | group_by(.) | map({n: length, c: .[0]})
  | sort_by(-.n) | .[:5] | map("\(.c) \(.n)") | join(", ")' <<< "$alerts")

message="🛡️ **CrowdSec, 7 derniers jours** : $count alertes, $bans adresses bloquées en ce moment."
[ "$count" -gt 0 ] && message+=$'\n'"Principales attaques : $scenarios"$'\n'"Origines : $origins"
jq -n --arg message "$message" '{event: "crowdsec_weekly", severe: false, message: $message}' \
  | curl -sf -m 20 -H "Content-Type: application/json" --data-binary @- "$(cat "$DIR/torgal.url")" > /dev/null
