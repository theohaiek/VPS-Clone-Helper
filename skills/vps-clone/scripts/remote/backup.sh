#!/usr/bin/env bash
# backup.sh - daily backup of one host: dumps every database running in a local Docker
# container, tars configured volumes/paths, applies retention, and (optionally) cross-copies
# the local backup dir to a peer node over rsync/ssh. Config-driven, idempotent, no arguments
# beyond -h. Install it as a cron job with backup_install.sh.
#
# Config file: /etc/vps-clone/backup.env (override the path with the CONF_FILE env var).
# Every key can also be set as an environment variable when invoking this script directly;
# an explicit environment variable wins over the config file, which wins over the built-in
# default below (same precedence rule as firewall.sh / node_bootstrap.sh).
#
#   BACKUP_DIR      local backup root                                  (default: /root/backups)
#   RETENTION_DAYS  days of local dumps/tars to keep                   (default: 7)
#   VOLUMES         space-separated docker volume names to tar         (default: empty)
#   PATHS           space-separated extra host paths to tar            (default: empty)
#   BACKUP_EXCLUDE  space-separated tar --exclude patterns             (default: "n8nEventLog* crash.journal *.sock")
#   PEER            root@IP of a peer node to cross-copy backups to    (default: empty, skipped)
#   PEER_KEY        ssh private key used to reach PEER                 (default: /root/.ssh/vps-clone-backup)
#
# Database detection is automatic: every running container whose image name matches
# postgres/postgis/timescale, mysql/mariadb/percona, mongo, or redis/valkey/keydb is dumped.
# One file per container: <sanitized-container-name>_<engine>_<UTC timestamp>.<ext>.gz
#
# Credentials are never passed on a command line (visible in `ps`/docker logs). Instead every
# dump runs as `docker exec CONTAINER sh -c '... "$SOME_VAR" ...'`: the shell expansion happens
# INSIDE the container, using that container's own environment, so the password/user value
# itself is never an argument on the host. Postgres user comes from the container's
# POSTGRES_USER (default postgres); MySQL/MariaDB/Percona password from the container's
# MYSQL_ROOT_PASSWORD or MARIADB_ROOT_PASSWORD via MYSQL_PWD; Redis password (if set) from the
# container's REDIS_PASSWORD.
#
# ---- restore hints (exact commands, adjust CONTAINER/host names) -------------------------
#
# postgres:
#   gunzip -c FILE.sql.gz | docker exec -i CONTAINER sh -c 'psql -U "${POSTGRES_USER:-postgres}"'
#
# mysql / mariadb / percona:
#   gunzip -c FILE.sql.gz | docker exec -i CONTAINER sh -c \
#     'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" mysql -uroot'
#   Percona/MySQL containers do a TWO-PHASE startup on first init: the log reaches
#   "mysqld: ready for connections" once early, then the server restarts and only the SECOND
#   "ready for connections" (preceded by "MySQL init process done. Ready for start up.") is the
#   real one. Wait for that line (`docker logs -f CONTAINER | grep -m1 'init process done'`)
#   before restoring into a freshly started container, or the restore lands mid-reinit and gets
#   wiped. Also: MYSQL_ROOT_PASSWORD only seeds root's password on a fully empty data
#   directory; on a container with existing data, rotate it with `ALTER USER` for both
#   'root'@'%' and 'root'@'localhost' instead of just changing the env var.
#
# mongo:
#   gunzip -c FILE.archive.gz | docker exec -i CONTAINER mongorestore --archive --drop
#
# redis / valkey / keydb:
#   gunzip -c FILE.rdb.gz > dump.rdb
#   docker cp dump.rdb CONTAINER:/data/dump.rdb   # or wherever CONFIG GET dir/dbfilename point
#   docker restart CONTAINER                      # redis only loads the RDB file at startup
#
# volumes / paths tars:
#   docker stop CONTAINER   # avoid restoring under a writer
#   tar xzf volumes_TS.tgz -C /var/lib/docker/volumes   # (paths_TS.tgz: -C / instead)
#   docker start CONTAINER
#
# ---------------------------------------------------------------------------------------------
set -euo pipefail

log(){ echo "[backup $(hostname) $(date -u +%H:%M:%S)] $*"; }
has(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "backup.sh: must run as root" >&2; exit 1; }; }

CONF_FILE="${CONF_FILE:-/etc/vps-clone/backup.env}"

usage(){
  cat <<'EOF'
Usage: backup.sh [-h]

Dumps every database running in a local Docker container (postgres/postgis/timescale,
mysql/mariadb/percona, mongo, redis/valkey/keydb), tars configured volumes/paths, applies
retention, and (if PEER is set) cross-copies the local backup dir to a peer node over
rsync/ssh (falling back to tar over ssh if rsync is missing on either side).

All configuration comes from environment variables / the config file; see the header comment
of this file for the full list and precedence rule. Meant to run once a day from cron; see
backup_install.sh to install it that way.

Exit code is non-zero if any dump, tar, or peer-copy step failed; the log says which. On full
success, BACKUP_DIR/last_ok is updated with the current UTC timestamp.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "backup.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

resolve_config(){
  # Same precedence as firewall.sh/node_bootstrap.sh: explicit env var (captured BEFORE sourcing
  # the file, since sourcing would otherwise silently clobber a one-off override) > config file
  # > built-in default.
  local _env_dir="${BACKUP_DIR:-}" _env_ret="${RETENTION_DAYS:-}" _env_vol="${VOLUMES:-}" \
        _env_paths="${PATHS:-}" _env_excl="${BACKUP_EXCLUDE:-}" _env_peer="${PEER:-}" \
        _env_key="${PEER_KEY:-}"

  if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi

  BACKUP_DIR="${_env_dir:-${BACKUP_DIR:-/root/backups}}"
  RETENTION_DAYS="${_env_ret:-${RETENTION_DAYS:-7}}"
  VOLUMES="${_env_vol:-${VOLUMES:-}}"
  PATHS="${_env_paths:-${PATHS:-}}"
  BACKUP_EXCLUDE="${_env_excl:-${BACKUP_EXCLUDE:-n8nEventLog* crash.journal *.sock}}"
  PEER="${_env_peer:-${PEER:-}}"
  PEER_KEY="${_env_key:-${PEER_KEY:-/root/.ssh/vps-clone-backup}}"

  case "$RETENTION_DAYS" in
    ''|*[!0-9]*) log "invalid RETENTION_DAYS '$RETENTION_DAYS', falling back to 7"; RETENTION_DAYS=7 ;;
  esac
}

sanitize_name(){
  # docker container name -> safe filename fragment: drop the leading "/" docker inspect adds,
  # strip a swarm task suffix (stack_service.REPLICA.TASKID), replace anything else unsafe.
  local n="${1#/}"
  n=$(printf '%s' "$n" | sed -E 's/\.[0-9]+\.[a-z0-9]{25}$//')
  printf '%s' "$n" | tr -c 'A-Za-z0-9._-' '_'
}

dump_one(){
  # dump_one ENGINE CONTAINER OUTBASE -> writes OUTBASE.<ext>.gz on success. Returns 1 on failure
  # (and logs why); never uses -e-fatal constructs internally so the caller keeps going.
  local engine="$1" c="$2" base="$3" ext=sql
  case "$engine" in mongo) ext=archive ;; redis) ext=rdb ;; esac
  local out="${base}.${ext}.gz" tmp="${base}.${ext}.gz.tmp" errfile="${base}.err"

  case "$engine" in
    postgres)
      if ! { docker exec "$c" sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' 2>"$errfile" | gzip -6 >"$tmp"; }; then
        log "FAIL: postgres dump of $c: $(tail -n1 "$errfile" 2>/dev/null)"
        rm -f "$tmp"; return 1
      fi
      ;;
    mysql)
      if ! { docker exec "$c" sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" mysqldump -uroot --all-databases --single-transaction --routines --events --triggers --set-gtid-purged=OFF' 2>"$errfile" | gzip -6 >"$tmp"; }; then
        log "FAIL: mysql dump of $c: $(tail -n1 "$errfile" 2>/dev/null)"
        rm -f "$tmp"; return 1
      fi
      ;;
    mongo)
      if ! { docker exec "$c" sh -c 'mongodump --archive' 2>"$errfile" | gzip -6 >"$tmp"; }; then
        log "FAIL: mongo dump of $c: $(tail -n1 "$errfile" 2>/dev/null)"
        rm -f "$tmp"; return 1
      fi
      ;;
    redis)
      # REDISCLI_AUTH (an env var, read by redis-cli itself) keeps the password out of argv
      # entirely -- unlike `-a "$REDIS_PASSWORD"`, which would show up in that container's own
      # `ps`/`docker top` output and (via the word-split "$R" trick this replaces) broke on a
      # password containing whitespace or shell metacharacters.
      if ! { docker exec "$c" sh -c '
        export REDISCLI_AUTH="${REDIS_PASSWORD:-}"
        redis-cli --no-auth-warning BGSAVE >/dev/null 2>&1 || redis-cli --no-auth-warning SAVE >/dev/null 2>&1 || exit 1
        prev=$(redis-cli --no-auth-warning LASTSAVE 2>/dev/null)
        i=0
        timed_out=1
        while [ "$i" -lt 60 ]; do
          now=$(redis-cli --no-auth-warning LASTSAVE 2>/dev/null)
          if [ "$now" != "$prev" ]; then timed_out=0; break; fi
          sleep 1
          i=$((i + 1))
        done
        [ "$timed_out" -eq 1 ] && echo "WARN: save did not complete within 60s, copying dump.rdb as-is (may be stale)" >&2
        dir=$(redis-cli --no-auth-warning CONFIG GET dir 2>/dev/null | tail -n1)
        file=$(redis-cli --no-auth-warning CONFIG GET dbfilename 2>/dev/null | tail -n1)
        cat "$dir/${file:-dump.rdb}"
      ' 2>"$errfile" | gzip -6 >"$tmp"; }; then
        log "FAIL: redis dump of $c: $(tail -n1 "$errfile" 2>/dev/null)"
        rm -f "$tmp"; return 1
      fi
      if [ -s "$errfile" ]; then
        log "WARN: redis dump of $c: $(tail -n1 "$errfile")"
      fi
      ;;
    *)
      return 1
      ;;
  esac

  if ! gzip -t "$tmp" 2>"$errfile"; then
    log "FAIL: $engine dump of $c: corrupt gzip output ($(tail -n1 "$errfile" 2>/dev/null))"
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$out"
  rm -f "$errfile"
  local size
  size=$(wc -c <"$out" 2>/dev/null | tr -d ' ')
  if [ "${size:-0}" -lt 100 ]; then
    log "WARN: $out is only ${size:-0} bytes - looks suspiciously empty, verify manually (lesson: always check dump size, not just gzip -t)"
  fi
  log "ok: $out ($(du -h "$out" 2>/dev/null | cut -f1))"
  return 0
}

dump_databases(){
  if ! has docker; then
    log "docker not found, skipping database dumps"
    return 0
  fi
  local failed=0 cname cimage engine svc ps_out
  # Capture via command substitution (not `< <(docker ps ...)`): a process substitution's exit
  # status is invisible to the `while` loop that reads it, so a failing `docker ps` (daemon down/
  # unreachable while the CLI itself is present) would otherwise look like "zero containers" and
  # this function would silently return 0, skipping every dump without ever reporting a failure.
  if ! ps_out=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>&1); then
    log "FAIL: docker ps: $(printf '%s' "$ps_out" | tail -n1)"
    return 1
  fi
  while IFS=$'\t' read -r cname cimage; do
    [ -n "$cname" ] || continue
    engine=""
    case "$cimage" in
      *postgres*|*postgis*|*timescale*) engine=postgres ;;
      *percona*|*mariadb*|*mysql*) engine=mysql ;;
      *mongo*) engine=mongo ;;
      *redis*|*valkey*|*keydb*) engine=redis ;;
      *) continue ;;
    esac
    svc=$(sanitize_name "$cname")
    dump_one "$engine" "$cname" "$LOCAL_DIR/${svc}_${engine}_${TS}" || failed=1
  done <<< "$ps_out"
  return "$failed"
}

tar_set(){
  # tar_set NAME LIST_VAR_VALUE -> LOCAL_DIR/NAME_TS.tgz containing each entry of the
  # space-separated list (docker volume name, resolved via `docker volume inspect`, when
  # NAME=volumes; a plain host path otherwise), honoring BACKUP_EXCLUDE.
  local name="$1" list="$2"
  [ -n "$list" ] || return 0
  local out="$LOCAL_DIR/${name}_${TS}.tgz" tmp errfile
  tmp="${out}.tmp"
  errfile="$LOCAL_DIR/.${name}_${TS}.err"
  local -a targs=() excl_arr=() item_arr=()
  read -ra excl_arr <<< "$BACKUP_EXCLUDE"
  local e; for e in "${excl_arr[@]}"; do targs+=(--exclude="$e"); done
  read -ra item_arr <<< "$list"
  local it mp
  for it in "${item_arr[@]}"; do
    if [ "$name" = volumes ]; then
      if ! has docker; then log "FAIL: VOLUMES configured but docker not found"; return 1; fi
      mp=$(docker volume inspect -f '{{.Mountpoint}}' "$it" 2>/dev/null) || { log "FAIL: docker volume '$it' not found"; return 1; }
      [ -e "$mp" ] || { log "FAIL: $name entry '$it' ($mp) does not exist on this host"; return 1; }
      # Every Docker named volume's mountpoint ends in ".../<name>/_data" - its basename is
      # literally "_data" for every volume. Storing just that basename (as this used to do) makes
      # two or more VOLUMES collide into one identically-named tar member, silently merging their
      # contents on restore. Go up one extra level and keep "<name>/_data" as the member path so
      # each volume stays distinct; the documented `-C /var/lib/docker/volumes` restore still works.
      targs+=(-C "$(dirname "$(dirname "$mp")")" "$it/$(basename "$mp")")
    else
      mp="$it"
      case "$mp" in
        /*) : ;;
        *) log "FAIL: $name entry '$it' must be an absolute path"; return 1 ;;
      esac
      [ -e "$mp" ] || { log "FAIL: $name entry '$it' does not exist on this host"; return 1; }
      # Store the full absolute path (tar drops the leading "/") instead of just its basename, so
      # the documented `tar xzf paths_TS.tgz -C /` restore recreates it at its original location;
      # a basename-only member (the old behavior) restores to the wrong place every time, and two
      # PATHS entries that happen to share a basename (e.g. two services each with a "config" dir)
      # would collide into one tar member.
      targs+=("$mp")
    fi
  done
  if tar czf "$tmp" "${targs[@]}" 2>"$errfile"; then
    mv "$tmp" "$out"
    rm -f "$errfile"
    log "ok: $out ($(du -h "$out" 2>/dev/null | cut -f1))"
    return 0
  fi
  log "FAIL: $name tar: $(tail -n1 "$errfile" 2>/dev/null)"
  rm -f "$tmp"
  return 1
}

sync_peer(){
  [ -n "${PEER:-}" ] || return 0
  if ! has ssh; then
    log "FAIL: PEER configured but ssh not found"
    return 1
  fi
  local -a sshopts=(-i "$PEER_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
  local remote_dir
  remote_dir="$BACKUP_DIR/from-$(hostname)"
  local remote_has_rsync=1
  if has rsync && ssh "${sshopts[@]}" "$PEER" 'command -v rsync >/dev/null 2>&1' 2>/dev/null; then
    remote_has_rsync=0
  fi
  if [ "$remote_has_rsync" -eq 0 ]; then
    if rsync -a --delete -e "ssh ${sshopts[*]}" "$LOCAL_DIR"/ "$PEER:$remote_dir/" 2>"$LOCAL_DIR/.peer.err"; then
      log "ok: synced to $PEER:$remote_dir via rsync"
      rm -f "$LOCAL_DIR/.peer.err"
      return 0
    fi
    log "FAIL: rsync to $PEER: $(tail -n1 "$LOCAL_DIR/.peer.err" 2>/dev/null)"
    return 1
  fi
  log "rsync unavailable locally or on $PEER, falling back to tar over ssh (stale files on the peer are not pruned in this mode)"
  if ssh "${sshopts[@]}" "$PEER" "mkdir -p '$remote_dir'" 2>"$LOCAL_DIR/.peer.err" \
     && tar cf - -C "$LOCAL_DIR" . | ssh "${sshopts[@]}" "$PEER" "tar xf - -C '$remote_dir'" 2>>"$LOCAL_DIR/.peer.err"; then
    log "ok: synced to $PEER:$remote_dir via tar+ssh"
    rm -f "$LOCAL_DIR/.peer.err"
    return 0
  fi
  log "FAIL: tar+ssh fallback sync to $PEER: $(tail -n1 "$LOCAL_DIR/.peer.err" 2>/dev/null)"
  return 1
}

do_backup(){
  need_root
  resolve_config
  LOCAL_DIR="$BACKUP_DIR/local"
  mkdir -p "$LOCAL_DIR"
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  local failed=0

  dump_databases || failed=1
  tar_set volumes "$VOLUMES" || failed=1
  tar_set paths "$PATHS" || failed=1

  local keep_mtime=$((RETENTION_DAYS > 0 ? RETENTION_DAYS - 1 : 0))
  find "$LOCAL_DIR" -maxdepth 1 -type f -mtime "+$keep_mtime" -print -delete 2>/dev/null || true

  sync_peer || failed=1

  if [ "$failed" -eq 0 ]; then
    date -u +%FT%TZ > "$BACKUP_DIR/last_ok"
    log "backup complete, all steps ok"
    exit 0
  fi
  log "backup FINISHED WITH FAILURES (see FAIL lines above) - last_ok was NOT updated"
  exit 1
}

do_backup
