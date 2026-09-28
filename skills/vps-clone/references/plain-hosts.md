# Plain (Non-Docker) Hosts

Read this at Phases 5-6 for any source server where `export_docker.sh` printed only `ERROR.txt` ("docker
not installed"), or where the brief wants a panel-managed host cloned. It covers rebuilding a host from
`inventory.sh`'s output: packages, users, a *selective* `/etc` copy, application directories per runtime,
native databases, certificates, mail, cron, and verification — plus a short pointer for k3s and a table
of panels that have their own migration tool. Containerized hosts: `references/docker.md`.

All transfer commands below use `sshx.py pipe` (source stdout streamed straight into target stdin,
through this machine) instead of a direct `rsync`/`ssh` between the two servers — trusting the target's
key on the source would be a mutating change on a server that must stay read-only.

## 1. Packages

Read `PACKAGES` in the source's inventory file: `apt-mark showmanual` output, pinned versions of common
server packages, and `sources.list.d/` listing.

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 'apt-mark showmanual' > "$VPSCLONE_DIR/inventory/src1-pkgs.txt"
```

- Carry over any third-party repo listed under `sources.list.d/` on the source **before** installing —
  otherwise `apt install` on the target resolves those package names from Debian/Ubuntu's default repos
  and may install a different major version.
- Install the same major version as the source shows in `PACKAGES` (exact pin syntax:
  `apt-get install pkg=1.2.3-1`). Match `apt-cache madison pkg` on the target against what the source has;
  an exact patch match is not required, an exact major-version match is.
- `apt install $(cat src1-pkgs.txt)` on the target reproduces the manually-installed set; packages pulled
  in only as dependencies do not need listing — `apt` resolves them.

## 2. Users, groups, sudoers

Read `USERS` (interactive accounts + `sudo`/`docker`/`wheel` membership) and `SSH` (authorized keys per
account) in the inventory.

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 'getent group sudo docker; cat /etc/sudoers.d/* 2>/dev/null'
```

Recreate each interactive account (`useradd -m -s <shell> <user>`), add it to the same groups, and copy
its `authorized_keys` (not its password hash — issue a fresh credential, per `SKILL.md` rule 9). Copy
`/etc/sudoers.d/*` files individually after reading each one; never copy `/etc/sudoers` itself wholesale.

## 3. Selective `/etc` copy

**Never copy `/etc` wholesale.** It mixes host identity (must differ on the target) with application
config (must carry over). Copy an explicit include list; treat everything else in `/etc` as either
package-installed (comes back with `apt install`, section 1) or host-specific (must not be copied).

Explicit **exclude** (host identity — regenerate or let install-time tooling set these on the target):
`fstab`, network config (`network/interfaces`, `netplan/*.yaml`, `systemd/network/*`), `machine-id`,
`ssh/ssh_host_*`, `hostname`, `hosts` (merge by hand, do not overwrite), `cloud/` (cloud-init state).

Explicit **include** — build the list from what the inventory actually shows under `WEB_SERVERS`,
`CUSTOM_UNITS`, `CRON`, `SYSCTL_CUSTOM`, `LIMITS`:

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 \
  'tar cf - --ignore-failed-read -C / \
     etc/nginx/sites-available etc/nginx/sites-enabled etc/nginx/conf.d \
     etc/apache2/sites-available etc/apache2/sites-enabled \
     etc/caddy \
     etc/php/*/fpm/pool.d \
     $(ls /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null | sed "s#^/##") \
     etc/cron.d etc/crontab \
     etc/logrotate.d \
     etc/sysctl.d \
     etc/security/limits.d \
     etc/environment' \
  tgt1 'tar xf - -C /'
```

Trim the list to what that source actually has — an empty glob left in the `tar` argument list is harmless
(`--ignore-failed-read`), but do not invent paths the inventory did not show. After extraction:
`nginx -t` / `apache2ctl configtest` / `caddy validate`, then `systemctl daemon-reload` if any unit files
were copied.

**Per-user crontabs are not under `/etc`** (Debian: `/var/spool/cron/crontabs/<user>`) — read them from
the `CRON` section of the inventory and recreate with `crontab -u <user> -` piping the saved content, one
user at a time, rather than copying the spool directory (its format/permissions are fragile to copy raw).

## 4. Application directories

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 \
  'tar cf - --exclude=node_modules --exclude=vendor --exclude=venv --exclude=.venv \
     --exclude=__pycache__ --exclude=.pytest_cache --exclude=.npm --exclude=.cache \
     --exclude=*/log/*.log -C / var/www opt srv home' \
  tgt1 'tar xf - -C /'
```

Excluded on purpose: dependency directories (`node_modules`, `vendor`, `venv`/`.venv`) are rebuilt from
their manifest in sections 5-6 below — copying them risks platform-specific native binaries (a `venv` or
`node_modules` built on a different kernel/libc/arch silently breaks); caches and logs are not state worth
moving. `BIG_DIRS` in the inventory told you roughly how large these trees are — cross-check against what
actually transfers.

## 5. Runtime-specific rebuild

**Node.js**
- `.nvmrc` in the project (or the version in inventory's `PACKAGES`) -> on the target:
  `nvm install $(cat .nvmrc) && nvm use $(cat .nvmrc)` (same nvm the source used, not a system Node, if
  the source used nvm).
- Dependencies: `npm ci` (uses `package-lock.json`, reproducible) inside each copied app directory — never
  copy `node_modules`.
- Process manager: on the source, `pm2 save` writes `~/.pm2/dump.pm2`. Copy just that file:
  ```bash
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'tar cf - -C /root .pm2/dump.pm2' tgt1 'tar xf - -C /root'
  ```
  then on the target, with `pm2` installed and dependencies already rebuilt: `pm2 resurrect`.

**Python**
- A venv is not portable — its shebangs and some compiled extensions are tied to the exact interpreter
  path and arch. Rebuild it: `python3 -m venv venv && venv/bin/pip install -r requirements.txt`. If the
  source has no `requirements.txt`, generate one from the live venv before excluding it:
  `sshx.py src1 '/opt/app/venv/bin/pip freeze' > requirements.txt` (use the source's actual venv path —
  never leave a bare `<placeholder>` in the command: `<`/`>` are shell redirection characters, so an
  unfilled one silently redirects instead of failing loudly), then upload it with
  `sshx.py tgt1 --put requirements.txt requirements.txt`.

**PHP**
- Copy `composer.json`/`composer.lock`, run `composer install --no-dev --optimize-autoloader` on the
  target — never copy `vendor/`, for the same native-extension reason as `node_modules`.

## 6. Native databases

Same engines, same dump/restore commands as `references/data.md` — the only difference on a plain host is
that native installs usually listen on the default Unix socket (no `-h`/`-p` needed), not a container
network. Stream dump straight into restore, nothing touches disk on either end:

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'pg_dumpall' tgt1 'psql'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 \
  'mysqldump --single-transaction --routines --triggers --events --all-databases' \
  tgt1 'mysql'
```

Verify size sanity on both ends before trusting a dump/restore that returned exit 0 (`SKILL.md` rule 7,
lesson 20 — a `pg_dump`/`mysqldump` invoked with a bad flag can produce an empty file and still exit 0):
compare `pg_dumpall`'s output size, or row counts per table, against the source.

## 7. Certificates

Two options, pick per domain based on whether re-issuing is safe right now:

- **Re-issue on the target with certbot**, after DNS already points there (`references/dns-tls.md`,
  `verify_web.sh`). Cleanest — the target gets its own renewal config with correct paths.
- **Copy `/etc/letsencrypt` whole**, when DNS is not ready yet or you are close to Let's Encrypt's rate
  limit (50 certs/registered-domain/week) and do not want to consume it again. The `live/` directory is
  made of symlinks into `archive/` — `cp -r` breaks that; `tar` preserves it:
  ```bash
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'tar cf - -C /etc letsencrypt' tgt1 'tar xf - -C /etc'
  ```
  Confirm the renewal trigger moved too — the inventory's `CUSTOM_UNITS`/`TIMERS` sections show whether
  the source renews via a systemd timer (`certbot.timer`, usually package-installed, already present after
  `apt install certbot`) or a cron entry (already covered by section 3's cron include).
- Either way, reload the web server after so it picks up the certificate.

## 8. Mail servers (warning)

A new IP starts with **zero sending reputation** — do not point a mail server at the new IP and start
relaying production mail immediately.
- Ask the provider for a **PTR/rDNS record** matching the mail hostname before sending anything.
- Update **SPF** (and DKIM/DMARC if used) TXT records to include the new IP before cutover — mail sent
  from an IP not listed in SPF gets flagged or rejected by receiving servers.
- Consider a smart-relay (SendGrid/SES/Postmark) during the transition instead of sending directly from
  the new IP, or warm it up gradually — this is a deliverability risk, not a technical clone step, and the
  brief should say explicitly whether it is in scope.

## 9. Verification by service

| Service | Verify |
|---|---|
| nginx / apache2 / caddy | Config test (`nginx -t`, `apache2ctl configtest`, `caddy validate`), then `curl -I --resolve host:443:<target-ip> https://host/` per vhost |
| php-fpm | `systemctl is-active php*-fpm`, then a PHP page through the web server |
| Custom systemd units | `systemctl status <unit>` shows `enabled` + `active (running)` |
| Cron / timers | `systemctl list-timers` (for timers), or trigger a job manually once and check its log output |
| PostgreSQL / MySQL / MongoDB / Redis (native) | Connect over the local socket, compare row/table counts (Postgres/MySQL) or key count (Redis/Mongo) against the source figures in `DATABASES_NATIVE` |
| Node (pm2) | `pm2 list` shows the same process names, status `online` |
| Mail (Postfix/Exim/Dovecot) | `systemctl status`, send one test message end-to-end, check the mail log; do not consider this "verified" without also confirming PTR/SPF from section 8 |

## 10. k3s (short)

k3s embeds its own datastore (etcd for multi-server, SQLite for single-node). For same-cluster
disaster-recovery style moves, a snapshot/restore of that datastore is enough:
```bash
k3s etcd-snapshot save
k3s server --cluster-reset --cluster-reset-restore-path="<snapshot-path>"   # on the restored control-plane
```
For moving workloads to a genuinely different cluster (cross-provider, or k3s -> k3s on new nodes),
[Velero](https://velero.io) is the general tool: it backs up Kubernetes objects plus, with a
storage-provider plugin, persistent-volume data, to an object-storage bucket, and restores them into the
target cluster (`velero backup create` on the source cluster, `velero restore create --from-backup` on
the target). Treat this section as a pointer, not a full runbook — a k3s clone is still uncommon enough in
this toolkit's real-world use that the exact snapshot/Velero flags deserve a dry run before trusting them
on a production cluster.

## 11. Panels

Detect a panel from `PACKAGES`/`SERVICES_ENABLED` in the inventory (its daemon/service name) before
deciding to rebuild by hand — when a panel is present, use its own migration tool; it already knows every
file, database and cron job it manages.

| Panel | Native migration tool | Notes |
|---|---|---|
| cPanel | `pkgacct` (source) -> `restorepkg` (target) | Full account package: files, databases, email, DNS zone, cron. The most complete native tool on this list |
| Plesk | Plesk Migrator extension | Migrates one or many subscriptions between Plesk servers, or from cPanel/other panels into Plesk |
| CapRover | `caprover serversetup`, detects a backup tarball placed in the working directory and offers to restore from it (exact flag/prompt wording `[unverified]`) | Restores the whole instance: apps, certs, Nginx config |
| Coolify | Built-in Backup & Restore (local or S3) | Instance-level, documented in Coolify's own docs |
| CyberPanel | [unverified] no confirmed first-class whole-instance export/import | Treat as a rebuild-from-inventory target (sections 1-9) until confirmed otherwise |
| aaPanel | [unverified] no confirmed first-class whole-instance export/import | Same — rebuild from inventory |
| Dokploy | [unverified] no confirmed first-class whole-instance export/import | Same — rebuild from inventory; Dokploy manages Docker under the hood, so `references/docker.md` may cover more of it than this file does |

A panel's native tool still leaves the same host-identity items from section 3's exclude list (SSH host
keys, machine-id, network config) for you to handle separately — a panel restores its own domain, not the
OS underneath it.
