# Case study: a real clone, anonymized

This is the clone this package was built from — a worked example, not a template to copy literally.
Company names, domains, IPs, emails, and account identifiers below are all fictional placeholders;
the topology, phases, mistakes, and rules are real.

## The ask

"Company A" ran a small production stack for internal automation and a couple of client-facing
tools. Its owner also controlled "Company B", a separate, newer business, and wanted an independent
copy of the same infrastructure running under Company B's own hosting account — same shape, same
software, but starting empty. Paraphrased from the owner's own instructions at the start:

> Clone the two-server setup 1:1 into Company B's own account. I don't want Company A's data —
> workflows, credentials, messages, none of it — just the configuration, so it starts clean. The
> automation tool (n8n) needs to come up immediately with a working paid license at Company B's own
> domain. Buy the hosting with my card and don't wait for my approval to do it — just get it done.

Company A's infrastructure was explicitly read-only throughout: nothing about the clone was allowed
to touch or risk the source.

## Topology

Two nodes, same shape on both sides, connected as a single Docker Swarm cluster:

| Node | Role | Services running |
|---|---|---|
| `manager` | Swarm manager, everything except the primary database | Reverse proxy + TLS (Traefik v2), Swarm/stack management UI + its agent (Portainer, 2 services), an in-memory cache (Redis), a message broker (RabbitMQ), a relational database for one app (MySQL-compatible, Percona), a DB admin UI (phpMyAdmin), a workflow-automation tool in queue mode — editor, 2 webhook replicas, and a worker as separate services (n8n), a support-inbox app (Chatwoot: admin + background-job service, 2 services), a messaging-channel bridge (Evolution API), and object storage (MinIO). 14 services total. |
| `db` | Swarm worker, pinned by node-hostname constraint | One service: the primary relational database (PostgreSQL), used by the workflow-automation tool and the support-inbox app. |

Total: 15 services across 2 nodes, matching the source topology exactly except for domains.

## Timeline

**Phase 1 — Inventory (source, read-only).** Walked both source nodes: OS, kernel, Docker/Swarm
version, every stack's live spec (image digests, env, mounts, constraints, resources, ports),
volumes and their sizes, DNS records, and where the automation tool's paid-license certificate
lived in its database. Nothing was written to the source at any point in the project.

**Phase 2 — Purchase.** Bought two new cloud instances at a European cloud provider (Hetzner Cloud),
matching the source's vCPU/RAM/disk per node (the exact original tiers had since been retired, so
their direct successors were used) and the same OS major version as the source, under the owner's
own account — not the browser session's default, which turned out to still be logged into Company
A's account and had to be corrected first.

**Phase 3 — Bootstrap.** Installed the exact Docker/containerd versions the source ran (old package
versions were still available in the vendor's repository pool), initialized the Swarm on the manager
node with an explicit `--advertise-addr`, joined the db node as a worker with a hostname constraint
so the database would land there, and recreated the overlay networks and named volumes the source
used.

**Phase 4 — Deploy.** Rebuilt every stack's compose definition from the source's live inspect output,
substituting only the domain names, and pinned every image to the exact digest the source was
running (tags like `latest` had already moved since the source was first set up). Two images had
disappeared from the public registry entirely since the source pulled them; they were copied node-
to-node with `docker save`/`docker load` instead of re-pulled. Stacks that the source had deployed
through its management UI (Portainer) were created the same way on the target; the two stacks the
source had deployed directly from the CLI (the reverse proxy and the management UI itself) were kept
CLI-deployed on the target too, matching the source's own split.

**Phase 5 — Data: first copy, then reset.** The first pass restored real data from the source's
dumps and volumes into the target, to validate the whole pipeline end-to-end. Once the owner
clarified the real requirement — configuration only, applications empty — everything was reset:
stacks removed, volumes and the primary database wiped, and redeployed clean. The one exception was
the automation tool's paid license, which was deliberately re-injected into the now-empty database,
because the license depends on an identity key that must stay unchanged (see "identity keys" in
`pitfalls.md`) and losing it would have meant losing the license the owner explicitly wanted working.

**Phase 6 — DNS.** Nine subdomain records pointed at the new manager node's IP, created through an
already-authenticated DNS provider MCP tool rather than asking the owner to do it by hand — the tool
existed and was already connected; there was no reason to hand this back.

**Phase 7 — TLS.** Once DNS had propagated, the reverse proxy issued certificates for all nine hosts
automatically via HTTP-01. Verified per host: correct A record, HTTPS reachable, real certificate
(not a default self-signed placeholder), correct hostnames on the certificate.

**Phase 8 — Verification by spec diff.** Every one of the 15 services on the target was diffed
against the matching source service's live spec (normalized: dropped IDs, timestamps, and other
volatile fields) — image, environment, mounts, labels, constraints, resources, ports, update policy.
All matched except the deliberately changed values (domains, rotated passwords). Node OS, Docker
version, and key sysctl values were confirmed to match the source as well.

**Phase 9 — Hardening.** Applied after the owner asked for all outstanding security and
infrastructure issues to be resolved without waiting to be asked item by item: SSH restricted to
key-only auth, credentials the target had inherited unchanged from the source (database and
message-broker passwords, which were publicly reachable) rotated to new values, log rotation added
for a proxy log file that had been growing unbounded, swap configured, and a host firewall put in
front of every port the Swarm published — including the database and cache ports, which had been
open to the entire internet on the source and were carried over open by default until this phase.
The cloud provider's own firewall UI could not be scripted reliably, so the firewall was implemented
as host iptables rules in the chain Docker's own rules don't overwrite, reapplied automatically on
every Docker restart via a systemd drop-in.

**Phase 10 — Updates.** The owner clarified that anything genuinely out of date should be upgraded,
not left "in case it's needed later." The management UI, message broker, and one database engine
were all several versions behind; each was upgraded in place after a backup, with service name
resolution over the overlay network re-verified afterward (an in-place Docker engine upgrade earlier
in the project had already caused exactly this kind of resolution failure once — see `pitfalls.md`).

**Phase 11 — Backups.** Daily dumps of both databases plus a tar of key volumes, retained 7 days,
cross-copied between the two nodes so either node's backups survive the other node failing. Restore
was tested for real on both database engines before considering this phase done.

**Phase 12 — Reboot tests.** Both nodes were rebooted, twice (once before and once after the version
upgrades in Phase 10), to confirm services came back, the overlay network's internal DNS worked
again without manual intervention, and the firewall was still active — nothing here should require
a human to notice and fix it after every restart.

## Corrections the owner made, and the rule each one produced

- **"It has to be two servers, not one."** An early plan had merged both source roles onto a single
  target node to save cost. Rejected immediately and firmly. → *Match the source's server count and
  role placement exactly, unless explicitly told otherwise.*
- **"You misunderstood — the apps should be empty, I only want the configuration."** The first data
  pass had restored everything, including live workflows and credentials. → *Ask "configuration only
  or configuration plus data" up front; never assume either way.*
- **"The provider console is pre-logged into the wrong company's account — it needs to be mine."**
  → *Before purchasing anything, confirm the account name/email shown in the panel matches the
  brief.*
- **"Why didn't you just do the DNS yourself? We already have a DNS tool connected and signed in."**
  → *Enumerate the tools already available before asking a human to do manual work one of them could
  do.*
- **"No fan-out."** A parallel multi-agent pass had been started for a verification step. → *Operate
  on live infrastructure sequentially; parallel agents are for read-only analysis only, and only with
  explicit permission.*
- **"If something needs updating, update it. You're the one who set up the firewall [not me]."** An
  earlier report had deferred needed updates and asked the owner to remove a firewall object created
  by mistake during setup. → *Necessary security work and cleaning up your own mistakes are the
  operator's job, not something to defer back to the owner.*
- **"The tool is self-hosted — why are you calling the license a risk when it's actually fine?"** An
  earlier status report had flagged the license situation with alarming language without stating
  clearly that it was currently valid. → *State facts plainly. A valid, correctly renewing license is
  not "a risk" — say exactly what is and isn't a problem.*

## Final state and open items

At handoff, both nodes were running the full 15-service topology with specs verified to match the
source, all application data empty except the re-injected license, TLS live on every host, hardening
applied and reboot-tested, and backups running on a tested daily schedule. Three items remained
explicitly open, owned by the account holder rather than closed unilaterally:

1. **License renewal on two instances.** The automation tool's paid license is tied to an identity
   key that, by design, had to be copied unchanged from source to target — which means source and
   target now share the same underlying license identity. Whether the vendor's license server
   accepts a renewal request from two live instances at once was not yet confirmed at handoff (the
   next scheduled renewal attempt fell after the project's own visibility window). If it fails, the
   fix is a second, independent license key for one of the two instances.
2. **Backups are cross-node only, not offsite.** The daily backups protect against a single node
   failing, but both copies still live in the same account and datacenter as the data itself. Moving
   to a real offsite destination (the provider's managed backup product, or an external target) was
   recommended but not enabled, since it adds ongoing cost and needed the owner's explicit sign-off.
3. **Two-factor authentication was not yet enabled** on the new hosting account. This requires the
   account holder's own device and was left for them to complete.

Two application stacks (the support-inbox app and the messaging-channel bridge) were explicitly
pulled out of scope by the owner partway through hardening — "leave those alone" — and were left
running with only the one change everything else needed (the rotated database password), nothing else
touched.

## What we would do differently

- Ask the two or three shape-defining questions (server count and role placement, config-only vs.
  data, which account to buy under) as fixed checklist items at the very start, before any
  provisioning — not discover the answer by having the owner correct a wrong assumption after work
  was already done.
- Enumerate connected tools (MCP servers, authenticated CLIs) before the plan is written, not
  partway through, so "do it yourself instead of asking the owner" is the default from step one.
- Never start a parallel/fan-out pass on anything that touches live infrastructure state, even for
  "just verification" — treat that boundary as unconditional, not something to weigh case by case.
- Default to applying needed security patches and cleaning up self-inflicted mess as part of the
  work, and only flag genuinely owner-level decisions (ones with real tradeoffs or ongoing cost) as
  open items — don't blur the two.
- When a paid license's identity is tied to a value you must copy for the clone to work at all (see
  identity keys in `pitfalls.md`), raise the two-instances-one-license question and the "get an
  independent key" option immediately, rather than waiting to find out at the next renewal cycle.
- After any in-place upgrade of the container runtime, verify inter-service name resolution
  explicitly as its own check — "all services show as running" is not the same thing and hid a real
  outage once.
- Get explicit, one-line sign-off before enabling anything with ongoing cost (managed backups,
  paid firewall tiers) instead of either enabling it unasked or silently leaving it undone.
