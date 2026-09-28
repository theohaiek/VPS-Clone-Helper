---
name: vps-clone
description: Clone one or more VPS servers (the whole topology) into new servers in the user's own provider account, autonomously and without touching the source - readiness check, read-only inventory, provisioning, Docker Swarm / docker compose / systemd redeploy, optional data copy, DNS and TLS, parity proof, hardening and backups. Use when the user wants to clone, copy, duplicate, replicate or migrate a VPS, server or Docker Swarm to another server, provider or account, or says "clone my VPS".
---

# VPS Clone

Clone a running VPS, or a multi-server topology, into new servers the user owns. End to end, autonomous,
source untouched. Built from a real clone of a 2-node Docker Swarm (Traefik, Portainer, Postgres on a
dedicated node, MySQL, Redis, RabbitMQ, n8n queue mode, Chatwoot, Evolution API, MinIO, phpMyAdmin);
written to work with any provider and with compose or plain systemd hosts.

This file is the whole playbook. `references/` holds depth; read a reference when its phase starts.

## Paths and conventions

- `SKILL_DIR` = the folder of this file. Repo clone: `skills/vps-clone`. Plugin: the "Base directory for this
  skill" that Claude Code shows when the skill loads. Only this file, no `scripts/` next to it? Get the full
  toolkit first: `git clone --depth 1 https://github.com/theohaiek/VPS-Clone-Helper` and use its `skills/vps-clone`.
- Workspace = `.vps-clone/` in the directory where Claude runs (override: `VPSCLONE_DIR`). It holds
  secrets and job state, has its own `.gitignore` (`*`), and is never committed, pasted or uploaded.
  ```
  .vps-clone/STATE.md  BRIEF.md  hosts.json  known_hosts  env.sh  keys/  inventory/  export/  render/  parity/  OPERATIONS.md  logs/
  render/: names.json pins.json mapping.json secrets.json portainer_admin.env stacks/ (rendered files + report.txt)
  ```
- `doctor.py` writes `.vps-clone/env.sh`. Shell state does not persist between tool calls, so start EVERY
  command with it. It exports `S` (scripts dir), `PY` (working Python), `VPSCLONE_DIR`, `MSYS_NO_PATHCONV=1`:
  ```bash
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 'docker service ls'
  ```
- Aliases: `src1..srcN` = source servers (registered with `--role source`: sshx refuses state-changing
  commands on them), `tgt1..tgtN` = target servers. Remote workdir on targets: `/root/vps-clone/`.
- `sshx.py` output is byte-exact and nothing is appended to stdout; the exit code is the remote exit code.

## Iron rules

1. **The source is read-only.** Inventory, exports and dumps only. Never restart, update, prune, install or
   edit anything there. Temporary dumps in `/tmp` only in data mode, with `--allow-write`, deleted afterwards.
   Prefer `sshx.py pipe`, which writes nothing on the source.
2. **Same topology.** Same number of servers, same roles, same placement (hostnames, labels, constraints).
   Never merge servers "to save money" unless the brief says so.
3. **Ask once, then work.** Collect every decision and credential in Phase 1. After the readiness gate, do not
   ask again except for blockers: payment beyond the approved cap, 2FA/captcha/login, or a destructive action
   the brief does not cover.
4. **The user's account.** Buy and configure only in the account named in the brief. Before any purchase,
   read the account name or email shown by the API or panel and match it with the brief.
5. **Do it yourself.** Discover tools before asking (API token env vars, provider CLIs, `claude mcp list`,
   in-session MCP tools via ToolSearch, Claude in Chrome). Never hand the user a task a tool can do.
6. **Money needs a yes.** Servers, paid backups, extra IPs or volumes only within the cap written in BRIEF.md.
7. **Evidence before "done".** A phase is done when its check passed, not when its command returned 0.
8. **Write it down.** Update `.vps-clone/STATE.md` after every step: next step, decisions, divergences from
   the source, mistakes. A new session must be able to resume from it alone.
9. **Secrets stay local.** Only in `.vps-clone/` (chmod 600) and in root-only files on the targets. Never in
   chat summaries, commits, tickets or logs. Never print a password; print where it is stored.
10. **Servers are changed sequentially.** One mutating operation at a time. Parallel sub-agents only for
    read-only analysis, and only with the user's explicit permission.
11. **Clean up your own mistakes.** Resources created by accident, temp dumps, test stacks: remove them
    yourself and record it. Necessary security updates are your job too (backup first).

## Phase 0: first run (gate)

First run = `.vps-clone/STATE.md` does not exist. Whatever the user typed, before any tool call and
before anything else, write at most two short lines in the user's language:

- Risks: "I will run root commands on servers, may buy servers in your account (up to the cap you approve)
  and change DNS, without asking at each step. The source stays read-only; mistakes can cost money or break
  the new servers."
- Unless the hook line says `permission_mode=bypassPermissions`: "Reopen in this folder with
  `claude --dangerously-skip-permissions` so I can work without stopping."

Then start Phase 1 in the same turn. A later session resumes from STATE.md, so reopening loses nothing.
Resuming (STATE.md exists): read it, say in one line where the job stands, run its "Next step".

## Phase 1: readiness (doctor, brief, access)

1. Run the doctor (it also creates the workspace and `env.sh`):
   ```bash
   for p in python3 python "py -3"; do $p -c 'import sys; assert sys.version_info >= (3, 8)' 2>/dev/null && { PYB="$p"; break; }; done
   $PYB "<SKILL_DIR>/scripts/doctor.py" --fix
   ```
   No Python 3.8+: install it (winget `Python.Python.3.12` / brew `python` / apt `python3`), then rerun.
2. Copy `templates/STATE.md` and `templates/BRIEF.md` into `.vps-clone/` (keep existing ones).
3. In-session discovery: ToolSearch for provider and DNS tools (`hetzner`, `digitalocean`, `vultr`, `linode`,
   `aws`, `hostinger`, `cloudflare`, `dns`, `route53`, `godaddy`, `namecheap`) and for
   `mcp__claude-in-chrome__tabs_context_mcp`. Record what exists in STATE.md.
4. Intake. Fill BRIEF.md from what you can detect, then ask everything still missing in ONE message
   (AskUserQuestion for choices, one plain request for the free-text items):
   - Source: IP of every server, SSH user, password or key path (they may instead put it in an env var; see
     `references/prerequisites.md`). You will discover the other nodes of a Swarm yourself.
   - Mode: `config-only` (apps empty, no data copied) | `full` (config + data) | `full+cutover` (final data
     sync, then DNS switch, source kept as rollback).
   - Target: provider and account (must be theirs), region, purchase authorized yes/no and monthly cap.
   - Domains: `old -> new` map, or "same domains" (cutover). DNS provider of the new domain.
   - Posture: `strict parity` | `parity + security` (recommended: new DB/admin passwords, firewall, SSH keys
     only, log rotation, backups, patch updates). Identity keys (encryption keys, licenses) are kept.
   - Out of scope apps, if any. ACME e-mail for certificates.
5. Access tests (all read-only):
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" add src1 203.0.113.10 --user root --password '<pw>' --role source
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" check src1
   ```
   The password lands only in `.vps-clone/hosts.json` (600). Alternatives: `--key PATH`, or `--password-env VAR`
   when the user exported `VAR` before starting Claude. Non-root user with passwordless sudo: add `--user u --sudo`.
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 'docker node ls 2>/dev/null; docker info --format "{{.Swarm.LocalNodeState}}" 2>/dev/null'
   ```
   More Swarm nodes than servers in the brief: register them all (ask for missing credentials once).
   Provider: list servers or account info with the chosen method (token/CLI, MCP, or the logged-in browser)
   and confirm the account identity. DNS: list the zone's records. Domain's DNS provider:
   `"$PY" "$S/doctor.py" --domain new.example.org`.
6. Readiness gate: every row of the readiness table is OK (see `references/prerequisites.md`). Mark Phase 1
   done in STATE.md. From here on, work without asking (rule 3).

## Phase 2: inventory (read-only)

```bash
. .vps-clone/env.sh && mkdir -p "$VPSCLONE_DIR"/{inventory,export} && for a in src1 src2; do
  "$PY" "$S/sshx.py" $a --script "$S/remote/inventory.sh" > "$VPSCLONE_DIR/inventory/$a.txt"
  "$PY" "$S/sshx.py" $a --script "$S/remote/export_docker.sh" > "$VPSCLONE_DIR/export/$a.stream"
  "$PY" "$S/stacks.py" unpack "$VPSCLONE_DIR/export/$a.stream" "$VPSCLONE_DIR/export/$a"
done
```

Read every section. Write a topology map into STATE.md: per server - role, provider/type (CLOUD section),
vCPU/RAM/disk, OS, Docker version, services and where they run (placement), volumes and sizes, databases,
exposed ports, cron, sysctl, firewall. From the Swarm manager's export:
`"$PY" "$S/stacks.py" names <export> --write render/names.json` and `pins <export> --write render/pins.json`.
Details: `references/inventory-and-strategy.md`.

## Phase 3: plan

Choose the strategy (`references/inventory-and-strategy.md`):
- **Rebuild + redeploy** (default): containers and config recreated from the export; needed for config-only
  mode, new passwords or hardening.
- **Provider snapshot/image**: same provider, the user owns both accounts/projects, exact copy wanted.
- **Disk copy via rescue system**: exotic/bare hosts across providers, downtime acceptable.
- **Panel-native migration**: cPanel, Plesk, CapRover, Coolify and similar have their own tools.

Then decide and record in STATE.md (each with a done-criterion): target server types (same vCPU/RAM/disk/
arch; retired type -> its successor), same OS major version as the source, region, Docker/engine versions
(exact source version for strict parity; current patch releases for `parity + security`), hostnames, domain
map, `render/mapping.json` (replace / rotate_env / keep_env / set_env / image_override), deploy order, data
plan, DNS plan, hardening plan, cost vs cap. If everything fits the brief, continue without asking.

## Phase 4: provision

```bash
. .vps-clone/env.sh && mkdir -p "$VPSCLONE_DIR/keys" && ssh-keygen -t ed25519 -N '' -C vps-clone -f "$VPSCLONE_DIR/keys/id_ed25519"
```
Create the servers with that public key, same hostnames as the source, OS image of the same major version
(`references/providers.md`: CLI commands per provider, browser protocol). Browser purchases: verify the
account first, fill fields with `form_input` (typing duplicated characters in the real run), never press
Enter inside multi-value fields (it submitted a form and created an unwanted object), read the order summary
before confirming. Record server ids and IPs in STATE.md, then:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" add tgt1 198.51.100.20 --key keys/id_ed25519 --role target --note manager
. .vps-clone/env.sh && "$PY" "$S/sshx.py" check tgt1
```
Rebuilt a server? `sshx.py forget tgt1` before reconnecting (host key pinning).

## Phase 5: bootstrap

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 --put-tree "$S/remote" /root/vps-clone/scripts
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/docker_install.sh --docker 5:28.3.0-1~debian.12~bookworm'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/node_bootstrap.sh --hostname manager01 --sysctl vm.overcommit_memory=1 --swarm-init 198.51.100.20 --network network_swarm_public:overlay-attachable --volume portainer_data'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'bash /root/vps-clone/scripts/node_bootstrap.sh --hostname database01 --swarm-join 198.51.100.20:2377 --token <JOIN_TOKEN_WORKER> --volume postgres_data'
```
Versions, names, sysctl, labels and volumes come from the inventory, not from these examples. Pull every
image by its pinned digest on the node that runs it. Images gone from the registry (`pull access denied`):
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'docker save repo/image:tag' tgt1 'docker load'
```
Keep a copy of such images outside the servers; it may be the only copy left. Details: `references/docker.md`.

## Phase 6: deploy the configuration

```bash
. .vps-clone/env.sh && "$PY" "$S/stacks.py" render --src "$VPSCLONE_DIR/export/src1" --names "$VPSCLONE_DIR/render/names.json" \
  --mapping "$VPSCLONE_DIR/render/mapping.json" --pins "$VPSCLONE_DIR/render/pins.json" \
  --secrets "$VPSCLONE_DIR/render/secrets.json" --out "$VPSCLONE_DIR/render/stacks"
```
`render/stacks/report.txt` must show no leftover old domain and no leftover rotated secret. Upload with
`--put-tree "$VPSCLONE_DIR/render/stacks" /root/vps-clone/stacks`, then `chmod 600` them on the server.

Deploy in dependency order: reverse proxy -> management panel -> databases and queues -> apps -> post-install.
Keep each stack's original deployment method: CLI-deployed stacks with `docker stack deploy -c`,
Portainer-managed stacks through the Portainer API (`remote/portainer.sh init|create|update`), otherwise
Portainer loses control of them. Compose hosts: copy the project dir, `docker compose up -d`. Plain systemd
hosts: `references/plain-hosts.md`. Wait for each layer to be healthy before the next.

## Phase 7: data

- `config-only`: create the empty databases the apps expect, run each app's first-run preparation (e.g.
  Chatwoot `rails db:chatwoot_prepare`, MinIO buckets), leave first-user setup screens for the owner.
  Keep license material that the brief says to keep (e.g. n8n `settings.license.cert`, which only works
  with the same `N8N_ENCRYPTION_KEY`).
- `full`: stream dumps source -> target with `sshx.py pipe` (`pg_dumpall | psql`, `mysqldump
  --single-transaction | mysql`, `tar czf - | tar xzf -` for volumes with the target service stopped).
  Keep identity keys (encryption keys, `SECRET_KEY_BASE`, `APP_KEY`) or encrypted data becomes unreadable.
  Verify row/table counts on both sides.
- `full+cutover`: same, then a final sync in a short write freeze right before the DNS switch.
Details and per-engine commands: `references/data.md`.

## Phase 8: DNS and TLS

Test before switching anything:
`"$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/verify_web.sh --ip 198.51.100.20 app.new.example.org'`.
Create or update only the records you need (never delete unrelated records) through the DNS provider's API,
MCP or panel. Lower TTL to 300 s before a cutover. HTTP-01 certificates are issued only after DNS points to
the target; confirm with `verify_web.sh` (real CA issuer, not "TRAEFIK DEFAULT CERT"). Details:
`references/dns-tls.md`.

## Phase 9: verify parity

```bash
. .vps-clone/env.sh && for a in tgt1 tgt2; do "$PY" "$S/sshx.py" $a --script "$S/remote/export_docker.sh" > "$VPSCLONE_DIR/export/$a.stream" && "$PY" "$S/stacks.py" unpack "$VPSCLONE_DIR/export/$a.stream" "$VPSCLONE_DIR/export/$a"; done
. .vps-clone/env.sh && "$PY" "$S/parity.py" "$VPSCLONE_DIR/export/src1" "$VPSCLONE_DIR/export/tgt1" --mapping "$VPSCLONE_DIR/render/mapping.json" --secrets "$VPSCLONE_DIR/render/secrets.json"
```
Every DIFF is either fixed or written into STATE.md "Divergences" with the reason. Also: nodes and roles,
each service on the right node, all replicas running, name resolution inside the overlay
(`docker exec <app container> getent hosts <db service>`), endpoints with `verify_web.sh`, app smoke tests
(health endpoints, login pages, DB connections), licenses. Details: `references/verification.md`.

## Phase 10: harden and back up (posture `parity + security`)

`remote/firewall.sh --install` (Swarm-published ports bypass ufw/INPUT; filter in `DOCKER-USER`; swarm ports
open only between nodes), `remote/harden.sh --ssh-keys-only --swap 2G --docker-logs 50m:3 --unattended-upgrades`,
patch updates with a backup first, `remote/backup_install.sh` on every node + a first run + a restore test.
Then reboot every target node and re-verify (all services back, overlay DNS, firewall active). After any
in-place Docker engine upgrade run `docker service update --force -d` on every service. Record every
divergence from the source in STATE.md. Details: `references/hardening.md`.

## Phase 11: handoff

1. Write `.vps-clone/OPERATIONS.md` from `templates/OPERATIONS.md`: access, where each secret lives, service
   map, security, backups, day-to-day commands, rebuild-from-zero sequence, known pitfalls, divergences.
2. Delete temporary dumps and tars from the source (`--allow-write`) and the targets.
3. Final report to the user, short, in their language: what works (URLs), what differs from the source and
   why, what is pending with a done-criterion each, where OPERATIONS.md is. No secrets in the report.
4. STATE.md: all phases checked, "Next step" = the first pending item or "none".

## Pitfalls that already happened (details: `references/pitfalls.md`)

| Symptom | Fix |
|---|---|
| Traefik serves "TRAEFIK DEFAULT CERT", 404, no certificates | Docker >= 29 needs Traefik >= 2.11.31 (or keep Docker 28) |
| After a Docker engine upgrade: `ENOTFOUND postgres/redis` | `docker service update --force -d` on every service |
| `pull access denied` for an image the source runs | `sshx.py pipe src 'docker save IMG' tgt 'docker load'`, keep the tar |
| Portainer: `Invalid or missing setup token` / `initialization timeout` | `portainer.sh init` (setup token header, restart after 5 min) |
| Portainer: agent "unable to contact any other agent" | `docker service update --force <portainer agent service>` |
| App rejects a value copied through a helper (license, key) | Nothing may be appended to data; check length or hash |
| Git Bash turns `/tmp/x` into `C:/...` | `MSYS_NO_PATHCONV=1` (already in env.sh) |
| Script fails after `| head` with pipefail | Do not pipe into `head` under `set -o pipefail` |
| MySQL root password in the stack changed but login fails | The env var applies only at first init: `ALTER USER` root@'%' and root@'localhost' |
| DB ports reachable from the internet although ufw is on | Filter in `DOCKER-USER` (`firewall.sh`) |
| Provider form typed wrong / submitted early | `form_input`, never Enter in multi-value fields, delete accidental objects |
| Sysctl line repeated dozens of times | Write `/etc/sysctl.d/*.conf`, never append to `sysctl.conf` |

## Reference map

| Read when | File |
|---|---|
| Phase 1 | `references/prerequisites.md` |
| Phases 1, 4 | `references/providers.md` |
| Phases 2, 3 | `references/inventory-and-strategy.md` |
| Phases 5, 6 (containers) | `references/docker.md` |
| Phases 5, 6 (no containers) | `references/plain-hosts.md` |
| Phase 7 | `references/data.md` |
| Phase 8 | `references/dns-tls.md` |
| Phase 9 | `references/verification.md` |
| Phase 10 | `references/hardening.md` |
| Anything breaks | `references/pitfalls.md` |
| Want a worked example | `references/case-study.md` |
