# VPS Clone Helper

**Give Claude Code everything it needs to clone a VPS on its own.** Point it at a running server (or a whole
Docker Swarm), tell it where the copy should live, and it does the rest: checks your setup, inventories the
source without touching it, buys the servers in *your* account, rebuilds the stack, copies data if you want,
sets DNS and TLS, proves the copy matches, hardens it, sets up backups and leaves you an operations manual.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-orange)

[Leia em português](README.pt-BR.md)

## Quick start

```bash
git clone https://github.com/theohaiek/VPS-Clone-Helper
cd VPS-Clone-Helper
claude --dangerously-skip-permissions "clone my VPS"
```

That is the whole setup. On the first run Claude shows the risks in two lines, checks what your machine has
(Python, SSH, provider CLIs, MCP servers, browser extension), asks every question it needs **once**, and
then works without stopping. Started without the flag? It tells you to reopen with it; nothing is lost,
the job resumes from where it stopped.

## Install as a plugin (use it from any folder)

```text
/plugin marketplace add theohaiek/VPS-Clone-Helper
/plugin install vps-clone-helper@vps-clone-helper
```

Restart Claude Code with `claude --dangerously-skip-permissions`, then run `/vps-clone-helper:vps-clone` or
just say "clone my VPS". The job workspace is created as `.vps-clone/` in the current folder.

## How it works

| Phase | What Claude does | Proof it needs before moving on |
|---|---|---|
| 0 First run | Two-line risk notice, permission mode check | - |
| 1 Readiness | `doctor.py`, one-shot intake (mode, target account, budget cap, domains, posture), access tests | Every readiness row OK |
| 2 Inventory | Read-only inventory and Docker export of every source server | Topology map written |
| 3 Plan | Strategy, server sizes, versions, secrets policy, order, cost | Fits the brief and the cap |
| 4 Provision | Creates the servers in your account (API, CLI, MCP or your logged-in browser) | SSH works with a fresh key |
| 5 Bootstrap | Exact engine versions, Swarm init/join, networks, volumes, pinned images | Images present on every node |
| 6 Deploy | Renders stacks (new domains, rotated passwords, digests) and deploys in order | Every service healthy |
| 7 Data | Config-only prep, or streamed dumps and volumes | Row/table counts match |
| 8 DNS + TLS | Records through your DNS provider, certificates | Real CA certificate on every host |
| 9 Verify | Spec-level diff source vs target, overlay DNS, smoke tests | Every difference fixed or explained |
| 10 Harden | Firewall that Docker cannot bypass, SSH keys only, logs, swap, updates, backups, reboot test | Restore and reboot tested |
| 11 Handoff | `OPERATIONS.md`, cleanup, short report | - |

Everything is tracked in `.vps-clone/STATE.md`, so any new session continues exactly where the last stopped.

## What you need

- [Claude Code](https://code.claude.com) and Python 3.8+ (`doctor.py` installs the one Python package it needs, `paramiko`).
- SSH access to the source server(s): IP, user, password or key.
- An account at the target provider. Best: an API token or CLI login (Hetzner `hcloud`, DigitalOcean `doctl`,
  Vultr, Linode, AWS, GCP, Oracle, OVHcloud, Hostinger, Contabo). Also works with a provider MCP server or
  with your logged-in browser through the Claude in Chrome extension.
- Access to the DNS of the target domain (API token, MCP server or browser).

The doctor tells you exactly what is missing and how to get it.

## Safety model

- **The source is read-only.** Hosts registered as `source` refuse commands that change state; data moves
  through `sshx.py pipe`, which writes nothing on the source.
- **Your money, your cap.** Purchases only in the account and within the monthly cap you give in the brief,
  after checking the account shown by the provider.
- **Secrets stay local.** Credentials, keys, inventories and new passwords live in `.vps-clone/` (git-ignored,
  chmod 600) and in root-only files on the new servers.
- **Same topology.** Two servers stay two servers; roles and placement are preserved.
- **Evidence before done.** Every phase ends with a check, and differences from the source are listed with
  their reason.
- `--dangerously-skip-permissions` lets Claude run commands without asking. Use it in a folder dedicated to
  this job and read the two-line warning it gives you.

## What's inside

```
.claude-plugin/          plugin + marketplace manifests
hooks/                   prompt hook: real permission mode, first-run protocol, job state
CLAUDE.md                first-run protocol when you open Claude in this folder
skills/vps-clone/
  SKILL.md               the playbook (phases, rules, commands)
  references/            depth per phase: providers, Docker/Swarm, data, DNS/TLS, hardening, pitfalls, case study
  templates/             BRIEF.md, STATE.md, OPERATIONS.md
  scripts/
    doctor.py            readiness check, workspace + env setup
    sshx.py              SSH/SFTP helper: source guard, host-key pinning, streaming pipe between servers
    stacks.py            unpack exports, map Portainer stacks, pin digests, render with new domains/secrets
    parity.py            spec-level diff between source and target
    remote/              run on servers: inventory, export, Docker install, bootstrap, Portainer API,
                         firewall, hardening, backups, web/TLS verification
```

## Supported

| | Status |
|---|---|
| Docker Swarm (Portainer, Traefik) | Proven in a real 2-node clone |
| docker compose hosts | Supported by the same export/render flow |
| Plain systemd hosts (nginx, PHP, Node, native databases) | Guided rebuild from inventory |
| Kubernetes / k3s, hosting panels (cPanel, Plesk, CapRover, Coolify) | Guided: uses their native migration tools |
| Providers | Any with SSH; commands documented for 10 providers; purchase via API, CLI, MCP or browser |
| Source OS | Linux (Debian/Ubuntu first-class; others inventoried) |
| Your machine | Windows (Git Bash), macOS, Linux |

## Troubleshooting

- Claude keeps asking for permission: restart with `claude --dangerously-skip-permissions`.
- `paramiko missing`: `python -m pip install --user paramiko` (or run `doctor.py --fix`).
- Anything else: `skills/vps-clone/references/pitfalls.md` lists every failure seen so far with its fix.

## Updating

Repo: `git pull`. Plugin: `/plugin marketplace update vps-clone-helper`. Jobs in progress keep working:
the workspace format is stable within a major version.

## Contributing

Issues and pull requests are welcome, especially provider commands verified on real accounts and new pitfalls
with their fix. Keep scripts idempotent, stdlib-only Python, and never include real IPs, domains or credentials
(CI rejects non-placeholder IPs and e-mails). Run `bash tests/run.sh` before opening a PR.

Opening Claude Code inside this folder starts the clone-and-run protocol (that is the product). To work on the
toolkit itself, say so in your first message.

## License

[MIT](LICENSE)
