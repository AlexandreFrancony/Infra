"""Drop from Traefik's acme.json the certificates of hostnames no longer routed, never printing keys. (2026-11-02)

Traefik keeps renewing every certificate it stores, even for retired subdomains; those without a DNS record fail at
each restart. Run on the VPS, Traefik stopped only for the edit (it rewrites the file):
  python3 ~/prune-acme.py hosts && docker stop traefik && python3 ~/prune-acme.py; docker start traefik
The routed hostnames come from Traefik's API, read before the stop, so nothing still in use is removed.
"""
import json
import re
import shutil
import subprocess
import sys
import time

ACME = '/home/bloster/config/letsencrypt/acme.json'
ROUTED = '/tmp/routed-hosts.txt'


def routed_hosts() -> set[str]:
    with open(ROUTED, encoding='utf-8') as f:
        return set(f.read().split())


def save_routed_hosts() -> None:
    out = subprocess.run(['docker', 'exec', 'traefik', 'wget', '-qO-', 'http://localhost:8080/api/http/routers?per_page=500'],
                         capture_output=True, text=True, check=True).stdout
    rules = ' '.join(router.get('rule', '') for router in json.loads(out))
    hosts = sorted(set(re.findall(r'Host\(`([^`]+)`\)', rules)))
    assert len(hosts) >= 5, hosts
    with open(ROUTED, 'w', encoding='utf-8') as f:
        f.write(' '.join(hosts))
    print('routed:', ' '.join(hosts))


def prune() -> None:
    keep = routed_hosts()
    with open(ACME, encoding='utf-8') as f:
        data = json.load(f)
    backup = f'{ACME}.bak-{time.strftime("%Y%m%d-%H%M")}'
    shutil.copy2(ACME, backup)
    for resolver in data.values():
        certs = resolver.get('Certificates') or []
        kept = [c for c in certs if c['domain']['main'] in keep]
        dropped = sorted(c['domain']['main'] for c in certs if c['domain']['main'] not in keep)
        resolver['Certificates'] = kept
        print(f'kept {len(kept)}, dropped {len(dropped)}:', ' '.join(dropped))
    with open(ACME, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    print('backup:', backup)


if __name__ == '__main__':
    save_routed_hosts() if sys.argv[1:] == ['hosts'] else prune()
