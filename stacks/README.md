# Third-party stacks of the ProDesk

Compose files of the stacks that aren't our own code (no GitHub webhook, no build). Each one still runs from its own
folder, `~/Hosting/<Stack>/`, where `docker-compose.yml` is a symlink to the file here: the compose project name and
the relative paths (`./config`, `.env`) stay those of that folder, so moving the file here recreated nothing.

| Folder here | Runs from | Secrets |
|---|---|---|
| `media/` | `~/Hosting/Media` | — |
| `immich/` | `~/Hosting/Immich` | `.env` |
| `jellyfin/` | `~/Hosting/Jellyfin` | — |
| `nextcloud/` | `~/Hosting/Nextcloud` | `.env` |
| `homeassistant/` | `~/Hosting/HomeAssistant` | `.env` |
| `syncthing/` | `~/Hosting/Syncthing` | — |
| `vaultwarden/` | `~/Hosting/Vaultwarden` | `.env` |

Change a stack: edit here, commit, push, then on the ProDesk `cd ~/Hosting/Infra && git pull` and
`cd ~/Hosting/<Stack> && docker compose up -d` (see the `prodesk-recreate` skill before recreating anything).
