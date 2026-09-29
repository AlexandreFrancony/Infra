# VPS scripts (server-ovh, user `bloster`)

Installed in `~/torgal-watch/` on the VPS, run by **systemd user timers** (the VPS has no cron and no
sudo; `loginctl enable-linger bloster` keeps them running without a session). Units live in
`~/.config/systemd/user/`: `torgal-watch.{service,timer}`, `crowdsec-digest.{service,timer}`.

| Script | When | What |
|---|---|---|
| `torgal-watch.sh` | every 5 min | `GET https://torgal.francony.fr/health` from outside; after 2 failures (~10 min) posts to a **Discord webhook** (not through Torgal or the ProDesk, which may be what's down), reminds every 3 h, and posts when it's back |
| `housekeeping.sh` | Sunday 03:30 UTC | deletes the 10 MB temporary files CrowdSec leaves in its `/tmp`, rotates Traefik's access log (copy + truncate, gzip, 8 weeks kept) and prunes images unused for 7 days |
| `crowdsec-digest.sh` | Monday 07:00 UTC | a week of CrowdSec alerts (count, top scenarios, origins) and current bans, posted to Torgal's `vps` hook (→ `#journal`) |

Config files next to the scripts, **not in git**, mode 600:
- `webhook.url` — Discord webhook of `#alertes` (Channel settings → Integrations → Webhooks). Without it the watchdog only logs.
- `mention` — Discord user ID to mention in watchdog alerts.
- `torgal.url` — `https://torgal.francony.fr/hooks/vps/<token>`, token = `vps` entry of Torgal's `HOOK_TOKENS`.

`setup-root.sh` is the only part that needs root (`sudo bash ~/torgal-watch/setup-root.sh`, run 2026-09-29): 2 GB of
swap (the VPS had none), Pangolin's `docker-compose.yml` and Traefik's config made editable by bloster, and a
snapshot of Pangolin's config in `~/backups/` before an upgrade.

Update after a change here: `scp vps/*.sh server-ovh:torgal-watch/`.
Logs: `journalctl --user -u torgal-watch -u crowdsec-digest` on the VPS.
