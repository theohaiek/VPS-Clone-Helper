# Clone brief

Decisions collected once, in Phase 1. After the readiness gate, work only from this file: anything it does
not cover and that costs money, destroys data or changes the source needs the user's explicit answer.
Credentials do not go here: they live in `hosts.json`, env vars or provider CLI contexts.

Filled on: <UTC date>

## Source (read-only, always)
| Alias | IP | SSH user | Auth (key / password / env var) | Role in topology | Notes |
|---|---|---|---|---|---|
| src1 | | root | | manager | |

Discovered nodes (Swarm `docker node ls`, other hosts referenced by the apps):

## Target
- Provider:
- Account (name or e-mail exactly as the provider shows it):
- Access method: API token env / CLI context / MCP server / logged-in browser (Claude in Chrome)
- Region / datacenter:
- Purchase authorized: yes / no (user creates the servers)
- Monthly cost cap (currency, taxes included?):
- OS: same major version as the source (default) / other:

## Scope
- Mode: config-only (apps empty) / full (config + data) / full+cutover
- Topology: identical to the source (default, never merge servers) / other (explicit):
- Apps out of scope (deploy as-is, no changes):
- Data or apps that must NOT be copied:

## Domains
| Source hostname | Target hostname |
|---|---|
| | |

- DNS provider of the target domain(s):
- DNS access method: API token / MCP / browser / user (only if nothing else exists)
- Cutover of the same domain: yes / no. If yes: accepted downtime window:
- ACME / Let's Encrypt e-mail:

## Posture
- strict parity (same versions, same passwords, no extra security) / parity + security (recommended)
- Passwords: rotate DB/admin passwords (default for parity + security) / keep
- Identity keys to keep (encryption keys, app secrets, licenses):
- Updates allowed: patch releases only (default) / latest stable / none
- Backups: cross-node (free) / provider backups (paid, needs yes) / offsite target:

## Constraints from the user
- Language for reports:
- Anything forbidden (e.g. no parallel agents, no reboots during business hours):
