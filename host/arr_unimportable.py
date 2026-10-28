#!/usr/bin/env python3
"""Hourly (bloster's crontab): drops Sonarr/Radarr queue entries that finished downloading but can't be imported
(files missing) for more than 6 h. Left alone, both apps retry the import every minute and read the downloads folder,
so the media disk never got its 10 quiet minutes to spin down (nights of 21-28/10).

Removed without blocklist and without a new search: nothing gets downloaded in their place.
"""
import json
import re
import subprocess
import urllib.request
from datetime import datetime, timedelta, timezone

STUCK_AFTER = timedelta(hours=6)
STUCK_STATES = {"importPending", "importBlocked", "importFailed"}
APPS = [("sonarr", "http://localhost:8989/api/v3"), ("radarr", "http://localhost:7878/api/v3")]


def api_key(container: str) -> str:
    xml = subprocess.check_output(["docker", "exec", container, "cat", "/config/config.xml"]).decode()
    return re.search(r"<ApiKey>([^<]+)</ApiKey>", xml).group(1)


def call(base: str, path: str, key: str, method: str = "GET", data: dict | None = None) -> dict:
    req = urllib.request.Request(f"{base}{path}", method=method,
                                 data=json.dumps(data).encode() if data is not None else None,
                                 headers={"X-Api-Key": key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def is_dead_import(item: dict, now: datetime) -> bool:
    added = item.get("added")
    return (item.get("trackedDownloadState") in STUCK_STATES and bool(added)
            and now - datetime.fromisoformat(added.replace("Z", "+00:00")) > STUCK_AFTER)


def main() -> None:
    now = datetime.now(timezone.utc)
    for app, base in APPS:
        key = api_key(app)
        dead = [i for i in call(base, "/queue?pageSize=500", key)["records"] if is_dead_import(i, now)]
        if dead:
            call(base, "/queue/bulk?removeFromClient=true&blocklist=false&skipRedownload=true", key,
                 method="DELETE", data={"ids": [i["id"] for i in dead]})
            titles = ", ".join(sorted({i.get("title", "?") for i in dead}))
            print(f"{now:%Y-%m-%d %H:%M} {app}: {len(dead)} imports impossibles retirés ({titles})")


if __name__ == "__main__":
    main()
