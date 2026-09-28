# Verification

Read at Phase 9. Nothing is "done" because a command returned 0 (Iron rule 7, `SKILL.md`) - it is done when
the checks below pass, or every failure is understood and written into STATE.md with a reason.

## 1. What "done" requires, in order

1. `parity.py` shows no unexplained DIFF/MISSING (section 2).
2. The inventory diff shows no unexplained gap (section 3).
3. Every service runs on the right node (section 4).
4. Every service is healthy - full replica count, no failing tasks, no errors in recent logs (section 5).
5. Overlay name resolution works between services (section 6).
6. Every public endpoint answers correctly, with a real certificate (section 7).
7. App-level smoke tests pass (section 8).
8. Any license tied to this deployment is valid (section 9).
9. The reboot test passed (section 10; full procedure in `hardening.md` section 6).
10. The final report (section 11) is written, with every remaining item carrying a done-criterion.

## 2. `parity.py`: export, compare, interpret

Export the target the same way the source was exported in Phase 2, then compare:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 --script "$S/remote/export_docker.sh" > "$VPSCLONE_DIR/export/tgt1.stream"
. .vps-clone/env.sh && "$PY" "$S/stacks.py" unpack "$VPSCLONE_DIR/export/tgt1.stream" "$VPSCLONE_DIR/export/tgt1"
. .vps-clone/env.sh && "$PY" "$S/parity.py" "$VPSCLONE_DIR/export/src1" "$VPSCLONE_DIR/export/tgt1" \
  --mapping "$VPSCLONE_DIR/render/mapping.json" --secrets "$VPSCLONE_DIR/render/secrets.json"
```
Repeat per node pair (`src2`/`tgt2`, ...). `parity.py` normalizes away IDs, timestamps and update-status
fields before comparing service specs, so a DIFF there is meaningful, not noise from Docker's own bookkeeping.

- **SAME**: no action.
- **DIFF**: the mapped/rotated value differs from what `--mapping`/`--secrets` predicted. Two causes: (a) a
  real unintended difference - fix it and rerun; (b) a deliberate change the mapping did not account for
  (a version bump, a manually added label) - accept it and write it into STATE.md's Divergences with a
  one-line reason, then also into `OPERATIONS.md` (`hardening.md` section 9's table).
- **MISSING_ON_TARGET**: something the source has that never got deployed - almost always a real gap; go
  back to Phase 6.
- **EXTRA_ON_TARGET**: something the target has that the source did not - usually intentional (a hardening
  service, a monitoring agent) but confirm it was not an accident before accepting it.
- Exit code is 0 only once nothing is left unexplained; a non-zero exit followed by "looks fine to me" is
  not done - every DIFF belongs in STATE.md's Divergences table, explained, before Phase 9 is complete.

## 3. Inventory diff

Run the same read-only inventory used in Phase 2 against the target, and diff the two by eye - the two are
not expected to be byte-identical, since versions and IPs differ on purpose:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 --script "$S/remote/inventory.sh" > "$VPSCLONE_DIR/inventory/tgt1.txt"
diff "$VPSCLONE_DIR/inventory/src1.txt" "$VPSCLONE_DIR/inventory/tgt1.txt" | less
```
Focus on: OS name/major version (must match unless the brief said otherwise), Docker/containerd version
(expected vs source, per the posture decided in Phase 3), custom `sysctl` values, swap size, the enabled and
running service lists, firewall rule counts. A mismatch not already explained by the posture decision goes
into STATE.md.

## 4. Node, role and placement

Confirm each service landed on the node the topology map (Phase 2) said it should - most commonly, a
database service must be on the dedicated DB node, not colocated with the app tier:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service ps postgres_postgres --format "{{.Node}} {{.CurrentState}}" | head -3'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker node ls'
```
If a service landed on the wrong node, check its placement constraint/label in the rendered stack
(`render/stacks/<name>.yml`) against `render/names.json` and the source's constraint (from the Phase 2
export) - a missing or wrong `node.labels.*` constraint is the usual cause.

## 5. Service health

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service ls'
```
Every `Replicas` column must read `N/N`, not `0/1` or `1/2`. For anything short:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service ps <service> --no-trunc'
```
reads the actual failure reason (image pull error, OOM, exit code, missing volume/network) instead of
guessing from `service ls` alone. Then check recent logs for that service, or across all of them:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service logs --since 30m <service> 2>&1 | grep -i error | tail -50'
```

## 6. Overlay DNS

A service that lists as running can still be unable to resolve another service by name - the failure mode
that follows an in-place Docker engine upgrade (`hardening.md` section 4). Prove resolution from inside a
real container, not just that both services show `Running`:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker exec $(docker ps -q -f name=app_) getent hosts db redis 2>&1'
```
Empty output, or `getent: not found` for a name that should resolve on the overlay network, is a real
failure even when `docker service ls` shows everything green.

## 7. Endpoints

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'bash /root/vps-clone/scripts/verify_web.sh --ip 198.51.100.20 app.new.example.org panel.new.example.org'
```
Full usage and the `--resolve` before/after pattern: `dns-tls.md` section 7. Run this after every DNS change
and again after any reverse-proxy or certificate-related update.

## 8. App smoke tests

Beyond "the container is running" - prove each app actually works, from the outside where reasonable:
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://app.new.example.org/healthz     # expect 200
curl -s -o /dev/null -w '%{http_code}\n' https://app.new.example.org/            # login page, expect 200
```
For an app split across editor/webhook/worker processes (n8n in queue mode is the common example), check
each role's health endpoint separately, not just the editor's:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker exec $(docker ps -q -f name=app_editor) wget -qO- http://127.0.0.1:5678/healthz; echo'
```
Confirm each app can actually reach its database - not just that the DB container is up. A login attempt, or
an app-level health check that touches the DB, is stronger evidence than an open port.

## 9. License checks

If a component's paid features depend on a license tied to machine/instance identity (an encryption key that
derives the license's instance id is the common pattern), keeping that identity key (`keep_env` in
`render/mapping.json`) is what keeps the license valid - confirm it actually validated, do not assume:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service logs <app_service> 2>&1 | grep -i -E "licen|enterprise" | tail -10'
```
If the same license ends up active on two running instances at once (source kept alive alongside the new
target during a cutover window), flag it in the final report - some licensing servers refuse to renew for
two instances simultaneously, so a separate license key for the target may be needed if the source stays up
long-term.

## 10. Reboot test

Full procedure and why it matters: `hardening.md` section 6. Do not mark Phase 9 complete without it if
Phase 10 (hardening) already ran - the reboot test exists precisely to catch the interaction between
hardening changes (firewall persistence, swap, log rotation) and a full restart, so it belongs after both.

## 11. Final report template

Short, in the human's language, no secrets (Iron rule 9), pointing at `OPERATIONS.md` for detail:

```
Clone verified.

What works:
- <URL/service> - <one-line evidence, e.g. "200, cert valid until <date>">
- ...

What differs from the source, and why:
- <item> - <reason> (full table: OPERATIONS.md)
- ...

Pending, with done-criteria:
- <item> - done when: <exact, checkable condition>
- ...

Full operations manual: .vps-clone/OPERATIONS.md
```
Every "pending" line needs a done-criterion a different person, or a future session with no memory of this
one, could check without asking anyone - "done when `verify_web.sh` passes for host X" is a done-criterion;
"done when it looks stable" is not.
