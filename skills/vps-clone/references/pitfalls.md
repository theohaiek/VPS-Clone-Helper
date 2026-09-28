# Pitfalls: symptom -> cause -> fix

Read this when something breaks, or before the phase where the pitfall usually hits. Every row is a
real failure seen during a clone, not a hypothetical. "Fix" names the package script that already
handles it where one exists; otherwise it is the manual command.

## Local machine (the machine driving the clone)

| Symptom | Cause | Fix |
|---|---|---|
| A `/etc/...` or `/tmp/...` argument silently becomes `C:/Program Files/Git/etc/...` on Windows | Git Bash (MSYS) auto-converts leading-slash paths it thinks are Unix paths | `export MSYS_NO_PATHCONV=1` before every command; `doctor.py`/`env.sh` already exports it for you |
| A `.sh` file works locally, fails on the server with `$'\r': command not found` | File has CRLF line endings (edited or copied on Windows) | `sshx.py --put`/`--script` strip `\r\n`->`\n` on text extensions automatically; for anything else run `sed -i 's/\r$//' file` or `dos2unix file` before transferring |
| A script whose output is piped into `head` exits non-zero even though the real work succeeded | `set -o pipefail` plus `head` closing its stdin early makes the producer die from SIGPIPE, which pipefail reports as failure | Never pipe a mutating/long command into `head`; redirect to a file and `head` the file instead, or drop `pipefail` for that one line |
| A saved credential/cert/license file fails validation with "unexpected character after JSON" or a length mismatch | Some helper printed a footer (`[rc=N]`, a summary line) after the real stdout, and it got redirected straight into the data file | Never let a wrapper append anything to stdout when its output may be captured as data; `sshx.py` is byte-exact by design — validate saved files by size/hash anyway |
| `stacks.py`/`doctor.py` crash or print mojibake on Windows | Console codepage isn't UTF-8, or a byte can't be printed | Both scripts guard `sys.stdout.reconfigure(errors="replace")`; if you still see a crash, it's a bug — replace, don't ignore |

## Provider / purchase

| Symptom | Cause | Fix |
|---|---|---|
| Server bought lands on the wrong customer/account | The browser or CLI was already authenticated as someone else (a colleague, the source company, a shared login) | Before paying, read the account name/email shown in the panel and match it against the brief; `doctor.py` also flags which provider CLI is authenticated as whom |
| The exact source server type (e.g. a 2 vCPU / 4 GB / 40 GB tier) doesn't exist any more in the provider's list | Providers retire and replace SKUs over time | Pick the successor with the same vCPU/RAM/disk/architecture, not just the closest price; note the substitution in BRIEF.md |
| Target ends up on the provider's newest OS major version, source was older | Providers default new instances to their current image | Explicitly select the source's OS major version at creation (e.g. Debian 12, not whatever is now default) |
| Typing an SSH public key into a provider's web form duplicates or drops the first character | The form's onChange handler races a synthetic `type` event | Use a form-fill tool that sets the value directly (`form_input`) instead of simulated keystrokes; verify by re-reading the field, not by trusting the action succeeded |
| Pressing Enter in a multi-value field (e.g. an IP allow-list) submits the whole form and creates an unwanted object (a firewall, a rule) | Some multi-value inputs treat Enter as submit, not as "add another value" | Never send Enter into such a field; if something gets created by mistake, delete it yourself, don't leave it for the owner |
| New instance boots with SSH host keys already known/pinned from a template or snapshot | cloud-init only regenerates host keys when it sees a fresh `instance-id`; images built by hand or reused from a snapshot can carry over the old ones | Confirm new host keys on first boot (`ssh-keygen -A` was run) before trusting the connection; if you cloned disk-to-disk instead of rebuilding, regenerate them yourself: `rm /etc/ssh/ssh_host_*; ssh-keygen -A` |

## Docker / Swarm

| Symptom | Cause | Fix |
|---|---|---|
| `apt install docker-ce=<old-version>` fails with "unable to locate package" assumption before even trying | Wrong assumption — old `.deb`s are not removed from the vendor's apt pool just because a newer version shipped | Check first: `apt-cache madison docker-ce`; `docker_install.sh --docker <exact-version>` installs it directly, no need to hunt manually |
| `docker swarm init` picks the wrong IP (a private NIC, a NAT'd address) and other nodes can't join | `--advertise-addr` was left to auto-detect on a multi-NIC host | Always pass `--advertise-addr <public-or-correct-IP>` explicitly; `node_bootstrap.sh --swarm-init <IP>` requires it, no silent default |
| After an in-place Docker/containerd upgrade, services fail with `ENOTFOUND redis`/`ENOTFOUND postgres` and `dockerd` logs "Inconsistent driver and libnetwork state" | Containers restarted by the upgrade don't re-register on the overlay network's embedded DNS | Right after any Docker upgrade: `docker service update --force -d <service>` on every service, then test name resolution between containers, not just `docker service ls`. A plain reboot does not have this problem |
| `docker pull` of an image that was running fine a year ago now says "pull access denied" / "manifest unknown" | The image (or tag) was removed or made private on the registry since the source pulled it | Copy it directly from the source instead of re-pulling: `sshx.py pipe src1 'docker save img:tag' tgt1 'docker load'`; keep an offsite copy of that tar, it may be the only copy left anywhere |
| A service on the target quietly starts running a different build than the source was running | Image was referenced by a moving tag (`latest`, `sts`, a distro rolling tag) that has moved since inventory | Pin every image by the digest actually running on the source (`stacks.py pins`, from the live Swarm task spec, not just `docker images`), then `image_override` in the render mapping |
| `/etc/sysctl.conf` has the same line appended a dozen times, some installer or script ran repeatedly | A script used `echo ... >> /etc/sysctl.conf` instead of a idempotent drop-in | Write to `/etc/sysctl.d/90-*.conf` and check-before-append instead; `node_bootstrap.sh --sysctl` already does this |
| An unfamiliar stack layout turns out to have a network `network_swarm_public`, a volume `volume_swarm_certificates`, a Traefik resolver literally named `letsencryptresolver`, and Portainer at `painel.<domain>` | This is the signature of a popular one-click Swarm installer script (forum/gist origin), not a hand-built topology | Recognize the pattern and reuse the same network/volume/resolver names on the target rather than inventing new ones — see `references/docker.md` |

## Portainer

| Symptom | Cause | Fix |
|---|---|---|
| API call to create the admin returns "Invalid or missing setup token" | Recent Portainer versions require a one-time setup token from the container's own log, sent as header `X-Setup-Token`, instead of accepting a password directly | Read `setup_token=...` from `docker service logs`/`docker logs` right after start and send it as `X-Setup-Token`; `portainer.sh init` does this |
| Admin init request fails with "Administrator initialization timeout" | Portainer locks initialization ~5 minutes after the container starts if no admin was created yet | Force-restart the service (`docker service update --force portainer_...`) and retry immediately; `portainer.sh init` retries automatically |
| A stack edited through the Portainer UI reverts, or "pull and redeploy" reapplies stale content | The stack was updated with plain `docker stack deploy` instead of the Portainer API, so Portainer's own record of the file went stale and disagrees with what's actually running | Never `docker stack deploy` a Portainer-managed stack; always `portainer.sh update NAME FILE`. Conversely, never `portainer.sh update` a stack that was always CLI-deployed (typically the reverse proxy and Portainer itself) |
| After a reboot or `dockerd` restart, Portainer logs "agent was unable to contact any other agent located on a manager node" and stacks show as unmanaged | Portainer agents on different nodes can come up in separate mini-clusters if they race the network coming up | `docker service update --force -d portainer_agent`; install as a `@reboot sleep 180 && ...` cron so it self-heals every boot (`harden.sh --portainer-agent-fix`) |
| API calls from a throwaway curl container fail with a file-read error even though the JSON body clearly exists on disk | The remote working directory was `chmod 700`, and the curl container's default non-root user can't read into it | Run the curl container with `--user 0:0` and mount a root-only temp dir (`/tmp/vps-clone-api`, 700, files 600) read-only; never make request bodies world-readable (they hold secrets) |

## Traefik / TLS

| Symptom | Cause | Fix |
|---|---|---|
| Every host serves `TRAEFIK DEFAULT CERT` (self-signed) or 404, log shows "client version 1.24 is too old" | Docker >= 29 raised its minimum supported API version past 1.24, which older Traefik v2 builds hard-code | Run Traefik >= 2.11.31 (auto-negotiates the API version), or keep Docker < 29 if you can't upgrade Traefik yet |
| Traefik's log file grows hundreds of MB in weeks | `--log.level=DEBUG` writing to a file inside the container, with no rotation | INFO (not DEBUG) to stdout, and rely on the Docker log driver's rotation (`daemon.json` `max-size`/`max-file`) instead of an in-container file |
| `certbot`/Traefik ACME HTTP-01 challenge fails or issues nothing on the target | DNS for that host still points at the source (or nowhere) when the challenge runs | Confirm resolution first: `curl -sSI --resolve host:443:<target-ip> https://host/`; only cut DNS over once this succeeds, or use DNS-01 if HTTP-01 can't wait |
| ACME requests start failing with "too many certificates already issued" | Let's Encrypt allows 50 certs per registered domain per week and 5 duplicates per week; repeated failed test runs against the real domain burn through it | Test against `--resolve` (no real cert issuance) before ever pointing DNS at the target; if you must issue for real repeatedly, use a staging ACME endpoint first |
| Cutover window is longer than planned because clients keep resolving the old IP for hours after the DNS change | DNS TTL was left at its old (often long) value going into the cutover | Lower TTL to 60-300s a day or more ahead of the planned cutover, then restore it afterward if desired |

## Databases / data

| Symptom | Cause | Fix |
|---|---|---|
| `pg_dump`/`pg_dumpall` exits fine but the dump file is empty or near-empty | An invalid flag combination was used (e.g. a malformed `--no-owner` value) and the tool silently produced nothing useful | Always verify dump size and `gzip -t`/`pg_restore --list` before trusting a dump; `backup.sh` writes `*.tmp`, gzips, tests, then renames — never trust an untested dump |
| A MySQL/MariaDB/Percona restore test hangs or errors right after the container starts | Percona-family images do a two-phase startup; a client connecting during phase one gets "Access denied" or a connection refused, which looks like a broken restore | Wait for "init process done" in the container log, not "ready for connections" (that log line appears once per phase) |
| Rotating the DB root/admin password later doesn't take effect for a user created at first boot | `MYSQL_ROOT_PASSWORD`/`MARIADB_ROOT_PASSWORD` only apply during the image's first initialization, never again | To actually rotate later: `ALTER USER 'root'@'%' ...` and `'root'@'localhost'` inside the running server, not just the env var. RabbitMQ with no real data yet: reset the volume so user/pass/cookie re-init cleanly instead |
| After rotating a shared credential, dependent apps reconnect with the old value and fail | Consumers were updated after the credential rotated, or the stack-update mechanism itself wasn't healthy yet | Prove the stack-update path works on a low-risk stack first (management API responding, update succeeds), only then rotate the credential, then update every consumer |
| A leftover dump file with real production data sits in `/tmp` on the source or target after the clone is "done" | Cleanup was skipped because the operation looked finished | Remove temporary dumps from both sides immediately after use; the source stays read-only and untouched otherwise |

## Apps (n8n, Chatwoot, MinIO, Evolution API)

| Symptom | Cause | Fix |
|---|---|---|
| An app's stored credentials/secrets become unreadable right after migration, even though the app itself still runs | An identity/encryption key (`N8N_ENCRYPTION_KEY`, Rails `SECRET_KEY_BASE`, Laravel `APP_KEY`, Django `SECRET_KEY`) changed between source and target — these encrypt data at rest keyed to that exact value | Copy the identity key **literally**, unchanged, into the target's env before the app's first boot. This is the one class of "secret" that must never be rotated during a clone |
| A paid n8n license fails to renew, or renews on only one of two instances | The license is tied to an `instanceId` that n8n derives from `N8N_ENCRYPTION_KEY`; running the same key (hence the same instanceId) on two live instances means both are asking the vendor's license server to renew the same license concurrently | Expected if source and clone share the key intentionally (needed to keep the license valid at all on the clone). Get an independent license key for one of the two instances before the next renewal if both need to stay licensed long-term |
| `/metrics` (or another operational endpoint) is reachable from the internet with no auth | The app's own defaults expose it, and the migration copied the config as-is | Explicitly disable public metrics/debug endpoints on the target (e.g. n8n: `N8N_METRICS=false`) even when matching the source, unless the source's exposure was itself intentional |
| Chatwoot boots against an empty database but there's no way to create the first admin through the web UI | Chatwoot's onboarding sign-up page is reachable only while the account count is zero; once the first account exists it stops being reachable, and there is no separate toggle to reopen it | Run `bundle exec rails db:chatwoot_prepare` once against the empty DB, then create the super admin via `rails console` |
| An app that uses object storage (MinIO/S3) errors on first write with "bucket does not exist" | The bucket was implicit in the source (created once, long ago) and never recreated on the target | Create the bucket before the app's first real use, not after the first failure |
| Outbound email from the new IP gets marked spam or rejected outright | A brand-new IP has zero sender reputation regardless of how well-configured SPF/DKIM are | Route transactional/marketing email through a reputation-managed relay (SES, SendGrid, Postmark, etc.) during warm-up instead of sending directly from the new server's IP |
| An app config still works but silently still points at the old server | A literal IP (not a hostname) was hardcoded somewhere in an app's config and the text-replace pass only covered domains | Before calling the render step done, grep the rendered configs for leftover old IPs: `grep -rE '([0-9]{1,3}\.){3}[0-9]{1,3}' <rendered-dir>` and confirm every hit is either expected (a private/internal IP) or fixed |

## Security

| Symptom | Cause | Fix |
|---|---|---|
| A database port (5432/3306/6379/27017/...) or the Swarm control ports (2377/7946/4789) answer from the public internet even though `ufw`/iptables INPUT rules look correct | Docker writes its own iptables rules ahead of `INPUT` for anything published by a Swarm service or `-p` in compose, so host firewall tools that only touch `INPUT` never see that traffic | Filter in the `DOCKER-USER` chain instead — the only chain Docker does not overwrite on restart — and open Swarm's own ports (2377 tcp, 7946 tcp+udp, 4789 udp) only between cluster node IPs, never publicly (`firewall.sh`, and see `chaifeng/ufw-docker` for the same fix implemented against ufw specifically) |
| The provider's own cloud firewall UI can't be scripted reliably (fields reject pasted values, multi-value inputs misbehave) and there's no API token available for it | Some provider consoles are simply not built for automated multi-value entry | Fall back to host-level iptables/DOCKER-USER rules reapplied by a systemd drop-in on every Docker start, and verify with a real external port scan and after a reboot, rather than trusting the UI saved correctly |
| Target still accepts the source's old database/admin passwords after the "clone" | Passwords were copied 1:1 along with everything else, by default | Default to new, independently generated passwords for DB/admin accounts on the target; only keep a value identical to the source when something depends on the literal value (see identity keys above). Confirm no source secret value remains anywhere in the target's configs |
| Everything looked fine before a reboot, but a service or the firewall is silently gone/inactive after one | Something (a firewall chain, a cron job, a sysctl setting) was applied live but never made to survive a restart | Reboot both/every node once after bootstrap and again after any hardening or major upgrade; confirm all services return, overlay DNS resolves, and the firewall counters are still active — don't consider hardening done until this passes |

## Backups

| Symptom | Cause | Fix |
|---|---|---|
| "We have backups" turns out to mean untested dump files nobody has restored | Backups were configured but never verified end-to-end | Test an actual restore (not just that the dump file exists) before calling backup coverage done; `backup.sh` marks `last_ok` only after `gzip -t` succeeds, but a full restore test is still a manual step worth doing once |
| A cluster's only backups live on the same nodes/datacenter/account as the data itself | Cross-node copies between the cluster's own nodes were treated as sufficient | Cross-node copy is a good first layer (survives a single-node failure) but is not offsite — recommend the provider's managed backups or an external destination for real disaster coverage, and get explicit sign-off before enabling anything that adds ongoing cost |

## Behavior rules learned the hard way

1. **Match the source's server count and role placement exactly, unless told otherwise.** Merging two roles onto one box to save cost is a scope change, not an optimization — it changes what "cloned" means without being asked.
2. **Ask "configuration only, or configuration plus data" before touching anything.** These are two entirely different jobs (a data reset is destructive and hard to undo cleanly) and the answer is never safe to assume either way.
3. **Confirm which account you're acting as before you spend money or make changes.** A pre-authenticated browser/CLI session can belong to someone else's account; check the name/email shown before purchasing or provisioning.
4. **Discover what tools you already have before asking a human to do manual work.** List available MCP servers, CLIs, and stored credentials first; asking someone to do by hand what an already-connected tool can do is a wasted step, not politeness.
5. **Operate on live infrastructure sequentially.** Parallel/fan-out agents belong to read-only analysis at most, and only with explicit permission — never to steps that mutate shared state like servers, DNS, or databases.
6. **Necessary security patching and cleaning up your own mistakes are your job, not something to hand back.** Don't leave an update "for later" and don't ask the owner to delete something you created by accident.
7. **State facts plainly, especially about risk.** A valid license that's renewing on schedule is not "a risk" — calling it one without the qualifier creates alarm and burns trust for no reason. Say exactly what is and isn't a problem.
