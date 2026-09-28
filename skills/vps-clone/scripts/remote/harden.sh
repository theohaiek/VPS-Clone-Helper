#!/usr/bin/env bash
# harden.sh - a-la-carte hardening for one vps-clone node. Every flag is independent, optional,
# and safe to re-run (idempotent). Run it once per flag you want, or all at once.
#
# Usage examples (from the controller, over SSH, after --put-tree copied the scripts):
#   sshx.py tgt1 'bash /root/vps-clone/scripts/harden.sh --ssh-keys-only --swap 2G --swappiness 10'
#   sshx.py tgt1 'bash /root/vps-clone/scripts/harden.sh --docker-logs --firewall'
set -euo pipefail

log(){ echo "[harden $(hostname) $(date -u +%H:%M:%S)] $*"; }
has(){ command -v "$1" >/dev/null 2>&1; }
is_flagish(){ case "$1" in -*) return 0 ;; *) return 1 ;; esac; }

INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/vps-clone-firewall}"

SCRIPT_DIR=""
if [ -f "$0" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
fi

usage(){
  cat <<'EOF'
Usage: harden.sh [FLAGS]

Every flag below is independent and optional; combine as many as you want in one run.
Re-running with the same flags is always safe.

  --ssh-keys-only             Disable SSH password auth (key-only login). Refuses (does nothing)
                               unless /root/.ssh/authorized_keys, or $SUDO_USER's, already has at
                               least one key -- this is a lockout guard. Writes
                               /etc/ssh/sshd_config.d/10-vps-clone.conf, validates with
                               `sshd -t` (reverting on failure) before reloading sshd.

  --swap SIZE                 Create and enable a swap file if none is active yet (e.g. 2G,
                               512M). Uses fallocate, falls back to dd if unsupported. Adds it to
                               /etc/fstab once.

  --swappiness N               Set vm.swappiness (0-100) via /etc/sysctl.d/99-vps-clone.conf.

  --docker-logs [SIZE:COUNT]   Merge Docker's json-file log rotation into /etc/docker/daemon.json
                               (default SIZE:COUNT is 50m:3), keeping every other key already in
                               that file. Restarts docker only if the file actually changed, waits
                               for it to come back, then re-applies the persistent firewall if one
                               was installed (see --firewall / firewall.sh --install) -- a plain
                               restart does not need the "docker service update --force -d" fix
                               that upgrades sometimes do, but after any docker restart on a swarm
                               node it is worth confirming services came back:  docker service ls

  --firewall                    Install and apply the persistent host firewall by running
                               firewall.sh --install (must be next to this script on disk).

  --unattended-upgrades         Install and enable unattended-upgrades (security updates only).
                               Automatic reboot is explicitly left OFF.

  --portainer-agent-fix [SERVICE]
                               Only if this node is a swarm manager: install
                               /etc/cron.d/vps-clone-portainer-agent to force-update the agent
                               service (default: portainer_agent) 180s after every reboot,
                               because Portainer agents can otherwise form a split cluster after
                               a reboot or docker restart.

  -h, --help                    Show this help.

Must run as root. Every value comes from a flag (or, for --docker-logs/--portainer-agent-fix,
its own built-in default); nothing here is hardcoded to a specific server.
EOF
}

need_root(){
  [ "$(id -u)" = 0 ] || { echo "harden.sh: must run as root" >&2; exit 1; }
}

count_keys(){
  # Prints the number of non-blank, non-comment lines in an authorized_keys file (0 if missing
  # or empty). `grep -c` already prints "0" on a zero-match file but exits 1, so the fallback
  # must not print a second "0" on top of it -- only cover the case where grep prints nothing.
  [ -f "$1" ] || { echo 0; return 0; }
  local n
  n=$(grep -cvE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true)
  if [ -n "$n" ]; then printf '%s\n' "$n"; else echo 0; fi
}

do_ssh_keys_only(){
  local root_keys=0 sudo_keys=0 total home
  root_keys=$(count_keys /root/.ssh/authorized_keys)
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
    [ -n "$home" ] && sudo_keys=$(count_keys "$home/.ssh/authorized_keys")
  fi
  total=$((root_keys + sudo_keys))
  if [ "$total" -lt 1 ]; then
    echo "harden.sh: refusing --ssh-keys-only: no key in /root/.ssh/authorized_keys or \$SUDO_USER's (lockout guard). Add a public key first." >&2
    exit 1
  fi
  log "ssh key lockout guard passed: root=$root_keys sudo_user=$sudo_keys"

  local conf=/etc/ssh/sshd_config.d/10-vps-clone.conf backup=""
  mkdir -p /etc/ssh/sshd_config.d
  if [ -f "$conf" ]; then
    backup="$(mktemp)"
    cp "$conf" "$backup"
  fi
  cat > "$conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if ! sshd -t; then
    if [ -n "$backup" ]; then cp "$backup" "$conf"; else rm -f "$conf"; fi
    [ -n "$backup" ] && rm -f "$backup"
    echo "harden.sh: sshd -t rejected the new config, reverted $conf" >&2
    exit 1
  fi
  [ -n "$backup" ] && rm -f "$backup"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  sshd -T | grep -E '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication) ' || true
  log "sshd: key-only auth enforced"
}

validate_swap_size(){
  case "$1" in
    [0-9]*[GgMm]) : ;;
    *) echo "harden.sh: bad --swap size '$1' (use e.g. 2G or 512M)" >&2; exit 1 ;;
  esac
}

size_to_mb(){
  local s="$1" num suffix
  case "$s" in
    *[Gg]) suffix=G; num="${s%[Gg]}" ;;
    *[Mm]) suffix=M; num="${s%[Mm]}" ;;
  esac
  case "$num" in
    ''|*[!0-9]*) echo "harden.sh: bad --swap size '$s'" >&2; exit 1 ;;
  esac
  if [ "$suffix" = G ]; then
    echo $((num * 1024))
  else
    echo "$num"
  fi
}

do_swap(){
  local size="$1" file=/swapfile
  validate_swap_size "$size"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$file"; then
    log "swap already active: $file"
  else
    if [ ! -f "$file" ]; then
      log "creating swap file $file ($size)"
      if ! fallocate -l "$size" "$file" 2>/dev/null; then
        log "fallocate unsupported here, falling back to dd"
        rm -f "$file"
        dd if=/dev/zero of="$file" bs=1M count="$(size_to_mb "$size")" status=none
      fi
    fi
    chmod 600 "$file"
    mkswap "$file" >/dev/null
    swapon "$file"
    log "swap enabled: $file"
  fi
  if ! grep -q "^$file " /etc/fstab 2>/dev/null; then
    echo "$file none swap sw 0 0" >> /etc/fstab
    log "added $file to /etc/fstab"
  fi
  swapon --show
}

do_swappiness(){
  local n="$1" f=/etc/sysctl.d/99-vps-clone.conf
  case "$n" in
    ''|*[!0-9]*) echo "harden.sh: --swappiness wants an integer 0-100, got '$n'" >&2; exit 1 ;;
  esac
  if [ "$n" -gt 100 ]; then
    echo "harden.sh: --swappiness wants an integer 0-100, got '$n'" >&2
    exit 1
  fi
  mkdir -p /etc/sysctl.d
  if [ -f "$f" ] && [ "$(cat "$f")" = "vm.swappiness=$n" ]; then
    log "swappiness already $n"
  else
    echo "vm.swappiness=$n" > "$f"
    sysctl -q -p "$f"
    log "swappiness set to $n"
  fi
}

do_firewall_install(){
  local fw="$SCRIPT_DIR/firewall.sh"
  if [ -z "$SCRIPT_DIR" ] || [ ! -f "$fw" ]; then
    echo "harden.sh: --firewall needs firewall.sh next to this script on disk (this run was piped via stdin, or the file is elsewhere)." >&2
    echo "Copy the scripts to the host first, then run: bash /root/vps-clone/scripts/firewall.sh --install" >&2
    return 0
  fi
  log "installing the persistent firewall via $fw --install"
  bash "$fw" --install
}

wait_for_docker(){
  local _i
  for _i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "harden.sh: docker did not come back up after restart" >&2
  return 1
}

reapply_firewall_if_installed(){
  if [ -x "$INSTALL_PATH" ]; then
    log "re-applying the persisted firewall: $INSTALL_PATH"
    "$INSTALL_PATH" || echo "harden.sh: warning: $INSTALL_PATH exited non-zero" >&2
  fi
}

do_docker_logs(){
  local sizecount="$1" max_size max_file before after
  case "$sizecount" in
    *:*) : ;;
    *) echo "harden.sh: --docker-logs wants SIZE:COUNT (e.g. 50m:3), got '$sizecount'" >&2; exit 1 ;;
  esac
  max_size="${sizecount%%:*}"
  max_file="${sizecount#*:}"
  has python3 || has jq || { echo "harden.sh: --docker-logs needs python3 or jq to merge /etc/docker/daemon.json safely" >&2; exit 1; }

  mkdir -p /etc/docker
  [ -f /etc/docker/daemon.json ] || printf '{}\n' > /etc/docker/daemon.json
  before="$(cat /etc/docker/daemon.json)"

  if has python3; then
    python3 - "$max_size" "$max_file" <<'PYEOF'
import json
import sys

max_size, max_file = sys.argv[1], sys.argv[2]
path = "/etc/docker/daemon.json"

try:
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read().strip()
    data = json.loads(raw) if raw else {}
except json.JSONDecodeError as e:
    sys.stderr.write(f"harden.sh: {path} is not valid JSON ({e}); refusing to merge (would drop its keys) - fix it by hand first\n")
    sys.exit(1)
except OSError:
    data = {}
if not isinstance(data, dict):
    sys.stderr.write(f"harden.sh: {path} top level is not a JSON object; refusing to merge - fix it by hand first\n")
    sys.exit(1)

data["log-driver"] = "json-file"
opts = data.get("log-opts")
if not isinstance(opts, dict):
    opts = {}
opts["max-size"] = max_size
opts["max-file"] = str(max_file)
data["log-opts"] = opts

with open(path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PYEOF
  else
    local tmp
    tmp="$(mktemp /etc/docker/daemon.json.XXXXXX)"
    if ! jq --arg size "$max_size" --arg file "$max_file" \
         '.["log-driver"] = "json-file"
          | .["log-opts"] = ((if (.["log-opts"] | type) == "object" then .["log-opts"] else {} end)
                              + {"max-size": $size, "max-file": $file})' \
         /etc/docker/daemon.json > "$tmp"; then
      rm -f "$tmp"
      echo "harden.sh: jq failed to merge /etc/docker/daemon.json" >&2
      exit 1
    fi
    chmod 644 "$tmp"
    mv "$tmp" /etc/docker/daemon.json
  fi

  after="$(cat /etc/docker/daemon.json)"
  if [ "$before" = "$after" ]; then
    log "docker log rotation already $max_size:$max_file, no restart needed"
  else
    log "docker log rotation set to $max_size:$max_file, restarting docker"
    systemctl restart docker
    wait_for_docker
    log "docker is back up -- verify swarm services: docker service ls (run on a manager; check for name-resolution errors in app logs too)"
  fi
  reapply_firewall_if_installed
}

do_unattended_upgrades(){
  has apt-get || { echo "harden.sh: --unattended-upgrades needs apt-get (Debian/Ubuntu)" >&2; exit 1; }
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    log "installing unattended-upgrades"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null
  fi
  mkdir -p /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
    sed -i 's#^\([[:space:]]*\)\(//[[:space:]]*\)\{0,1\}Unattended-Upgrade::Automatic-Reboot\([[:space:]].*\)$#\1Unattended-Upgrade::Automatic-Reboot "false";#' /etc/apt/apt.conf.d/50unattended-upgrades
  fi
  systemctl enable --now unattended-upgrades
  log "unattended-upgrades installed and enabled, automatic reboot left OFF"
}

do_portainer_agent_fix(){
  local svc="$1" manager
  if ! has docker; then
    log "portainer-agent-fix: docker not found, skipping"
    return 0
  fi
  manager="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo false)"
  if [ "$manager" != true ]; then
    log "portainer-agent-fix: not a swarm manager, skipping (install this once, from a manager)"
    return 0
  fi
  mkdir -p /etc/cron.d
  printf '@reboot root sleep 180 && docker service update --force -d %s >/dev/null 2>&1\n' "$svc" > /etc/cron.d/vps-clone-portainer-agent
  chmod 644 /etc/cron.d/vps-clone-portainer-agent
  log "portainer-agent-fix installed for service '$svc' (fires 180s after every reboot)"
}

DO_SSH_KEYS_ONLY=0
SWAP_SIZE=""
SWAPPINESS=""
DOCKER_LOGS=""
DO_FIREWALL=0
DO_UNATTENDED=0
PORTAINER_FIX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-keys-only) DO_SSH_KEYS_ONLY=1; shift ;;
    --swap) SWAP_SIZE="${2:?--swap needs a size, e.g. --swap 2G}"; shift 2 ;;
    --swap=*) SWAP_SIZE="${1#*=}"; shift ;;
    --swappiness) SWAPPINESS="${2:?--swappiness needs a number 0-100}"; shift 2 ;;
    --swappiness=*) SWAPPINESS="${1#*=}"; shift ;;
    --docker-logs)
      if [ $# -ge 2 ] && ! is_flagish "$2"; then DOCKER_LOGS="$2"; shift 2; else DOCKER_LOGS="50m:3"; shift; fi
      ;;
    --docker-logs=*) DOCKER_LOGS="${1#*=}"; shift ;;
    --firewall) DO_FIREWALL=1; shift ;;
    --unattended-upgrades) DO_UNATTENDED=1; shift ;;
    --portainer-agent-fix)
      if [ $# -ge 2 ] && ! is_flagish "$2"; then PORTAINER_FIX="$2"; shift 2; else PORTAINER_FIX="portainer_agent"; shift; fi
      ;;
    --portainer-agent-fix=*) PORTAINER_FIX="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "harden.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

need_root

DID=0
[ "$DO_SSH_KEYS_ONLY" = 1 ] && { do_ssh_keys_only; DID=1; }
[ -n "$SWAP_SIZE" ] && { do_swap "$SWAP_SIZE"; DID=1; }
[ -n "$SWAPPINESS" ] && { do_swappiness "$SWAPPINESS"; DID=1; }
[ "$DO_FIREWALL" = 1 ] && { do_firewall_install; DID=1; }
[ -n "$DOCKER_LOGS" ] && { do_docker_logs "$DOCKER_LOGS"; DID=1; }
[ "$DO_UNATTENDED" = 1 ] && { do_unattended_upgrades; DID=1; }
[ -n "$PORTAINER_FIX" ] && { do_portainer_agent_fix "$PORTAINER_FIX"; DID=1; }

if [ "$DID" = 0 ]; then
  echo "harden.sh: no flags given, nothing to do (see -h)"
  exit 0
fi
log "done"
