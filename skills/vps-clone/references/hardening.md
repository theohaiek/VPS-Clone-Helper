# Hardening and backups

Read at Phase 10. Everything here runs on target nodes only, through `sshx.py` (never on the source).

## 1. Default posture

The brief (`BRIEF.md`, filled in Phase 1) picks one of two postures:

- **`strict parity`**: reproduce the source exactly, including whatever is insecure there (shared passwords,
  public DB ports, password SSH). Choose this only when the brief says so explicitly - it exists for cases
  where an identical environment matters more than security (a staging mirror, a support reproduction).
- **`parity + security`** (**recommended default** when the brief does not say): same topology and services,
  but new DB/admin passwords, a firewall, SSH keys-only, log rotation, unattended patches and backups. This
  is what every step below assumes.

Either way, record the choice, and every resulting difference from the source, in STATE.md and later in
`OPERATIONS.md`'s divergences table (section 9).

## 2. Firewall: why `DOCKER-USER`, not just `INPUT`/ufw

Docker Swarm's published (`ports:`/`-p`) traffic is routed through `iptables` before it reaches the normal
`INPUT` chain - a plain `ufw`/`INPUT` rule does not see it, so a port that looks blocked can still be open to
the world. `firewall.sh` filters in the `DOCKER-USER` chain instead, the hook Docker leaves for exactly this,
and reapplies it through a systemd drop-in on every `docker.service` start, so a Docker restart or a reboot
never leaves the host unprotected.
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 --put-tree "$S/remote" /root/vps-clone/scripts
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/firewall.sh --peers "198.51.100.21" --install'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/firewall.sh --status'
```
**Always pass `--peers` with every other node's IP**, on every node - the blocked ports include the Swarm
control-plane (2377/7946/4789) and DB ports, so a node installed with no `--peers` cuts itself off from
its own cluster mates too, not just from the internet. Repeat the three commands above per target node,
each with the *other* node(s)' IP(s) in `--peers` (space-separated for 3+ nodes).
Default blocks: the Swarm control-plane ports (2377/tcp, 7946/tcp+udp, 4789/udp) and common DB/broker ports
(3306, 5432, 6379, 27017, 5672, 15672, 9000, 9443, 8080) from outside the cluster - every peer node's IP is
allowed everything. If a provider's own firewall UI cannot be automated reliably, or there is no API token
for it, host-level `iptables` via `firewall.sh` is the fallback that does not depend on the provider at all -
use it as the default, not only as a fallback, since it also covers providers whose firewall API works fine.

## 3. `harden.sh`

```
harden.sh [--ssh-keys-only] [--swap SIZE] [--swappiness N] [--docker-logs 50m:3] [--firewall]
          [--unattended-upgrades] [--portainer-agent-fix]
```
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/harden.sh --ssh-keys-only --swap 2G --swappiness 10 --docker-logs 50m:3 --unattended-upgrades'
```
- **`--ssh-keys-only`** refuses to run unless `/root/.ssh/authorized_keys` (or the sudo user's) already has
  at least one key - the lockout guard. Never disable password auth before key login is confirmed working;
  the script checks this itself, but the rule holds even when scripting around it. Writes
  `/etc/ssh/sshd_config.d/10-vps-clone.conf`, tests it with `sshd -t`, reloads.
- **`--swap`/`--swappiness`**: idempotent swapfile + fstab entry, `vm.swappiness` written to a dedicated
  `/etc/sysctl.d/99-vps-clone.conf` file, never appended to `/etc/sysctl.conf` (an installer on the source
  had appended the same line to that file dozens of times over its life; a dedicated file is idempotent by
  construction and trivial to remove).
- **`--docker-logs`**: merges `log-driver`/`log-opts` into `/etc/docker/daemon.json` (keeps any other keys
  already there), restarts Docker only if the merged file actually changed. Without this, a verbose service
  (a reverse proxy left in DEBUG, for example) can grow a log file into hundreds of MB within weeks.
- **`--unattended-upgrades`**: installs and enables Debian/Ubuntu's unattended security patches. **Does not
  reboot automatically** - a kernel update that needs a reboot to take effect is surfaced (check
  `/var/run/reboot-required`), never applied blind; schedule the reboot test (section 6) yourself.
- **`--portainer-agent-fix`**: only relevant on a Swarm manager running Portainer with agents. Installs
  `/etc/cron.d/vps-clone-portainer-agent`, `@reboot sleep 180 && docker service update --force -d
  <agent service>` - after a reboot, agents can come up unable to see each other ("agent was unable to
  contact any other agent located on a manager node") and this self-heals it without anyone noticing.

## 4. Updating images and the Docker engine safely

1. **Backup first** (section 5) - not optional before any upgrade.
2. Prefer an exact patch version over `latest`/`stable` tags - list what is available before picking:
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'apt-cache madison docker-ce | head -20'
   ```
   Old `.deb`s stay in `download.docker.com`'s pool after they stop being the newest, so pinning an exact
   version like `5:28.3.0-1~debian.12~bookworm` still works long after its release.
3. **Upgrade one service at a time**, not the whole stack in one shot - deploy, wait healthy, check logs,
   only then move to the next. This is what makes it possible to tell which change broke something.
4. **An in-place Docker engine upgrade breaks overlay DNS.** Containers get restarted by `dockerd` itself
   during the upgrade, but without re-registering in the overlay network's DNS - services fail with
   `ENOTFOUND redis`/`ENOTFOUND postgres`, and `dockerd` logs "Inconsistent driver and libnetwork state". A
   plain reboot does not have this problem, only an in-place engine upgrade does. Fix, right after every
   engine upgrade:
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'for s in $(docker service ls -q); do docker service update --force -d "$s"; done'
   ```
   Then prove it, not just assume it - resolve a real name from inside a container, not just `service ls`:
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker exec $(docker ps -q -f name=app_) getent hosts db 2>&1'
   ```
5. **Traefik/Docker API compatibility.** Docker >= 29 rejects the old Docker API version (1.24) that
   Traefik < 2.11.31 speaks - the symptom is Traefik serving its own "TRAEFIK DEFAULT CERT" and 404s, with no
   real certificates issued, and nothing that obviously points at the cause. Either keep Traefik >= 2.11.31,
   or do not upgrade Docker past 28 on that node.

## 5. Backups

```
backup.sh                                       # the dump/tar itself, cron-driven
backup_install.sh [--time 03:00] [--peer root@IP]
```
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'bash /root/vps-clone/scripts/backup_install.sh --time 03:00 --peer root@198.51.100.20'
```
- Config lives at `/etc/vps-clone/backup.env`: `BACKUP_DIR` (default `/root/backups`), `RETENTION_DAYS`
  (default 7), `VOLUMES`/`PATHS` to include, `PEER` for a cross-node copy over SSH. The database engine is
  auto-detected from running container images (`postgres`, `mysql`/`mariadb`/`percona`,
  `mongo`, `redis`/`valkey`).
- `backup_install.sh` generates a dedicated keypair (`/root/.ssh/vps-clone-backup`) and prints a ready-made
  restricted `authorized_keys` line - add it to the peer node's `/root/.ssh/authorized_keys`, never a bare
  key. `from="<this-host-ip>"` in that line is the IP of the node running `backup_install.sh` (the one that
  will connect out), not the peer's own IP - the script already fills it in for you
  (`from="<this-host-ip>",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty`).
- **Cross-node copy is not offsite.** Two nodes in the same account/datacenter both going down (billing
  issue, provider incident, account compromise) loses both copies. Recommend true offsite storage (a
  separate provider/account, or object storage) in the handoff; set it up only if the brief authorized it.
- **Provider-managed backups are a paid add-on on most providers.** Never enable them without the explicit
  "yes" the brief requires for any spend (Iron rule 6, `SKILL.md`) - note them as a recommendation in
  `OPERATIONS.md` if the human declined.
- **A restore that was never tested is not a backup.** Run one, on a scratch database or volume, before
  calling backups done:
  ```bash
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'ls /root/backups/local/*_postgres_*.sql.gz'   # find the exact filename first
  # restore into a THROWAWAY container of the same image (a pg_dumpall into the live server would
  # collide with its roles/databases), prove data arrived, then remove it
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'IMG=$(docker inspect -f "{{.Config.Image}}" $(docker ps -q -f name=postgres_ | head -1)); docker run -d --name vpsclone-restore-test -e POSTGRES_PASSWORD=restoretest "$IMG" >/dev/null; for i in $(seq 1 30); do docker exec vpsclone-restore-test pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done'
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'zcat /root/backups/local/<name>_postgres_<TS>.sql.gz | docker exec -i vpsclone-restore-test psql -U postgres -q -o /dev/null; docker exec vpsclone-restore-test psql -U postgres -Atc "select datname from pg_database where not datistemplate"'
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'docker exec vpsclone-restore-test psql -U postgres -d <app_db> -Atc "select count(*) from information_schema.tables where table_schema = '"'"'public'"'"'"; docker rm -f vpsclone-restore-test'
  ```
  The table count must match the live database (same query against the real container).
  (filenames are `<sanitized-container-name>_<engine>_<UTC-timestamp>.<ext>.gz` - `backup.sh` prints the
  exact name it wrote; `ls` above finds it instead of guessing. Adapt to the engine actually running -
  MySQL/MariaDB/Percona restore uses `mysql -uroot`, Mongo uses `mongorestore --archive`). Record the date
  it was tested in `OPERATIONS.md`.

## 6. Reboot test

Run after hardening and after any Docker engine upgrade, on every target node, one at a time:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'reboot'
# wait, then:
. .vps-clone/env.sh && "$PY" "$S/sshx.py" check tgt1
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service ls; docker exec $(docker ps -q -f name=app_) getent hosts db 2>&1'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/firewall.sh --status'
```
Confirms every service comes back, overlay DNS still resolves, and the firewall re-applied itself - the
whole point of installing it through the systemd drop-in instead of running it once by hand.

## 7. Provider account hygiene

Cannot be automated - say it plainly to the human once, in the final report (Phase 11): enable 2FA on the
new provider account and the DNS account, if not already on. One line, not a blocker.

## 8. Secrets storage rules

- Secrets live in exactly two places: `.vps-clone/` locally (chmod 600, and the workspace's own
  `.gitignore` already excludes it entirely) and root-only files on the target
  (`/root/vps-clone/stacks/*.yml`, chmod 600). Never in chat output, commit messages, tickets, or logs.
- Default (posture `parity + security`): every DB and admin password is newly generated on the target, not
  copied from the source - `stacks.py render`'s `rotate_env` handles this. Identity keys (`keep_env`:
  encryption keys, app secret keys) are the deliberate exception - rotating those breaks decryption of
  existing data, or invalidates a license tied to them.
- Before calling this done, confirm none of the source's old secret values remain outside `keep_env` fields.
  `stacks.py render`'s `report.txt` already lists any leftover rotated value from the source export - treat a
  non-empty list there as a blocker, not a warning.

## 9. What to record in `OPERATIONS.md`

Every divergence from the source, in the Divergences table (`templates/OPERATIONS.md`), one row per item,
with a reason:

| What | Source | Target | Why |
|---|---|---|---|
| DB/admin passwords | shared/old | newly generated | posture = parity + security |
| SSH | password allowed | keys only | posture = parity + security |
| Firewall | (whatever the source had) | `DOCKER-USER` + INPUT rules | posture = parity + security |
| Component versions | old pinned versions | current patch versions | security updates applied |
| Backups | (whatever the source had) | daily, cross-node, restore tested | posture = parity + security |

Also record: where every secret lives (section 8), the firewall/harden/backup commands actually run (with
their flags), the restore-test date, and the reboot-test date. A later session, or a human with no memory of
this one, must be able to pick up maintenance from this file alone.
