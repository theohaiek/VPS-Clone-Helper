#!/usr/bin/env bash
# node_bootstrap.sh - prepare one already-provisioned Debian/Ubuntu host: hostname, base
# packages, sysctl, optional docker swarm init/join, networks, volumes, node labels.
# Idempotent: safe to re-run, including to just re-print swarm join tokens.
#
# Usage:
#   node_bootstrap.sh --hostname NAME [--timezone TZ] [--sysctl 'k=v,k=v'] [--packages 'a b c']
#                      [--swarm-init ADVERTISE_IP | --swarm-join MANAGER_IP:2377 --token TOKEN]
#                      [--network NAME[:overlay-attachable]]... [--volume NAME]...
#                      [--label KEY=VALUE]...
#
# Run docker_install.sh first if this host needs Docker: the swarm/network/volume/label
# steps below fail with a clear message if the docker daemon isn't present.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log(){ echo "[node-bootstrap $(hostname) $(date -u +%H:%M:%S)] $*"; }
fail(){ echo "[node-bootstrap $(hostname) $(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

usage(){
  cat <<'EOF'
Usage: node_bootstrap.sh --hostname NAME [options]

  --hostname NAME             set hostname + /etc/hosts (required)
  --timezone TZ                timedatectl set-timezone TZ (default: UTC)
  --sysctl 'k=v,k=v'           written to /etc/sysctl.d/90-vps-clone.conf (never appends to
                                /etc/sysctl.conf -- installers that do that end up with the
                                same line duplicated dozens of times), applied with sysctl -p
  --packages 'a b c'           extra apt packages on top of the base set
  --swarm-init ADVERTISE_IP    docker swarm init on this node, advertising ADVERTISE_IP.
                                ADVERTISE_IP is required explicitly, never auto-detected:
                                cloud hosts are usually multi-homed (private net, public IP,
                                a metadata-service address) and Docker's own auto-pick is
                                often the wrong interface. Prints JOIN_TOKEN_WORKER=... and
                                JOIN_TOKEN_MANAGER=... (also reprinted on a re-run, even
                                when the node was already a manager, so you can fetch fresh
                                tokens without re-provisioning).
  --swarm-join MANAGER_IP:2377 --token TOKEN
                                docker swarm join this node to an existing swarm.
  --network NAME[:overlay-attachable]
                                create a docker network if missing (repeatable). Without the
                                suffix, driver defaults to overlay+attachable when this node
                                currently has swarm active, else bridge. Overlay networks can
                                only be created on a swarm manager.
  --volume NAME                 create a local docker volume if missing (repeatable)
  --label KEY=VALUE              docker node label, applied only if this node is currently a
                                swarm manager (repeatable, e.g. --label node.role=db)
  -h, --help                    this text

Exit codes: 0 ok, 1 bad usage / docker required but missing.
Idempotent: safe to re-run with the same, fewer, or additional flags.
EOF
}

HOSTNAME_ARG=""
TIMEZONE=UTC
SYSCTL_ARG=""
PACKAGES_ARG=""
SWARM_INIT_IP=""
SWARM_JOIN_ADDR=""
SWARM_TOKEN=""
NETWORKS=()
VOLUMES=()
LABELS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)
      [ $# -ge 2 ] || { usage >&2; fail "--hostname needs a value"; }
      HOSTNAME_ARG=$2; shift 2 ;;
    --timezone)
      [ $# -ge 2 ] || { usage >&2; fail "--timezone needs a value"; }
      TIMEZONE=$2; shift 2 ;;
    --sysctl)
      [ $# -ge 2 ] || { usage >&2; fail "--sysctl needs a value"; }
      SYSCTL_ARG=$2; shift 2 ;;
    --packages)
      [ $# -ge 2 ] || { usage >&2; fail "--packages needs a value"; }
      PACKAGES_ARG=$2; shift 2 ;;
    --swarm-init)
      [ $# -ge 2 ] || { usage >&2; fail "--swarm-init needs an advertise IP"; }
      SWARM_INIT_IP=$2; shift 2 ;;
    --swarm-join)
      [ $# -ge 2 ] || { usage >&2; fail "--swarm-join needs MANAGER_IP:2377"; }
      SWARM_JOIN_ADDR=$2; shift 2 ;;
    --token)
      [ $# -ge 2 ] || { usage >&2; fail "--token needs a value"; }
      SWARM_TOKEN=$2; shift 2 ;;
    --network)
      [ $# -ge 2 ] || { usage >&2; fail "--network needs NAME[:overlay-attachable]"; }
      NETWORKS+=("$2"); shift 2 ;;
    --volume)
      [ $# -ge 2 ] || { usage >&2; fail "--volume needs a value"; }
      VOLUMES+=("$2"); shift 2 ;;
    --label)
      [ $# -ge 2 ] || { usage >&2; fail "--label needs KEY=VALUE"; }
      LABELS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

if [ -z "$HOSTNAME_ARG" ]; then usage >&2; fail "--hostname is required"; fi
if [ -n "$SWARM_INIT_IP" ] && [ -n "$SWARM_JOIN_ADDR" ]; then
  fail "--swarm-init and --swarm-join are mutually exclusive"
fi
if [ -n "$SWARM_JOIN_ADDR" ] && [ -z "$SWARM_TOKEN" ]; then
  fail "--swarm-join requires --token"
fi

log "hostname=$HOSTNAME_ARG timezone=$TIMEZONE"
hostnamectl set-hostname "$HOSTNAME_ARG" || true
if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
  sed -i "s/^127\\.0\\.1\\.1[[:space:]].*/127.0.1.1 ${HOSTNAME_ARG} ${HOSTNAME_ARG}/" /etc/hosts
else
  echo "127.0.1.1 ${HOSTNAME_ARG} ${HOSTNAME_ARG}" >> /etc/hosts
fi

if [ -n "$TIMEZONE" ]; then
  timedatectl set-timezone "$TIMEZONE" || true
fi

log "base packages"
BASE_PACKAGES=(ca-certificates curl gnupg jq rsync)
# shellcheck disable=SC2206  # intentional word split: --packages takes a space-separated list
EXTRA_PACKAGES=($PACKAGES_ARG)
apt-get update -qq
apt-get install -y -qq "${BASE_PACKAGES[@]}" "${EXTRA_PACKAGES[@]}" >/dev/null

if [ -n "$SYSCTL_ARG" ]; then
  log "sysctl -> /etc/sysctl.d/90-vps-clone.conf"
  IFS=',' read -ra SYSCTL_PAIRS <<< "$SYSCTL_ARG"
  {
    echo "# managed by vps-clone node_bootstrap.sh -- re-run with --sysctl to change, do not hand-edit"
    for kv in "${SYSCTL_PAIRS[@]}"; do
      echo "$kv"
    done
  } > /etc/sysctl.d/90-vps-clone.conf
  sysctl -p /etc/sysctl.d/90-vps-clone.conf -q || true
fi

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1; then HAVE_DOCKER=1; fi

swarm_state(){ docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive; }
is_manager(){ [ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo false)" = true ]; }

NEEDS_DOCKER=0
if [ -n "$SWARM_INIT_IP" ] || [ -n "$SWARM_JOIN_ADDR" ] || [ "${#NETWORKS[@]}" -gt 0 ] \
   || [ "${#VOLUMES[@]}" -gt 0 ] || [ "${#LABELS[@]}" -gt 0 ]; then
  NEEDS_DOCKER=1
fi
if [ "$NEEDS_DOCKER" = 1 ] && [ "$HAVE_DOCKER" = 0 ]; then
  fail "docker is not installed -- run docker_install.sh first"
fi

if [ -n "$SWARM_INIT_IP" ]; then
  if [ "$(swarm_state)" = active ]; then
    log "swarm already active on this node, skipping init"
  else
    log "swarm init, advertise-addr=$SWARM_INIT_IP"
    docker swarm init --advertise-addr "$SWARM_INIT_IP" >/dev/null
  fi
  if is_manager; then
    echo "JOIN_TOKEN_WORKER=$(docker swarm join-token -q worker)"
    echo "JOIN_TOKEN_MANAGER=$(docker swarm join-token -q manager)"
  fi
fi

if [ -n "$SWARM_JOIN_ADDR" ]; then
  if [ "$(swarm_state)" = active ]; then
    log "swarm already active on this node, skipping join"
  else
    log "swarm join -> $SWARM_JOIN_ADDR"
    docker swarm join --token "$SWARM_TOKEN" "$SWARM_JOIN_ADDR" >/dev/null
  fi
fi

for spec in "${NETWORKS[@]:-}"; do
  [ -n "$spec" ] || continue
  NET_NAME=${spec%%:*}
  NET_MODE=""
  case "$spec" in
    *:*) NET_MODE=${spec#*:} ;;
  esac
  if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    log "network $NET_NAME already exists, skipping"
    continue
  fi
  DRIVER=""
  ATTACH=0
  case "$NET_MODE" in
    overlay-attachable) DRIVER=overlay; ATTACH=1 ;;
    "")
      # overlay networks can only be created on a manager; workers get them when a task lands there
      if is_manager; then DRIVER=overlay; ATTACH=1; else DRIVER=bridge; fi ;;
    *) fail "unknown network mode '$NET_MODE' for --network $spec (only ':overlay-attachable' is supported)" ;;
  esac
  log "creating network $NET_NAME (driver=$DRIVER attachable=$ATTACH)"
  if [ "$ATTACH" = 1 ]; then
    docker network create --driver="$DRIVER" --attachable "$NET_NAME" >/dev/null
  else
    docker network create --driver="$DRIVER" "$NET_NAME" >/dev/null
  fi
done

for v in "${VOLUMES[@]:-}"; do
  [ -n "$v" ] || continue
  if ! docker volume inspect "$v" >/dev/null 2>&1; then
    log "creating volume $v"
    docker volume create "$v" >/dev/null
  fi
done

if [ "${#LABELS[@]}" -gt 0 ]; then
  if is_manager; then
    NODE_ID=$(docker info --format '{{.Swarm.NodeID}}')
    for kv in "${LABELS[@]}"; do
      log "label $kv"
      docker node update --label-add "$kv" "$NODE_ID" >/dev/null
    done
  else
    log "not a swarm manager, skipping ${#LABELS[@]} label(s)"
  fi
fi

if [ "$HAVE_DOCKER" = 1 ]; then
  log "done: hostname=$(hostname) swarm=$(swarm_state)"
else
  log "done: hostname=$(hostname) (docker not installed)"
fi
