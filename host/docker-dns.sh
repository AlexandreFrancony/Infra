#!/usr/bin/env bash
# Pin the upstream DNS of every container, then stop the host from using Tailscale's MagicDNS.
#
# Containers inherit their upstream resolvers from the host's /etc/resolv.conf when they start, and that
# file points at Tailscale (100.100.100.100). Turning MagicDNS off on 2026-09-28 broke name resolution in
# every container at once. With "dns" in daemon.json, containers no longer depend on the host's resolvers.
#
# Restarts dockerd, so every container restarts: ~1 min without the sites, Pi-hole or Torgal. Run it in a
# quiet moment: sudo ./docker-dns.sh
set -euo pipefail

CONF=/etc/docker/daemon.json
UPSTREAMS='["1.1.1.1", "8.8.8.8"]'
PROBE_CONTAINER=torgal
PROBE_NAME=discord.com
SITES=(https://tipsy.francony.fr https://jdr.francony.fr https://torgal.francony.fr/health)

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

backup=""
if [[ -e $CONF ]]; then
  backup=$CONF.bak-$(date +%Y%m%d-%H%M%S)
  cp -a "$CONF" "$backup"
fi

restore_config() {
  echo "!! Restoring the previous Docker configuration" >&2
  if [[ -n $backup ]]; then cp -a "$backup" "$CONF"; else rm -f "$CONF"; fi
  systemctl restart docker
}

container_resolves() {
  docker exec "$PROBE_CONTAINER" python -c "import socket; socket.gethostbyname('$PROBE_NAME')" 2>/dev/null
}

wait_for_containers() {
  local expected=$1
  for _ in $(seq 60); do
    [[ $(docker ps -q | wc -l) -ge $expected ]] && container_resolves && return 0
    sleep 3
  done
  return 1
}

python3 - "$CONF" "$UPSTREAMS" <<'PY'
import json, os, sys
path, upstreams = sys.argv[1], json.loads(sys.argv[2])
conf = json.load(open(path)) if os.path.exists(path) else {}
conf["dns"] = upstreams
with open(path, "w") as f:
    json.dump(conf, f, indent=2)
    f.write("\n")
PY
echo "== $CONF"; cat "$CONF"
dockerd --validate --config-file "$CONF" || { restore_config; exit 1; }

running=$(docker ps -q | wc -l)
echo "== Restarting Docker ($running containers running)"
systemctl restart docker
if ! wait_for_containers "$running"; then
  echo "!! Containers did not come back with working DNS" >&2
  restore_config
  exit 1
fi
echo "Containers back: $(docker ps -q | wc -l)/$running, upstreams: $(docker exec "$PROBE_CONTAINER" grep ExtServers /etc/resolv.conf)"

echo "== Turning Tailscale MagicDNS off on the host"
tailscale set --accept-dns=false
sleep 3
if ! container_resolves || ! getent hosts "$PROBE_NAME" >/dev/null; then
  echo "!! DNS broke without MagicDNS, turning it back on" >&2
  tailscale set --accept-dns=true
  exit 1
fi
echo "Host resolvers now: $(grep ^nameserver /etc/resolv.conf | tr '\n' ' ')"

echo "== Sites"
for site in "${SITES[@]}"; do
  printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$site")" "$site"
done
echo "Done. Backup of the previous config: ${backup:-none (there was no daemon.json)}"
