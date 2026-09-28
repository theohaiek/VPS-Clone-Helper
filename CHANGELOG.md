# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org).

## 1.0.0 - 2026-09-28

First public release, distilled from a real clone of a two-node Docker Swarm (Traefik, Portainer, Postgres on
a dedicated node, MySQL, Redis, RabbitMQ, n8n in queue mode, Chatwoot, Evolution API, MinIO, phpMyAdmin)
into new servers in another account, with apps empty, new passwords, hardening and backups.

- Playbook skill `vps-clone` with 12 phases, iron rules and resumable job state.
- First-run protocol: two-line risk notice, real permission-mode detection through a UserPromptSubmit hook, one-shot intake.
- `doctor.py`: readiness check for Windows, macOS and Linux (tools, provider CLIs and tokens, MCP servers, DNS provider detection), workspace and `env.sh` setup.
- `sshx.py`: SSH/SFTP helper with source read-only guard, host-key pinning, byte-exact output and a source-to-target streaming pipe.
- `stacks.py`: export unpacking, Portainer stack mapping, digest pinning, rendering with domain maps and consistent secret rotation.
- `parity.py`: spec-level diff between source and target exports.
- Remote scripts: read-only inventory and Docker export, exact-version Docker install, node/Swarm bootstrap, Portainer API client (setup token and init timeout handled), firewall in `DOCKER-USER`, hardening, backups with peer copy, web/TLS verification.
- References for providers, strategies, Docker, plain hosts, data, DNS/TLS, hardening, verification, pitfalls and an anonymized case study.
