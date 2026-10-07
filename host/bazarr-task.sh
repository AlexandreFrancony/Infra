#!/bin/sh
# Runs Bazarr scheduled tasks by id (POST /api/system/tasks), from bloster's crontab: the subtitle searches are set to
# "Never" in Bazarr, whose intervals start whenever it restarts and kept waking the media disk at night.
# The API key is read inside the container and never leaves it.
for task in "$@"; do
    docker exec bazarr python3 -c '
import re, sys, urllib.parse, urllib.request
key = re.search(r"^auth:\n(?:  .*\n)*?  apikey: (\S+)", open("/config/config/config.yaml").read(), re.M).group(1)
data = urllib.parse.urlencode({"taskid": sys.argv[1]}).encode()
req = urllib.request.Request("http://localhost:6767/api/system/tasks", data=data, headers={"X-API-KEY": key})
print(sys.argv[1], urllib.request.urlopen(req, timeout=30).status)
' "$task"
done
