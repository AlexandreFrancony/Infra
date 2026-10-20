#!/bin/bash
# Runs on the VPS every Monday (cron): a week of CrowdSec activity, posted to Torgal (#journal).
# Config next to this script (not in git): torgal.url (600), Torgal's hook URL for the "vps" source.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -s "$DIR/torgal.url" ] || { echo "crowdsec-digest: no torgal.url"; exit 1; }

# --limit 0: cscli otherwise stops at 50 alerts
alerts=$(docker exec crowdsec cscli alerts list --since 168h --limit 0 -o json) || exit 1
bans=$(docker exec crowdsec cscli decisions list --limit 0 -o json | jq '[.[]?.decisions[]?] | length')
count=$(jq 'length' <<< "$alerts")
# Rule names in words; an unlisted one shows as is, or as a known flaw when it names a CVE
SCENARIO_NAMES='{
  "vpatch-env-access": "lecture de fichiers .env (mots de passe)",
  "vpatch-CVE-2025-29927": "faille Next.js (contournement de connexion)",
  "vpatch-CVE-2025-55182": "faille React (exécution de code)",
  "vpatch-CVE-2025-3248": "faille Langflow",
  "vpatch-git-config": "lecture du dossier .git",
  "vpatch-symfony-profiler": "faille Symfony",
  "appsec-vpatch": "requête malveillante (pare-feu web)",
  "http-sensitive-files": "recherche de fichiers sensibles",
  "http-admin-interface-probing": "recherche de pages d’admin",
  "http-crawl-non_statics": "aspiration de pages en rafale",
  "http-bad-user-agent": "outil de piratage connu",
  "http-path-traversal-probing": "remontée de dossiers (../)",
  "http-cve-probing": "recherche de failles connues",
  "http-wordpress-scan": "recherche de WordPress",
  "http-generic-401-bf": "mots de passe essayés en rafale",
  "http-generic-403-bf": "accès refusés en rafale",
  "CVE-2017-9841": "faille PHPUnit",
  "thinkphp-cve-2018-20062": "faille ThinkPHP",
  "jira_cve-2021-26086": "faille Jira",
  "CVE-2022-41082": "faille Exchange"
}'
COUNTRY_NAMES='{"AE":"Émirats","BE":"Belgique","BG":"Bulgarie","BR":"Brésil","CA":"Canada","CH":"Suisse","CL":"Chili",
  "CM":"Cameroun","CN":"Chine","DE":"Allemagne","ES":"Espagne","FI":"Finlande","FR":"France","GB":"Royaume-Uni",
  "HK":"Hong Kong","ID":"Indonésie","IN":"Inde","IR":"Iran","IT":"Italie","JP":"Japon","KR":"Corée du Sud",
  "LT":"Lituanie","NL":"Pays-Bas","PK":"Pakistan","PL":"Pologne","RO":"Roumanie","RU":"Russie","SE":"Suède",
  "SG":"Singapour","TR":"Turquie","TW":"Taïwan","UA":"Ukraine","US":"États-Unis","VN":"Viêt Nam","ZA":"Afrique du Sud"}'

scenarios=$(jq -r --argjson names "$SCENARIO_NAMES" '[.[].scenario | sub("^[^/]*/"; "")] | group_by(.)
  | map(.[0] as $s | {n: length, s: ($names[$s] // (if $s | test("cve"; "i") then "faille connue (\($s))" else $s end))})
  | sort_by(-.n) | .[:5] | map("• \(.n) × \(.s)") | join("\n")' <<< "$alerts")
origins=$(jq -r --argjson names "$COUNTRY_NAMES" '[.[].source.cn // "?"] | group_by(.) | map({n: length, c: .[0]})
  | sort_by(-.n) | .[:5] | map("\($names[.c] // .c) \(.n)") | join(", ")' <<< "$alerts")

message="🛡️ **CrowdSec, 7 derniers jours** : $count attaques repoussées, $bans adresses bannies en ce moment."
[ "$count" -gt 0 ] && message+=$'\n'"Ce qu’ils cherchaient :"$'\n'"$scenarios"$'\n'"D’où : $origins"
jq -n --arg message "$message" '{event: "crowdsec_weekly", severe: false, message: $message}' \
  | curl -sf -m 20 -H "Content-Type: application/json" --data-binary @- "$(cat "$DIR/torgal.url")" > /dev/null
