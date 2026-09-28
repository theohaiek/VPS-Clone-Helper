# Operations manual - <target name>

Living document. Updated: <UTC>. Job history and decisions: `STATE.md` (same folder).

## Rules
- The source (<aliases>) is read-only, forever.
- Configuration mirrors the source except the divergences listed below.
- <user constraints from BRIEF.md>

## Access
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service ls'   # <role>
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'docker ps'           # <role>
ssh -i .vps-clone/keys/id_ed25519 root@<ip>                            # plain ssh also works
```
- Root login: key only (`.vps-clone/keys/id_ed25519`). Lost the key: provider console -> rescue mode.
- Provider console: <provider, account, project> (credentials are the owner's).

## Where secrets live
| Secret | Local | On the server |
|---|---|---|
| DB / admin passwords (rotated) | `.vps-clone/render/secrets.json` | `/root/vps-clone/stacks/*.yml` (600) |
| Panel admin (e.g. Portainer) | `.vps-clone/render/portainer_admin.env` | - |
| Identity keys kept from the source | `.vps-clone/render/stacks/*.yml` | stack files |

## Service map
| URL / port | Stack / service | Node | Volume | Login |
|---|---|---|---|---|

## Security
- Firewall: `vps-clone-firewall` (`/etc/vps-clone/firewall.env`), reapplied on every Docker start.
- SSH: `/etc/ssh/sshd_config.d/10-vps-clone.conf`.
- Swap / sysctl: `/etc/sysctl.d/99-vps-clone.conf`. Docker logs: `/etc/docker/daemon.json`.
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'vps-clone-firewall --status'
```

## Backups
- Schedule: <cron> (`/etc/cron.d/vps-clone-backup`), config `/etc/vps-clone/backup.env`.
- Retention: <days>. Copies: <peer / offsite>. Last success: `/root/backups/last_ok`.
- Restore (tested on <date>):
```bash
<restore commands per engine>
```

## Day to day
```bash
docker service ls
docker service ps <service> --no-trunc          # why a task failed
docker service logs --since 30m <service> 2>&1 | tail -100
docker service update --force -d <service>      # restart one service
bash /root/vps-clone/scripts/verify_web.sh --ip <ip> <hosts...>
```
Change a stack: edit `render/mapping.json` (or the source export), rerun `stacks.py render`, upload, then
update it with its original method (Portainer API for Portainer-managed stacks, `docker stack deploy` for CLI ones).

## Updates
- Before: backup. After: `verify_web.sh`, `docker service ls`, overlay DNS test.
- Docker engine upgraded in place: `for s in $(docker service ls -q); do docker service update --force -d "$s"; done`.

## Divergences from the source
| What | Source | Target | Why |
|---|---|---|---|

## Known pitfalls
| Symptom | Cause | Fix |
|---|---|---|

## Rebuild from zero (destructive, only with the owner's order)
<exact ordered command list that recreated this environment>
