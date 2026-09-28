# Inventory and Clone Strategy

Read this at Phase 2 (collect) and Phase 3 (decide) of `SKILL.md`. It covers running the two read-only
collection scripts, reading their output into a topology map, and picking a clone strategy from what
you found.

## 1. Collect

Run both scripts on every source server before deciding anything. Both are read-only (`set +e`, stdout
only, nothing written on the remote server) and safe to rerun as many times as you want.

```bash
. .vps-clone/env.sh && mkdir -p "$VPSCLONE_DIR"/{inventory,export}
for a in src1 src2; do
  "$PY" "$S/sshx.py" "$a" --script "$S/remote/inventory.sh"     > "$VPSCLONE_DIR/inventory/$a.txt"
  "$PY" "$S/sshx.py" "$a" --script "$S/remote/export_docker.sh" > "$VPSCLONE_DIR/export/$a.stream"
  "$PY" "$S/stacks.py" unpack "$VPSCLONE_DIR/export/$a.stream" "$VPSCLONE_DIR/export/$a"
done
```

- `inventory.sh` writes one flat text file, sections marked `##### NAME`. Read it directly.
- `export_docker.sh` writes a single stream (`@@@VPSCLONE-FILE <path>@@@` markers); `stacks.py unpack`
  splits it into a tree: `host.txt`, `daemon.json`, `images.tsv`, `image_repodigests.tsv`, `volumes.json`,
  `networks.json`, `containers.json`, `swarm/nodes.json`, `swarm/stacks.txt`, `swarm/services/<name>.json`,
  `swarm/configs/<name>.json`, `swarm/secrets.txt`, `portainer/<...>`, `disk<path>` (compose/stack files
  found on disk), `END.txt`.
- Both outputs **contain secrets in the clear**: compose `environment:` blocks, `.env` files copied
  verbatim, database names. Keep them inside `$VPSCLONE_DIR` only — never paste into a ticket, a chat
  outside this session, or a commit.
- A host with no Docker prints only `ERROR.txt` from `export_docker.sh` ("docker not installed on
  `<host>`") and exits 0. That is the signal to plan that server under `plain-hosts.md`, not `docker.md`.
- Run both again on the **targets** once they exist (Phase 9) — same commands, same format — that is
  exactly what `parity.py` compares.

## 2. Reading `inventory.sh`: section -> implication

Primary sections — read these in full, they drive the plan:

| Section | Tells you | Implication |
|---|---|---|
| `CLOUD` | DMI vendor strings + metadata-endpoint probes (Hetzner, DigitalOcean, Vultr, AWS, GCP, Azure, Oracle) that succeeded | Which provider and which metadata to match a server type against; empty on bare metal / unknown host |
| `HARDWARE` | vCPU count, RAM, swap, disk layout (`lsblk`), mounted filesystem sizes | The target server type: same vCPU/RAM/disk class as the source (`SKILL.md` rule 2); a retired type needs its same-spec successor |
| `SWARM_NODES` (inside `DOCKER`, only on a manager) | Every node in the cluster: hostname, role, labels, engine version | **All of them must be cloned**, not just the manager (lesson 1). Register every node in `hosts.json` and get a credential for each before Phase 3 closes — a Swarm node you never registered is a server you will forget to provision |
| `LISTENING_PORTS` + `FIREWALL` | What is actually bound (`ss -tulpn`) vs. what `ufw`/`iptables`/`nft` claims to block | The real exposure. A DB port bound to `0.0.0.0` with no matching firewall rule is public right now — decide in Phase 3 whether the target keeps that (parity) or gets fixed (`parity + security`, `references/hardening.md`) |
| `SYSCTL_CUSTOM` | `sysctl.conf` + `sysctl.d/*.conf`, deduplicated with `sort \| uniq -c` | A `uniq -c` count > 1 for the same key is the sign of an installer that kept appending the same line (lesson 31, `vm.overcommit_memory=1` seen dozens of times). Do not replicate the duplication on the target: write it once into `/etc/sysctl.d/90-vps-clone.conf` via `node_bootstrap.sh --sysctl` |
| `PORTAINER` (inside `DOCKER`) | Whether a `portainer_data`-like volume exists and its `compose/` subdirectory | If present, some stacks are Portainer-managed — they must be redeployed through `portainer.sh create`/`update`, never `docker stack deploy`, or Portainer loses control of them (`SKILL.md` Phase 6) |
| `DATABASES_NATIVE` + `DATABASES_IN_CONTAINERS` | Active native DB services, and per-container `psql`/`mysql`/`mongosh`/`redis-cli` size probes | Which engines exist and roughly how big each database is — the input to the data-plan time estimate in section 6 |
| `BIG_DIRS` | `du -xsh` of `/var/www /opt /srv /home /root /var/lib/docker/volumes /var/lib/postgresql /var/lib/mysql` | The total data volume to move in `full`/`full+cutover` mode — the other input to the time estimate |

Supporting sections — skim, note anything unusual:

| Section | One-line read |
|---|---|
| `META` | Collection timestamp, hostname, uptime — sanity check you hit the right box |
| `FSTAB` | Extra mounts (NFS, extra disks) that `du`/`lsblk` alone would miss |
| `OS` | Distro + version + kernel: target must match the major version (lesson 9), even if the provider's default image is newer |
| `NETWORK` / `HOSTS_FILE` | Interface names (may rename on the target, e.g. `eth0` -> `ens3`), static entries to carry into `node_bootstrap.sh --hostname` and `/etc/hosts` |
| `SSH` | `sshd -T` effective config + counted `authorized_keys` per account — do not blindly copy host keys (section D of `plain-hosts.md`); do carry the *authorized* keys forward if the brief wants the same operators to have access |
| `USERS` | Interactive accounts and `sudo`/`docker`/`wheel` group membership — the user/group list for `plain-hosts.md` section 2 |
| `PACKAGES` | `apt-mark showmanual` output plus pinned versions of common server packages, and `sources.list.d/` — the exact install list for a rebuild |
| `SERVICES_ENABLED` / `SERVICES_RUNNING` / `SERVICES_FAILED` | What should come up on boot vs. what is actually up vs. what is already broken on the source (do not silently "fix" a source problem by omission — record it) |
| `CUSTOM_UNITS` / `TIMERS` | Non-package systemd units and timers to carry over verbatim |
| `CRON` | `/etc/crontab`, `/etc/cron.d/*`, per-user crontabs — copy jobs, not the files wholesale (paths often need adjusting) |
| `LIMITS` | `limits.conf`/`limits.d` — usually needed only when a DB or JVM process raised `nofile`/`nproc` |
| `WEB_SERVERS` | `nginx -T` / `apache2ctl -S` / Caddy version, resolved server blocks, and Let's Encrypt cert expiry — the vhost list for `plain-hosts.md` section 2 and the domain list for `references/dns-tls.md` |
| `DOCKER` / `DOCKER_CONTAINERS` / `DOCKER_IMAGES` / `DOCKER_VOLUMES` / `DOCKER_NETWORKS` / `COMPOSE_PROJECTS` / `SWARM_STACKS` / `SWARM_SERVICES` / `SWARM_SECRETS_CONFIGS` / `STACK_FILES_ON_DISK` | The Docker side of the topology — cross-reference against `export_docker.sh`'s output for the actual specs (`references/docker.md`) |

## 3. Topology map

Fill this into `.vps-clone/STATE.md` (the table already exists there, under "Topology map") — one row per
**source** server, even the ones you have not decided a target for yet:

| Source alias | Role | Provider / type | vCPU / RAM / disk | OS | Services (placement) | Target alias | Target type | Target IP |
|---|---|---|---|---|---|---|---|---|
| `src1` | manager | Hetzner CX32 (from `CLOUD`+`HARDWARE`) | 4 / 8 GB / 80 GB | Debian 12 | traefik, portainer, n8n_editor, n8n_webhook | `tgt1` | Hetzner CX33 | `198.51.100.20` |
| `src2` | db | Hetzner CX32 | 4 / 8 GB / 160 GB | Debian 12 | postgres, mysql, redis | `tgt2` | Hetzner CX33 | `198.51.100.21` |

A row with an empty "Target" trio is a server you have inventoried but not yet planned — Phase 3 is not
done until every source row has one.

## 4. Strategy decision tree

Work through these questions in order; the first "yes" picks the strategy. `SKILL.md` Phase 3 defaults to
(c) when nothing else applies.

1. **Does the source run behind a panel with its own migration tool** (cPanel, Plesk, CapRover, Coolify —
   see `plain-hosts.md` section "Panels")? -> **(d) Panel-native migration.**
2. **Same provider, and the user owns (or controls) both the source and target accounts/projects, and an
   exact bit-for-bit copy including current data is wanted, with no config changes?** -> **(a) Provider
   snapshot/image.**
3. **Cross-provider or exotic/bare-metal host, a rescue/live boot mode is available on both ends, and
   downtime on the source is acceptable for the copy window?** -> **(b) Disk copy via rescue system.**
4. **Otherwise** — containerized stacks, `config-only` mode, a version/OS bump, or hardening changes are
   wanted, or none of the above conditions hold -> **(c) Rebuild from inventory + redeploy (default).**

### (a) Provider snapshot/image
Create a snapshot/image of the source via the provider's API/CLI/MCP (`references/providers.md`), then
launch the target from it. Fastest path when it applies, but it is still not a finished clone: hostname,
machine-id and SSH host keys are inherited and must be regenerated on the target (see `plain-hosts.md`
section D-equivalent pitfall), and any hardening/version changes the brief wants must be applied
afterward — a snapshot preserves the source exactly, warts included.

### (b) Disk copy via rescue system
Both servers boot into rescue/live mode (Hetzner, OVH, netcup and similar offer this via KVM/iPXE).
**Do not** run `dd`/`rsync` directly between the two servers — that requires trusting the target's SSH key
on the source, which is a mutating change on a server that must stay read-only. Stream through this
machine instead, exactly like `sshx.py`'s own `pipe` command is meant for:

```bash
# block copy, compressed in flight - sshx.py's source guard flags any "dd " as a possible write;
# --allow-write is safe here because this dd only reads (if=/dev/sda), it writes nothing on the source
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe --allow-write src1 \
  'dd if=/dev/sda bs=4M status=progress | zstd -T0 -3 -c' \
  tgt1 'zstd -d | dd of=/dev/sda bs=4M status=progress'

# filesystem copy instead (lets you resize/change filesystem)
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 \
  'tar --numeric-owner --acls --xattrs -cf - --one-file-system \
     --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp \
     --exclude=/mnt --exclude=/media --exclude=/lost+found --exclude=/swapfile \
     --exclude=/var/lib/docker/overlay2 /' \
  tgt1 'tar --numeric-owner --acls --xattrs -xf - -C /mnt/target'
```

After either form: `chroot` into the target disk (or boot it normally and fix in place) and regenerate
everything host-identity related — `/etc/fstab` (new UUIDs via `blkid`), network config (interface name
may change), `/etc/machine-id` (`rm /etc/machine-id && systemd-machine-id-setup`), SSH host keys
(`rm /etc/ssh/ssh_host_* && ssh-keygen -A`), hostname, and `update-grub`/bootloader if the disk layout
changed. This path needs source downtime for the copy window — plan it as a maintenance window, not a
live operation.

### (c) Rebuild from inventory + redeploy (default)
What the rest of `SKILL.md` (Phases 5-7) and `docker.md`/`plain-hosts.md` walk through: packages, users,
selective `/etc`, app directories, and — separately, by mode — data. Zero downtime on the source (it is
never touched beyond reading), and the only path that lets you change OS/engine versions or apply
hardening while cloning. More manual surface area than (a)/(b): anything not captured by `inventory.sh`
or `export_docker.sh` has to be caught by hand.

### (d) Panel-native migration
When the source runs a panel with its own export/import tool, use it instead of reconstructing by hand —
it already knows every file, database and cron job the panel manages. Full command reference and per-panel
verification status: `plain-hosts.md` section "Panels".

## 5. Pros and cons

| Strategy | Downtime on source | Crosses providers | Preserves exact data | Lets you change versions/hardening | Manual surface |
|---|---|---|---|---|---|
| (a) Snapshot/image | None (snapshot is a point-in-time copy) | No | Yes | No (copies the source as-is) | Low |
| (b) Disk copy (rescue) | Yes, for the copy window | Yes | Yes | Only after the copy (chroot fixups) | Medium (fstab/UUID/network/machine-id/host keys) |
| (c) Rebuild + redeploy | None | Yes | Only what you explicitly move (Phase 7) | Yes | Highest (everything not automated must be checked by hand) |
| (d) Panel-native | Depends on the panel's tool (usually low) | Depends on the panel | Yes, for what the panel manages | Rarely (panel restores its own state) | Low for panel-managed content, but anything outside the panel's scope is still manual |

## 6. Time estimates (heuristics, not measured benchmarks)

Use these only for planning a window; before committing to a downtime budget, time a real dump/restore
or transfer of a representative sample and use that number instead.

**Transfer over the network** (disk copy, volume tar, dump files):
```
seconds ≈ data_GB * 8000 / bandwidth_Mbps
```
Line-rate is optimistic — SSH/TLS overhead, small-file overhead (many small files are far slower than one
large stream) and shared/contended links typically deliver 30-60% of nominal bandwidth in practice. A
100 GB transfer over a nominal 1 Gbps link is ~13 minutes at line rate; budget 25-40 minutes for real
conditions, more if the path is many small files rather than one stream.

**Dump / restore, per engine** (bound by disk I/O, not network, once both ends are on decent SSD-backed
cloud storage):
| Engine | Rough rate | Notes |
|---|---|---|
| PostgreSQL (`pg_dump -Fc` / `pg_restore -j`) | ~10-30 GB/hour | Custom format + parallel restore (`-j <cores>`) is materially faster than plain SQL |
| MySQL/MariaDB (`mysqldump` text) | ~5-15 GB/hour | Text-format dump/restore is slow for large schemas; `mydumper`/`myloader` (parallel) is faster if installed, but is not part of this toolkit — install it explicitly if the DB is large enough to matter |
| MongoDB (`mongodump`/`mongorestore` `--archive`) | ~15-30 GB/hour | Roughly comparable to Postgres custom-format |
| Redis (RDB/AOF file copy) | Network/disk bound only | It is a file copy, not a dump — use the transfer formula above, not this table |
| Plain file volumes (`rsync -aAXH`, `tar` over `sshx.py pipe`) | ~20-60 GB/hour over a WAN link with decent bandwidth | Bound by whichever of network or source/target disk I/O is slower |

**Total data-mode window** ≈ sum of (per-database dump/restore time) + (volume/file transfer time) +
fixed overhead (bootstrap, redeploy, verification — budget 30-60 minutes regardless of data size). Record
the estimate and the actual elapsed time in `STATE.md` so the next clone's estimate is better calibrated.

## 7. Writing the plan into STATE.md

`STATE.md` already has a `## Plan` table (`| # | Step | Done when |`). Fill it with one row per concrete
step, each with a done-criterion that is checkable, not a feeling — "deployed" is not a done-criterion,
"`docker service ls` shows N/N replicas for every service" is. Example:

| # | Step | Done when |
|---|---|---|
| 1 | Provision `tgt1`, `tgt2` (Hetzner CX33, Debian 12, `nbg1`) | `sshx.py check tgt1`/`tgt2` succeed, root reachable |
| 2 | Bootstrap engine + swarm init/join | `docker info` shows swarm active on both, same node count as `SWARM_NODES` |
| 3 | Deploy stacks in order: traefik -> portainer -> postgres/mysql/redis/rabbitmq -> apps | every service `N/N` replicas |
| 4 | Data mode: `full` — stream dumps + volumes | row/table counts match source (`parity.py`) |
| 5 | DNS cutover for 9 hostnames | `verify_web.sh` clean on all 9, real CA issuer |
| 6 | Harden + backup install + reboot test | `harden.sh`/`backup.sh` applied, services back after reboot |

Also record, as decisions in the `## Decisions` table (not the plan table): target server types and why,
OS/engine versions chosen, the domain map, the `render/mapping.json` choices, and the total cost vs. the
cap in `BRIEF.md`. If everything fits inside the brief, proceed without asking (`SKILL.md` rule 3); if
something does not (cost over cap, a destructive step the brief never authorized), that is the one thing
worth stopping for.
