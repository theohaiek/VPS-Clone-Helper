#!/usr/bin/env bash
# backup_install.sh - installs backup.sh as a daily cron job on this host: an ssh keypair
# dedicated to peer sync, the cron entry, logrotate for its log file, and (only if it does not
# exist yet) a starter /etc/vps-clone/backup.env. Idempotent: safe to re-run.
#
# Usage: backup_install.sh [--time HH:MM] [--peer root@IP]
#
#   --time HH:MM   UTC time of day the cron job runs at (default: 03:00)
#   --peer root@IP root@ip of the peer node to write into a FRESH backup.env's PEER= line.
#                  Only takes effect the first time this runs on a host (see below); on a host
#                  that already has /etc/vps-clone/backup.env, edit PEER= in that file by hand.
#
# What this prints:
#   PUBKEY=<the raw ed25519 public key>
#   plus a ready-to-paste authorized_keys line, restricted to this host's IP and to no
#   port/X11/agent forwarding and no pty - add that line to the PEER's
#   /root/.ssh/authorized_keys so this host can push backups to it without a password.
set -euo pipefail

log(){ echo "[backup-install $(hostname) $(date -u +%H:%M:%S)] $*"; }
has(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "backup_install.sh: must run as root" >&2; exit 1; }; }

KEY="${KEY:-/root/.ssh/vps-clone-backup}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/vps-clone-backup}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/vps-clone-backup}"
LOG_FILE="${LOG_FILE:-/var/log/vps-clone-backup.log}"
ENV_FILE="${ENV_FILE:-/etc/vps-clone/backup.env}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-/root/vps-clone/scripts/remote/backup.sh}"

usage(){
  cat <<'EOF'
Usage: backup_install.sh [--time HH:MM] [--peer root@IP]

Installs backup.sh (expected at /root/vps-clone/scripts/remote/backup.sh - deploy the repo's
scripts/ tree there first, e.g. sshx.py <alias> --put-tree skills/vps-clone/scripts /root/vps-clone/scripts)
as a daily cron job:
  - generates an ed25519 keypair at /root/.ssh/vps-clone-backup (once; reused on every re-run)
  - writes /etc/cron.d/vps-clone-backup running backup.sh at --time (UTC), logging to
    /var/log/vps-clone-backup.log
  - writes /etc/logrotate.d/vps-clone-backup for that log file
  - writes a starter /etc/vps-clone/backup.env ONLY if that file does not already exist (never
    overwrites an existing config, so hand edits survive re-runs)

  --time HH:MM    24h UTC time of day to run the backup (default: 03:00)
  --peer root@IP  baked into the PEER= line of a freshly created backup.env; ignored (with a
                  note) if backup.env already exists on this host

Prints PUBKEY=<key> and a ready-to-paste restricted authorized_keys line. Add that line to
/root/.ssh/authorized_keys on the peer so this host can rsync/ssh backups there unattended.
EOF
}

TIME=03:00
PEER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --time) [ $# -ge 2 ] || { echo "backup_install.sh: --time needs a value, e.g. --time 03:00" >&2; exit 2; }; TIME=$2; shift 2 ;;
    --time=*) TIME=${1#*=}; shift ;;
    --peer) [ $# -ge 2 ] || { echo "backup_install.sh: --peer needs a value, e.g. --peer root@198.51.100.21" >&2; exit 2; }; PEER=$2; shift 2 ;;
    --peer=*) PEER=${1#*=}; shift ;;
    *) echo "backup_install.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $TIME =~ ^([0-1][0-9]|2[0-3]):([0-5][0-9])$ ]] || {
  echo "backup_install.sh: --time must be HH:MM in 24h format, got '$TIME'" >&2
  exit 2
}
HOUR=${BASH_REMATCH[1]}
MIN=${BASH_REMATCH[2]}

need_root

if [ ! -f "$KEY" ]; then
  mkdir -p "$(dirname "$KEY")"
  chmod 700 "$(dirname "$KEY")"
  ssh-keygen -q -t ed25519 -N '' -C "vps-clone-backup-$(hostname)" -f "$KEY"
  log "generated new peer-sync keypair at $KEY"
else
  log "peer-sync keypair already exists at $KEY, reusing it"
fi
chmod 600 "$KEY"
chmod 644 "$KEY.pub"

mkdir -p "$(dirname "$ENV_FILE")"
if [ -f "$ENV_FILE" ]; then
  log "$ENV_FILE already exists, leaving it untouched"
  if [ -n "$PEER" ]; then
    log "note: --peer was given but is ignored on an existing config; set PEER=\"$PEER\" in $ENV_FILE by hand if you want it"
  fi
else
  cat > "$ENV_FILE" <<EOF
# vps-clone backup config - read by backup.sh on every run. Edit freely; no re-install needed.
BACKUP_DIR=/root/backups
RETENTION_DAYS=7
VOLUMES=""
PATHS=""
BACKUP_EXCLUDE="n8nEventLog* crash.journal *.sock"
PEER="$PEER"
PEER_KEY=$KEY
EOF
  chmod 600 "$ENV_FILE"
  log "wrote starter $ENV_FILE"
fi

cat > "$CRON_FILE" <<EOF
# Written by vps-clone-helper backup_install.sh. Edit --time by re-running the installer, not
# this file directly (a plain edit survives until the next --time change but won't be re-applied).
$MIN $HOUR * * * root $BACKUP_SCRIPT >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"
log "cron entry written: daily at ${TIME} UTC -> $CRON_FILE"

cat > "$LOGROTATE_FILE" <<EOF
$LOG_FILE {
  weekly
  rotate 8
  compress
  missingok
  notifempty
}
EOF
log "logrotate config written -> $LOGROTATE_FILE"

if [ ! -x "$BACKUP_SCRIPT" ]; then
  log "WARNING: $BACKUP_SCRIPT not found yet (or not executable) - the cron job will fail until it is deployed there"
fi

log "PUBKEY=$(cat "$KEY.pub")"
SRC_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || true)
if [ -z "$SRC_IP" ]; then
  SRC_IP="<this-host-ip>"
  log "WARNING: could not determine this host's public IP (outbound curl failed) - the line below"
  log "WARNING: has a literal '<this-host-ip>' placeholder; replace it with the real IP by hand"
  log "WARNING: before pasting, or the from=\"...\" restriction will never match and lock this out"
fi
log "authorize on the peer (append to its /root/.ssh/authorized_keys):"
echo "from=\"$SRC_IP\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $(cat "$KEY.pub")"
