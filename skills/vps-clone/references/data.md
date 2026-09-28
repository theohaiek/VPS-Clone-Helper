# Moving data: modes, engines, identity keys, rotation, verification

Read this during Phase 7 (data), after the configuration is deployed and healthy (`docker.md`).
Every command starts with `. .vps-clone/env.sh &&` and calls `"$PY" "$S/sshx.py"`. The source stays
read-only throughout: dumps happen on the source only inside `sshx.py pipe`, which streams through
this machine and writes nothing on the source disk, or (when a step genuinely must write a
temporary file on the source, e.g. a tool with no stdin/stdout dump mode) with `--allow-write` and
an explicit delete afterwards (section 6). `src1`/`src2` and `tgt1`/`tgt2` are the source/target
aliases from Phase 1.

## 1. Pick the mode (decided in Phase 1, executed here)

**`config-only`** — target applications start empty. Create only the databases each stack expects
(same names, no rows), then run each app's own first-run preparation so it does not crash looking
for schema/state that a normal fresh install would have created for it:
- A Rails-style app that skips its normal onboarding wizard once a super-admin account exists
  anywhere in its database (e.g. Chatwoot) needs its `db:*_prepare`-style rake task run once,
  before the app is expected to serve traffic:
  ```bash
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker exec $(docker ps -q -f name=chatwoot_admin_chatwoot_admin | head -1) bundle exec rails db:chatwoot_prepare'
  ```
- Object storage apps (MinIO-backed uploads, avatars, attachments) need their bucket created
  *before* the app that writes to it: a first write attempt against a missing bucket is usually
  what surfaces as a silent upload failure in the app's UI, not a database error.
- Leave the product's own first-user / owner setup screen (n8n's owner-setup wizard, similar
  screens in other self-hosted tools) for the human owner to complete themselves the first time
  they open the URL — do not fabricate a fake first admin account through the database on their
  behalf unless the brief explicitly asked for it.
- Keep whatever identity keys and license material the brief says to keep even in `config-only`
  mode (section 3) — those are about the *product installation* staying licensed/functional, not
  about copying any customer data.

**`full`** — copy config *and* real data (section 2), plus the same identity-key and license care
as `config-only` (section 3).

**`full+cutover`** — same as `full`, plus one more delta sync of every dataset right before the DNS
switch, to catch writes that happened on the source between the first dump and go-live (section 5
of `dns-tls.md` covers the DNS side; this file covers the data delta itself, same commands as
section 2, run a second time just before cutover).

## 2. Full data: consistency and per-engine commands

**Consistency choice, made once per dataset before dumping anything:** either stop the writer
first (the source app/service; a Swarm stack can be `docker service scale <name>=0`), which gives
a byte-perfect dump but a downtime window on the source, or accept a *hot* dump taken while the
source keeps running, which needs zero source downtime but is only a consistent-as-of-that-instant
snapshot — anything written after the dump started is missing until the `full+cutover` delta
(section 1) catches it. A hot dump is safe for every engine below as long as its documented
consistency flag is used (`--single-transaction` for MySQL, `pg_dump`'s own MVCC snapshot, Redis
`BGSAVE`'s copy-on-write fork); it is not safe to instead cold-copy a live engine's raw data
directory with a generic file copy (see the volumes note at the end of this section).

**PostgreSQL** — whole-cluster dump (roles + every database, plain SQL, simplest restore) or a
single database in the parallel-restorable custom format:
```bash
# whole cluster
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src2 'docker exec -i $(docker ps -q -f name=postgres_postgres | head -1) pg_dumpall -U postgres' \
                                          tgt2 'docker exec -i $(docker ps -q -f name=postgres_postgres | head -1) psql -U postgres -v ON_ERROR_STOP=1 -q'
# one database, custom format, parallel restore
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src2 'docker exec -i $(docker ps -q -f name=postgres_postgres | head -1) pg_dump -Fc -d appdb' \
                                          tgt2 'docker exec -i $(docker ps -q -f name=postgres_postgres | head -1) pg_restore -d appdb -j4 --no-owner'
```
`pg_dumpall`/`pg_dump` need no special consistency flag: PostgreSQL's own MVCC snapshot handles a
hot dump correctly on its own. Do not pass `--no-owner=false` to `pg_dump` expecting it to be the
default's opposite — it is not a valid flag and produces an empty dump silently; use `--no-owner`
(a bare flag) on the restore side instead, as above, when the target's role names differ.

**MySQL / MariaDB / Percona** — always with `--single-transaction` for a hot dump of InnoDB tables
(without it, a dump of a live database is not transactionally consistent), plus routines/events/
triggers, which a plain `mysqldump` silently omits:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe \
  src1 "docker exec \$(docker ps -q -f name=mysql_mysql | head -1) sh -c 'MYSQL_PWD=\"\${MYSQL_ROOT_PASSWORD:-\$MARIADB_ROOT_PASSWORD}\" mysqldump -uroot --all-databases --single-transaction --routines --events --triggers --set-gtid-purged=OFF'" \
  tgt1 "docker exec -i \$(docker ps -q -f name=mysql_mysql | head -1) sh -c 'MYSQL_PWD=\"\${MYSQL_ROOT_PASSWORD:-\$MARIADB_ROOT_PASSWORD}\" mysql -uroot'"
```
`--set-gtid-purged=OFF` avoids the restore trying (and usually failing) to replay the source's own
GTID history on a target that is not a replica of it. `MYSQL_PWD` is read from the container's own
`MYSQL_ROOT_PASSWORD` (or `MARIADB_ROOT_PASSWORD` on a MariaDB/Percona image) env var through an
inner `sh -c` — the same pattern `remote/inventory.sh` already uses for its own database-size
query — so nobody has to know, type, or pass a password on either side. Do **not** reference a
bare `$VAR` directly in a `sshx.py`/`sshx.py pipe` argument expecting it to carry a value from the
*local* shell: `sshx.py` transmits the command text unchanged over SSH and never forwards the local
environment, so such a `$VAR` is expanded by the *remote* shell instead, which never has it set —
the value silently becomes empty rather than failing loudly.

**MongoDB**:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'docker exec -i $(docker ps -q -f name=mongo_mongo | head -1) mongodump --archive' \
                                          tgt1 'docker exec -i $(docker ps -q -f name=mongo_mongo | head -1) mongorestore --archive'
```

**Redis** — no `mongodump`-style streaming dump exists; trigger a snapshot on the source, then copy
the resulting file (not the whole data directory, only the snapshot). `BGSAVE` writes `dump.rdb` to
the source's own disk, so — like any other step in this file that writes to the read-only source
(section 1) — it takes `--allow-write`; unlike the temp dumps in section 6, `dump.rdb` is Redis's
own persistence snapshot, not a throwaway file, so it is *not* deleted afterward:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 'docker exec $(docker ps -q -f name=redis_redis | head -1) redis-cli BGSAVE' --allow-write
# wait for the background save to finish, then stop the target's redis so nothing restarts and
# reloads a half-written file while it lands:
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service scale redis_redis=0'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'docker exec $(docker ps -q -f name=redis_redis | head -1) cat /data/dump.rdb' \
                                          tgt1 'sh -c "cat > /var/lib/docker/volumes/redis_data/_data/dump.rdb"'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service scale redis_redis=1'
```
Redis must be stopped on the target (or not started yet) when the file lands, and started fresh
right after — it only loads `dump.rdb` at startup. `BGSAVE` forks and writes in the background
(non-blocking on the source); a plain `SAVE` blocks the source's Redis until it finishes and should
be avoided on a server that must stay live.

**Volumes (uploads, attachments, any bind data with no dump tool of its own)** — stream a tar
archive of the volume's data directory through this machine, target service stopped so nothing
mutates the files mid-copy:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service scale minio_minio=0'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" pipe src1 'tar czf - -C /var/lib/docker/volumes/minio_data/_data .' \
                                          tgt1 'tar xzf - -C /var/lib/docker/volumes/minio_data/_data'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service scale minio_minio=1'
```
This is also the pattern for the "volumes" half of `docker.md` section 8's docker-compose bind
mounts. Do not point this `tar` at a live database engine's own data directory
(`/var/lib/docker/volumes/postgres_data/_data`, `/var/lib/mysql`, etc.) even with the writer
stopped as a shortcut instead of a proper dump — file-level copies of a database's internal
storage format are only safe when the engine's own documented cold-copy procedure is followed
exactly (checkpoint state, WAL segments, storage-engine-specific files all have to stay
consistent with each other); the dump/restore commands above are the safe, engine-endorsed path
and should be preferred every time a dump tool exists for that engine.

**After every restore in this section**: verify before moving on (section 7). A silently empty or
truncated dump is a real failure mode, not a theoretical one — the pattern in `docker.md` and
below (write to a `.tmp` path, then a format-level integrity check, then rename into place) exists
because of it.

## 3. Identity keys and licenses

Some values are not "data" to migrate — they are the installation's *identity*, and copying the
application's config or database without them makes existing encrypted values permanently
unreadable, or invalidates a license tied to that identity. Keep these **exactly as they were on
the source**, in every mode including `config-only`, unless the brief explicitly says to rotate
them (which then means: rotate them *and* accept that whatever they protected on the source is
unrecoverable on the target):

| Key | What breaks if it changes | Where it lives |
|---|---|---|
| An app-level encryption key (e.g. `N8N_ENCRYPTION_KEY`) | Every credential/secret the app stored encrypted becomes unreadable; the app's own instance identity (often derived from this key) changes too, which can also invalidate a license tied to that identity | Stack env var — carried over automatically by `stacks.py render` unless listed in `rotate_env` |
| `SECRET_KEY_BASE` (Rails), `APP_KEY` (Laravel), `SECRET_KEY` (Django), JWT signing secrets | Every signed session/cookie invalidates at once (forced logout of every user); anything encrypted with it (Rails `ActiveSupport::MessageEncryptor`-backed fields) becomes unreadable | Stack env var — same as above |

Put every one of these keys in `mapping.json`'s `keep_env` (see `docker.md` section 4) — `render`
then never rotates them even if a broader pattern in `rotate_env` would otherwise match, and warns
if a key appears in both lists so the conflict cannot pass silently.

**A license certificate stored as a database value, not an env var** (seen in the source case as
n8n's `settings` table, key `license.cert`) needs to be written back explicitly after the schema
exists (i.e. after the app has booted once against an empty database and created its own tables),
with an upsert so re-running the step is harmless:
```sql
insert into settings (key, value, "loadOnStartup")
values ('license.cert', '<cert-value>', false)
on conflict (key) do update set value = excluded.value;
```
Two things that go wrong here in practice, both worth checking every time:
- **Validate the value's exact length before writing it**, and compare it again after writing (a
  cert like this is normally a fixed-length base64 blob). A value that is short, or that changed
  length between "what you meant to write" and "what is now in the database", means it got
  truncated or mangled somewhere in the pipeline — do not proceed with the app still expecting
  that value.
- **Never append anything to the value on its way in.** A helper script that prints a status line
  after streaming output (`"[rc=0]"`, a summary line, a trailing prompt) and does not clearly
  separate that from the data itself can end up with that line concatenated onto the value it just
  wrote — the app then rejects the whole field as malformed the moment it parses it. Keep any
  logging/status output on a channel the data itself never flows through (stderr, a separate file,
  the caller's own echo *after* the value is confirmed written — never appended to the same stdout
  a value was captured from).

## 4. Secret rotation (posture `parity + security`)

Rotating a password is more than changing where the stack file points — every consumer service
still holds the *old* value until you update it, and a database engine only honors the *new* value
starting from when you explicitly change it (most engines do not re-read a "set password" env var
on every restart; it typically only applies the very first time the engine initializes its data
directory). Order matters:

1. **Prove the update path works on something low-risk first.** Before rotating a real password,
   confirm `remote/portainer.sh update` (or `docker stack deploy` for a CLI-deployed stack)
   actually reaches and redeploys the target stack successfully — rotating a password and then
   discovering the deploy path itself is broken leaves every consumer holding a password nothing
   accepts.
2. **Change the password where the engine actually enforces it**, not just in the file:
   - **PostgreSQL** — existing connections keep working; only new connections need the new
     password from this point on:
     ```bash
     . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 "docker exec -i \$(docker ps -q -f name=postgres_postgres | head -1) psql -U postgres -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD '<new-password>';\""
     ```
   - **MySQL/MariaDB/Percona** — the `MYSQL_ROOT_PASSWORD`/`MARIADB_ROOT_PASSWORD` env var only
     applies the *first* time the engine initializes an empty data directory; on an already
     -initialized instance (which this clone's data directory now is, once restored) changing that
     env var in the stack file alone does nothing — issue `ALTER USER` for both host forms:
     ```bash
     . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 "docker exec -i -e MYSQL_PWD='<old-password>' \$(docker ps -q -f name=mysql_mysql | head -1) mysql -uroot -e \"ALTER USER 'root'@'%' IDENTIFIED BY '<new-password>'; ALTER USER 'root'@'localhost' IDENTIFIED BY '<new-password>'; FLUSH PRIVILEGES;\""
     ```
   - **RabbitMQ with no data worth keeping** — simplest correct fix is to stop the service and
     zero its data volume, so it reinitializes cleanly with the new user/password/erlang-cookie
     from the (already-updated) stack file on next start, instead of trying to change credentials
     inside a running broker:
     ```bash
     . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service scale rabbitmq_rabbitmq=0'
     . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'rm -rf /var/lib/docker/volumes/rabbitmq_data/_data/* /var/lib/docker/volumes/rabbitmq_data/_data/.[!.]*'
     . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker service scale rabbitmq_rabbitmq=1'
     ```
     If the queue holds data worth keeping instead, rotating credentials in place needs RabbitMQ's
     own user-management commands (`rabbitmqctl change_password`) rather than a volume wipe.
3. **Update every consumer** (every stack whose env references that password, typically via a full
   connection string/DSN) through `portainer.sh update` / `docker stack deploy`, using the same
   rendered stack files from `docker.md` section 4 — `stacks.py render`'s `rotate_env` already
   replaced the value everywhere it appeared, including inside DSNs, so this step is "redeploy",
   not "hand-edit".
4. **Verify the old password is now rejected**, not just that the new one works — both directions
   matter, because a still-accepted old password usually means step 2 targeted the wrong host form
   or the wrong instance:
   ```bash
   . .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 "docker exec -e MYSQL_PWD='<old-password>' \$(docker ps -q -f name=mysql_mysql | head -1) mysql -uroot -N -e 'select 1'"
   ```
   Expect a non-zero exit / an access-denied error. If it still succeeds, the rotation is not done.

## 5. `full+cutover` delta

Run the same section 2 commands again for every dataset, immediately before the DNS switch in
`dns-tls.md`, ideally inside a short write freeze on the source (stop the writer service just for
this final pass). This delta only needs to move what changed since the first pass — for the SQL
engines a fresh full dump/restore is still simplest and safe to repeat; for a large volume, prefer
`rsync -a --delete`-style incremental behavior if available on the source, otherwise repeat the
section 2 `tar` pipe. A second `tar` pass still correctly adds and overwrites every file that
exists on the source, just not incrementally, but it does **not** remove a target file whose
source file was deleted between the two passes (only `rsync --delete` does) — usually harmless for
an uploads/attachments volume over a short cutover window, but note it as a known gap rather than
assuming full parity.

## 6. Clean up temporary dumps

The source must not be left holding dump files after use — it stays read-only and untouched beyond
the duration of the dump itself. Any step in this file that could not stream directly through
`sshx.py pipe` and instead had to write a file on the source with `--allow-write` must delete that
file again as its last action:
```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 'rm -f /tmp/vps-clone-*.sql /tmp/vps-clone-*.dump /tmp/vps-clone-*.tgz' --allow-write
```
Do the same for temporary files left on the target once a restore is confirmed good (section 7) —
they are not secrets, but they are dead weight and, for a dump containing full application data,
also a second copy of sensitive rows sitting around longer than necessary.

## 7. Verification

Before calling any restore in this file done, compare row/table counts (and, for volumes, sizes)
on both sides — a restore that "returned 0" is not evidence by itself (iron rule 7 in SKILL.md); an
empty or partial import from a truncated or malformed dump also exits 0 in several of these tools.

```bash
# Postgres: row counts per table, per database
. .vps-clone/env.sh && "$PY" "$S/sshx.py" src2 'docker exec $(docker ps -q -f name=postgres_postgres | head -1) psql -U postgres -d appdb -Atc "select relname, n_live_tup from pg_stat_user_tables order by 1"'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt2 'docker exec $(docker ps -q -f name=postgres_postgres | head -1) psql -U postgres -d appdb -Atc "select relname, n_live_tup from pg_stat_user_tables order by 1"'

# MySQL: size per schema (a fast, good-enough consistency check for "did the dump restore")
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 "docker exec -e MYSQL_PWD='<pw>' \$(docker ps -q -f name=mysql_mysql | head -1) mysql -uroot -N -e \"select table_schema, round(sum(data_length+index_length)/1024/1024,1) mb from information_schema.tables group by table_schema\""

# Mongo: document counts per collection
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'docker exec $(docker ps -q -f name=mongo_mongo | head -1) mongosh --quiet --eval "db.getCollectionNames().forEach(c=>print(c, db[c].countDocuments()))"'

# a volume copy: size comparison, both sides
. .vps-clone/env.sh && "$PY" "$S/sshx.py" src1 'du -sh /var/lib/docker/volumes/minio_data/_data'
. .vps-clone/env.sh && "$PY" "$S/sshx.py" tgt1 'du -sh /var/lib/docker/volumes/minio_data/_data'
```
`n_live_tup` is an estimate updated by autovacuum, not a live `count(*)` — close enough for parity
evidence; use `select count(*) from <table>` per table instead if the brief calls for an exact
match. Record every count pair (source vs. target) in STATE.md, and any mismatch as a divergence
with its reason (e.g. "N fewer rows: writes on the source between dump and cutover, covered by the
`full+cutover` delta in section 5"), not silently.
