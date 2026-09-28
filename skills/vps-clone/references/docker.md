# Rebuilding a Docker Swarm / compose host

Read this during Phase 5 (bootstrap) and Phase 6 (deploy) when the source runs containers. Every
command below is run from the machine driving the clone (not on the servers), starts with
`. .vps-clone/env.sh &&`, and calls `"$PY" "$S/sshx.py"` or `"$PY" "$S/stacks.py"`. `src1`/`src2`
are source aliases, `tgt1`/`tgt2` are target aliases (see SKILL.md for the alias convention).

## 1. Export and unpack

Already done in Phase 2 for every source node:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 --script "$S/remote/export_docker.sh" > "$VPSCLONE_DIR/export/src1.stream"
. .vps-clone/env.sh && "$PY" "$S/stacks.py" unpack "$VPSCLONE_DIR/export/src1.stream" "$VPSCLONE_DIR/export/src1"
```
`export/src1/` now holds `host.txt`, `daemon.json`, `images.tsv`, `image_repodigests.tsv`,
`volumes.json`, `networks.json`, `containers.json`, `swarm/nodes.json`, `swarm/stacks.txt`,
`swarm/services/<name>.json`, `swarm/configs/*.json`, `swarm/secrets.txt` (secret NAMES only: values
cannot be read back from the Docker API; recreate them from the stack files/env or the containers'
`/run/secrets/`), `portainer/<compose-id>/*.yml` (+ `.env`),
`disk/<path>` (CLI-deployed compose files found on disk, + their `.env`). Read `host.txt` first:
it names the Docker/containerd version the target must match for strict parity.

## 2. Identify each stack's compose files and how it was deployed

```bash
. .vps-clone/env.sh && "$PY" "$S/stacks.py" names "$VPSCLONE_DIR/export/src1" --write "$VPSCLONE_DIR/render/names.json"
```
This maps every `portainer/...` and `disk/...` compose file to a stack name, by matching its
top-level `services:` keys against the real `swarm/services/*.json` names. Rows with `UNMATCHED`
need a manual entry in `names.json` (rare: usually a compose file for a stack with zero running
services, or one whose service naming does not follow `<stack>_<service>`).

**Portainer-managed vs. CLI-deployed matters for the whole rest of the clone.** A stack that lives
under `portainer/<id>/` in the export was created through Portainer's API; Portainer keeps its own
copy of that stack's ID and file content, and every future change to it must also go through the
API (`remote/portainer.sh update`) or Portainer's record goes stale — the UI shows the old file,
"pull and redeploy" reapplies the wrong content, and the two sources of truth disagree from then
on. A stack whose only source is `disk/<path>` (nothing under `portainer/`) was deployed by plain
`docker stack deploy -c file.yml name` before or outside Portainer, typically the reverse proxy
and Portainer's own stack (Portainer cannot manage the stack that runs itself). Keep that split on
the target: never `docker stack deploy` something Portainer will later "manage", never
`portainer.sh create/update` something that was always CLI-only.

**Recognizing a popular installer's layout.** Several widely-used one-shot Swarm installer scripts
(the kind pasted from a forum or gist) leave a recognizable signature: overlay network named
`network_swarm_public` (or `network_public`), a volume `volume_swarm_certificates` holding
Traefik's `acme.json`, a Traefik ACME resolver literally named `letsencryptresolver`, Portainer
reachable at a `painel.<domain>` / `portainer.<domain>` subdomain, and Traefik + Portainer
themselves deployed by `docker stack deploy` from a script in `/root` while every application
stack after that goes through Portainer's UI/API. If you see this pattern in the export, it is not
a hand-built topology — treat Traefik and Portainer as CLI-deployed (matches the pattern above)
and every other discovered stack as Portainer-managed, and reuse the same network/volume/resolver
names on the target instead of inventing new ones (less to remap, fewer surprises for the owner).

## 3. Pin every image by digest

```bash
. .vps-clone/env.sh && "$PY" "$S/stacks.py" pins "$VPSCLONE_DIR/export/src1" --write "$VPSCLONE_DIR/render/pins.json"
```
Tags move (`latest`, `sts`, a distro's rolling tag); the digest the source is actually running does
not. `pins.json` maps `repo:tag -> repo:tag@sha256:...`, preferring the live Swarm task spec over
`image_repodigests.tsv` when the two disagree (the task spec is what is really running). `render`
(next section) applies it to every unpinned `image:` line automatically.

## 4. Render the stacks

Write `render/mapping.json` in Phase 3 (planning), then:
```bash
. .vps-clone/env.sh && "$PY" "$S/stacks.py" render --src "$VPSCLONE_DIR/export/src1" \
  --names "$VPSCLONE_DIR/render/names.json" --mapping "$VPSCLONE_DIR/render/mapping.json" \
  --pins "$VPSCLONE_DIR/render/pins.json" --secrets "$VPSCLONE_DIR/render/secrets.json" \
  --out "$VPSCLONE_DIR/render/stacks"
```
Example `mapping.json` for a "config + security posture" clone (new DB/queue passwords, one
identity key kept, an old domain replaced, one loud DEBUG log line silenced, one image bumped to a
patched build already resolved to its new digest):
```json
{
  "replace": { "old.example.com": "new.example.org" },
  "rotate_env": ["POSTGRES_PASSWORD", "MYSQL_ROOT_PASSWORD", "RABBITMQ_DEFAULT_PASS"],
  "keep_env": ["N8N_ENCRYPTION_KEY"],
  "set_env": { "N8N_METRICS": "false" },
  "image_override": {
    "traefik:v2.11.3": "traefik:v2.11.57@sha256:59b207b94324288b2ed6ec57985496848e1f838b0904fa020c82eec45ace5c53"
  },
  "drop_lines_matching": ["--log.filePath=", "--accesslog.filepath="]
}
```
Read `render/stacks/report.txt` before uploading anything: it lists every rendered file, every
`replace` key or rotated value still present somewhere (both must be empty — a leftover means a
config file `render` didn't see, e.g. a `.env` outside the export), unpinned images, and every
hostname the rendered stacks route (cross-check against the domain map from Phase 1). Exit code 1
means leftovers were found; do not deploy until it is 0.

Then upload and lock down permissions:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 --put-tree "$VPSCLONE_DIR/render/stacks" /root/vps-clone/stacks
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'chmod 600 /root/vps-clone/stacks/*.yml'
```

## 5. Node roles and placement

Before touching containers, the *nodes themselves* must match the source's shape. Read each
service's placement straight from the already-unpacked export — no need to hit the source again
for this:
```bash
grep -A3 '"Constraints"' "$VPSCLONE_DIR/export/src1/swarm/services/"*.json
```
A constraint `node.hostname == database01` means: the target node meant to run that service must
also be named `database01` — `node_bootstrap.sh --hostname` sets that at bootstrap time (Phase 5),
so as long as you keep the same hostname assignment as the source, this constraint needs no extra
work. A constraint `node.role == manager` is automatically satisfied by whichever node ran
`--swarm-init`. A constraint on a custom label, e.g. `node.labels.role == database`, needs that
label applied explicitly: **`node_bootstrap.sh --label KEY=VALUE` only labels the node it runs
on, and only while that node is currently a swarm manager** (`docker node update --label-add`
needs a manager to run it, and the script targets its own node ID). To label a worker/non-manager
node, run the label command from the manager after the join, targeting the worker by name:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker node update --label-add role=database database01'
```

## 6. Bootstrap order

1. Install the pinned Docker/containerd version on every target node (source's `host.txt`, or the
   patched version chosen in Phase 3 for a `parity + security` posture):
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/docker_install.sh --docker 5:28.3.0-1~debian.12~bookworm --containerd 1.7.27-1~debian.12~bookworm'
   ```
   Use the exact apt version string, not a bare `MAJOR.MINOR` — old `.deb`s stay in the
   `download.docker.com` pool after a newer release ships, so pinning an older, already-proven
   version still works. List what the repo actually has after the first run adds it:
   `"$PY" "$S/sshx.py" tgt1 'apt-cache madison docker-ce'`.
2. Init the swarm on the manager, creating its networks and volumes in the same call:
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/node_bootstrap.sh --hostname manager01 --sysctl vm.overcommit_memory=1 --swarm-init 198.51.100.20 --network network_swarm_public:overlay-attachable --volume volume_swarm_certificates --volume portainer_data'
   ```
   Captures `JOIN_TOKEN_WORKER=...` (and `JOIN_TOKEN_MANAGER=...`) from stdout. `--swarm-init`
   always takes the advertise IP explicitly — cloud hosts are usually multi-homed and Docker's own
   interface auto-pick is often wrong.
3. Install Docker on the other target nodes, then join them:
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'bash /root/vps-clone/scripts/docker_install.sh --docker 5:28.3.0-1~debian.12~bookworm'
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'bash /root/vps-clone/scripts/node_bootstrap.sh --hostname database01 --swarm-join 198.51.100.20:2377 --token <JOIN_TOKEN_WORKER> --volume postgres_data'
   ```
4. Apply any remaining node labels from the manager (section 5), then confirm the shape:
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker node ls'
   ```
   Same node count and roles as `export/src1/swarm/nodes.json` — if not, stop (iron rule 2).

## 7. Images

Pull every pinned digest on the node(s) that will run it, before deploying:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker pull traefik:v2.11.57@sha256:59b207b94324288b2ed6ec57985496848e1f838b0904fa020c82eec45ace5c53'
```
If a `docker pull` on the target fails with `pull access denied` / `manifest unknown` for an image
the source is still running (removed from its registry, private base image, a maintainer that
stopped publishing), copy the exact image straight from the source through this machine, without
touching the source's disk:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'docker save repo/image:tag@sha256:...' tgt1 'docker load'
```
Then also keep an offline copy of that image (`docker save -o image.tar` locally, or upload it to
a registry you control) — if it is gone from every public registry, this pull from the source may
be the only copy left anywhere.

## 8. Deploy order

Always: reverse proxy -> management panel -> databases and queues -> applications -> post-install
tasks. Wait for a layer to be healthy before starting the next one; a database service still
initializing will make every dependent app crash-loop and confuse the read of what actually
failed. A simple wait, since none of these scripts include a "wait" subcommand:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'until docker service ps postgres_postgres --filter desired-state=running --format "{{.CurrentState}}" 2>/dev/null | grep -q Running; do sleep 3; done; echo ready'
```

**Proxy and panel (CLI-deployed):**
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'cd /root/vps-clone/stacks && docker stack deploy -c traefik.yml traefik --detach=true'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'cd /root/vps-clone/stacks && docker stack deploy -c portainer.yml portainer --detach=true'
```

**Databases, queues, everything else Portainer-managed:** initialize the admin account once (this
call already handles the setup-token dance and the 5-minute init window on its own, see section
9), then create every stack:
```bash
# once, in Phase 3: generate the panel admin password into the workspace (never into chat or STATE.md)
. .vps-clone/env.sh && [ -f "$VPSCLONE_DIR/render/portainer_admin.env" ] || { mkdir -p "$VPSCLONE_DIR/render"; printf "PORTAINER_PASS='%s'\n" "$("$PY" -c 'import secrets;print(secrets.token_urlsafe(24))')" > "$VPSCLONE_DIR/render/portainer_admin.env"; chmod 600 "$VPSCLONE_DIR/render/portainer_admin.env"; }
# every Portainer call: read it from the workspace and send it as an env prefix
. .vps-clone/env.sh && . "$VPSCLONE_DIR/render/portainer_admin.env" && "$PY" "$S/sshx.py" tgt1 "PORTAINER_PASS='$PORTAINER_PASS' bash /root/vps-clone/scripts/portainer.sh init"
. .vps-clone/env.sh && . "$VPSCLONE_DIR/render/portainer_admin.env" && "$PY" "$S/sshx.py" tgt1 "PORTAINER_PASS='$PORTAINER_PASS' bash /root/vps-clone/scripts/portainer.sh create postgres /root/vps-clone/stacks/postgres.yml"
```
Repeat `create` for every infra stack, wait for each, then for every app stack. The admin password
lives only in `.vps-clone/render/portainer_admin.env` (600); OPERATIONS.md points there.

**Post-install tasks** (identity/data-dependent, so they belong to Phase 7 — see `data.md`): first
force-update any service whose behavior depends on a database that just got created or restored
(e.g. a license or config table it reads once at boot), then app-specific first-run steps.

**docker compose hosts** (no Swarm): the compose file AND its `.env` go through `stacks.py render`
like any stack (new domains, rotated passwords, pinned images). `names` names a project
`disk/opt/app/docker-compose.yml` after its directory (`app`), and `render` writes `app.yml` plus
`app.env` (from the project's `.env`). Never copy the raw export to the target: it carries the
source's real secrets. Recreate the project dir with the rendered files, then copy any other assets
the compose file references (Dockerfiles, config files, bind-mounted dirs) from the source:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'mkdir -p /opt/app && chmod 700 /opt/app'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 --put "$VPSCLONE_DIR/render/stacks/app.yml" /opt/app/docker-compose.yml
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 --put "$VPSCLONE_DIR/render/stacks/app.env" /opt/app/.env
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'tar czf - -C /opt/app --exclude=docker-compose.yml --exclude=.env --exclude=./data .' tgt1 'tar xzf - -C /opt/app'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'cd /opt/app && chmod 600 .env && docker compose pull && docker compose up -d'
```
The `tar` of assets can still contain secrets in other config files: grep the rendered target dir for
the old domain and old secrets (`report.txt` lists what was rotated) before starting the project.
Any bind mount outside a named volume (`- /opt/app/data:/data` rather than `- data:/data`) needs
its own data copy — treat it exactly like a volume in `data.md` section 3 (stop the writer, stream
the directory with `tar` through `sshx.py pipe`, verify size).

**k3s / Kubernetes (pointer only):** this package is written for Swarm and compose; if the source
runs k3s or another Kubernetes distribution, prefer the platform's own backup/restore path over a
manual rebuild — [Velero](https://velero.io) for a full cluster (workloads, PVs, and optionally
etcd) or, for a k3s cluster with the embedded etcd datastore, `k3s etcd-snapshot save` on the
source-equivalent step and `k3s etcd-snapshot restore` on a freshly bootstrapped target node. Both
are out of scope for the commands in this file; treat that phase as its own research task before
proceeding, and record the decision in STATE.md.

## 9. Portainer specifics

`remote/portainer.sh` already absorbs the operational pitfalls, so the commands above are enough
in normal operation — this section is what each one is doing, for when something does not go as
expected:
- `init` re-reads the container's own log for `setup_token=...` on every attempt (recent Portainer
  requires that header, `X-Setup-Token`, to create the first admin user) and, if the 5-minute
  admin-init window has expired (`administrator initialization timeout`), force-updates the
  Portainer service to get a fresh window and retries — automatically, no separate command needed.
- Every JSON request body (admin password, stack secrets) is written to a root-only temp directory
  (`/tmp/vps-clone-api`, 700, files 600, deleted after each call) and mounted read-only into the
  throwaway `curl` container, which runs with `--user 0:0`. The curl image's default non-root user
  cannot read a 700 directory (that broke the original run); a world-readable one would leak secrets.
- The Portainer *agent* (used for multi-node visibility) can lose contact with the manager after a
  reboot or a Docker restart and form a split cluster ("agent was unable to contact any other agent
  located on a manager node"). This package's fix is a boot-time cron installed by `harden.sh
  --portainer-agent-fix`; it is a hardening-phase concern, not something to chase during the
  initial deploy — see `references/hardening.md`.
- `update NAME FILE [--prune] [--pull]` is the *only* way to change a Portainer-managed stack after
  `create`. `--prune` removes services no longer in `FILE`; `--pull` forces a fresh image pull
  first. Running `docker stack deploy` on a Portainer-managed stack instead makes Portainer's own
  record of it stale (section 2) — do not do it, even to "fix something quickly".

## 10. Traefik

Traefik is normally the CLI-deployed stack from section 8. Points specific to rebuilding it:
- **ACME storage** lives on a volume (commonly `volume_swarm_certificates`, see the installer
  pattern in section 2) so certificates survive a container restart; create that volume before the
  first deploy (`node_bootstrap.sh --volume volume_swarm_certificates`) so Traefik does not start
  with an empty, ephemeral store.
- **HTTP-01 challenge** needs the domain's DNS already pointing at the target before Traefik will
  get a real certificate — see `references/dns-tls.md` for the full sequence; verify with
  `remote/verify_web.sh` rather than trusting `docker service logs`.
- **Logs**: keep the ACME/access log level at `INFO` on stdout, not `DEBUG` to a file inside the
  container — a `DEBUG` file log with no rotation is a real way to fill the disk over a few weeks.
  If the rendered stack still sets `--log.level=DEBUG` or a `--log.filePath=`/`--accesslog.filepath=`
  flag, use `mapping.json`'s `set_env` (for the level) and `drop_lines_matching` (for the file
  path flags) as in the section 4 example, and rely on Docker's own log rotation
  (`daemon.json`, set up in `references/hardening.md`) instead of an in-container file.
- **Docker >= 29 compatibility**: Docker 29 raised its minimum supported API version, and a Traefik
  build older than 2.11.31 talks a fixed, lower API version — it silently stops discovering any
  container and serves `TRAEFIK DEFAULT CERT` (a self-signed cert) or 404 for everything. If the
  chosen Docker version on the target is 29+, the Traefik image in the rendered stack must be
  2.11.31+ (patch it with `image_override` in `mapping.json`); otherwise, pin Docker to a 28.x
  release for strict parity. Confirm afterwards with `remote/verify_web.sh` — a real CA issuer in
  its output, not the Traefik default cert.

## 11. Docker engine upgrade (already installed, changing version)

`docker_install.sh` handles this idempotently — same command whether it is a first install or an
upgrade:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/docker_install.sh --docker 5:29.8.1-1~debian.12~bookworm --containerd 2.3.5-1~debian.12~bookworm'
```
If the node is already at that exact version it is a no-op. If it is a Swarm manager running
services, the script upgrades in place and then prints a REQUIRED FOLLOW-UP block on its own,
because **an in-place engine upgrade restarts every container without re-registering it on the
overlay network** — services report `running` in `docker service ls` while actually failing with
`ENOTFOUND <other-service>`, and `dockerd`'s own log shows "Inconsistent driver and libnetwork
state". A plain host reboot does not have this problem, only an in-place package upgrade does. Run
the follow-up immediately after any such upgrade:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'for s in $(docker service ls -q); do docker service update --force -d "$s"; done'
```
Then prove name resolution actually works from inside a real running task — `docker service ls`
alone is not evidence (iron rule 7):
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker exec "$(docker ps -q --filter label=com.docker.swarm.service.name=n8n_editor_n8n_editor | head -1)" getent hosts postgres'
```
Expect one line, `<internal-ip>  postgres`. No output or `getent: postgres: Name or service not
known` means the overlay network entry is still stale on that container; force-update its service
again and re-test before moving on.
