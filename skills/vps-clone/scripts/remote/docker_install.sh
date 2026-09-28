#!/usr/bin/env bash
# docker_install.sh - install or upgrade Docker Engine + containerd from the official
# download.docker.com apt repo, on Debian or Ubuntu. Idempotent: safe to re-run.
#
# Usage:
#   docker_install.sh [--docker VERSION|latest] [--containerd VERSION] [--hold] [--unhold]
#
# Exit codes: 0 ok, 1 bad usage / version not found in the repo, 3 unsupported distro.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PKG_LIST=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
KEYRING=/etc/apt/keyrings/docker.asc

log(){ echo "[docker-install $(hostname) $(date -u +%H:%M:%S)] $*"; }
fail(){ echo "[docker-install $(hostname) $(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

usage(){
  cat <<'EOF'
Usage: docker_install.sh [--docker VERSION|latest] [--containerd VERSION] [--hold] [--unhold]

Installs/upgrades Docker Engine + containerd from the official download.docker.com apt
repo (Debian/Ubuntu only). Idempotent: re-running with the same flags is a no-op once the
wanted versions are already installed.

  --docker VERSION|latest   exact apt version, e.g. "5:28.3.0-1~debian.12~bookworm" (list
                             candidates with `apt-cache madison docker-ce` after a first run
                             has added the repo), or the literal word "latest" (default).
  --containerd VERSION      exact apt version for containerd.io. Default: whatever newest
                             version satisfies the docker-ce dependency.
  --hold                    apt-mark hold docker-ce/docker-ce-cli/containerd.io/buildx/compose
                             afterwards, so an unrelated `apt upgrade` leaves Docker alone.
  --unhold                  apt-mark unhold the same packages (undo --hold).
  -h, --help                this text.

Notes:
  - Old docker-ce/containerd.io .deb packages stay in the download.docker.com pool even
    after a newer version ships, so an exact --docker VERSION keeps working long after it
    stops being "latest".
  - Upgrading an already-installed engine that is a swarm manager running services prints a
    REQUIRED FOLLOW-UP block: the in-place upgrade restarts containers without re-registering
    them on the overlay network, so name resolution between services breaks until every
    service is force-updated.

Exit codes: 0 ok, 1 bad usage / version not found in the repo, 3 unsupported distro.
EOF
}

DOCKER_WANT=latest
CONTAINERD_WANT=""
DO_HOLD=0
DO_UNHOLD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --docker)
      [ $# -ge 2 ] || { usage >&2; fail "--docker needs a value"; }
      DOCKER_WANT=$2; shift 2 ;;
    --containerd)
      [ $# -ge 2 ] || { usage >&2; fail "--containerd needs a value"; }
      CONTAINERD_WANT=$2; shift 2 ;;
    --hold) DO_HOLD=1; shift ;;
    --unhold) DO_UNHOLD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

if [ ! -r /etc/os-release ]; then
  echo "[docker-install $(hostname) $(date -u +%H:%M:%S)] ERROR: no /etc/os-release, cannot detect distro" >&2
  exit 3
fi
DISTRO_ID=""
CODENAME=""
# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID=${ID:-}
CODENAME=${VERSION_CODENAME:-}
case "$DISTRO_ID" in
  debian|ubuntu) : ;;
  *)
    echo "[docker-install $(hostname) $(date -u +%H:%M:%S)] ERROR: unsupported distro '${DISTRO_ID:-unknown}' -- docker_install.sh only supports debian/ubuntu" >&2
    exit 3 ;;
esac
if [ -z "$CODENAME" ]; then
  echo "[docker-install $(hostname) $(date -u +%H:%M:%S)] ERROR: could not read VERSION_CODENAME from /etc/os-release" >&2
  exit 3
fi

pkg_ver(){ dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
madison_versions(){ apt-cache madison "$1" 2>/dev/null | awk '{print $3}'; }
# No early `exit` in the awk script: under `pipefail`, a short-circuiting reader that closes
# its input before the writer (apt-cache) finishes can make the writer's next write() raise
# SIGPIPE, which pipefail then reports as a failure of this whole pipeline -- silently
# aborting the script here via `set -e` (this function's result feeds a bare assignment,
# not an `if`). Read to EOF instead; the output is one line either way.
apt_candidate(){ apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}'; }

log "distro=$DISTRO_ID codename=$CODENAME docker_want=$DOCKER_WANT containerd_want=${CONTAINERD_WANT:-<newest>}"

log "prerequisites"
apt-get update -qq
apt-get install -y -qq ca-certificates curl >/dev/null

log "docker apt repo"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" -o "$KEYRING"
chmod a+r "$KEYRING"
ARCH=$(dpkg --print-architecture)
echo "deb [arch=${ARCH} signed-by=${KEYRING}] https://download.docker.com/linux/${DISTRO_ID} ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq

if [ "$DOCKER_WANT" != latest ]; then
  # Capture first, then grep the captured string (a here-string, not a live pipe): with
  # `grep -q` reading directly from the `madison_versions` pipe, a match found before
  # apt-cache/awk finish writing can SIGPIPE the writer once the repo pool has grown past
  # one pipe buffer, which pipefail turns into a false "not found".
  if ! grep -qxF "$DOCKER_WANT" <<<"$(madison_versions docker-ce)"; then
    log "available docker-ce versions:"
    madison_versions docker-ce || true
    fail "docker-ce=$DOCKER_WANT not found in the repo (see list above)"
  fi
fi
if [ -n "$CONTAINERD_WANT" ]; then
  if ! grep -qxF "$CONTAINERD_WANT" <<<"$(madison_versions containerd.io)"; then
    log "available containerd.io versions:"
    madison_versions containerd.io || true
    fail "containerd.io=$CONTAINERD_WANT not found in the repo (see list above)"
  fi
fi

CUR_DOCKER=$(pkg_ver docker-ce)
CUR_CONTAINERD=$(pkg_ver containerd.io)
WAS_INSTALLED=0
if [ -n "$CUR_DOCKER" ]; then WAS_INSTALLED=1; fi

if [ "$DOCKER_WANT" = latest ]; then
  TARGET_DOCKER=$(apt_candidate docker-ce)
else
  TARGET_DOCKER=$DOCKER_WANT
fi
if [ -n "$CONTAINERD_WANT" ]; then
  TARGET_CONTAINERD=$CONTAINERD_WANT
else
  TARGET_CONTAINERD=$(apt_candidate containerd.io)
fi

NOOP=0
if [ "$CUR_DOCKER" = "$TARGET_DOCKER" ] && [ "$CUR_CONTAINERD" = "$TARGET_CONTAINERD" ]; then
  NOOP=1
fi

if [ "$NOOP" = 1 ]; then
  log "already at the wanted version ($CUR_DOCKER / $CUR_CONTAINERD), nothing to install"
else
  PRE_MANAGER=false
  PRE_SERVICE_COUNT=0
  if [ "$WAS_INSTALLED" = 1 ]; then
    PRE_MANAGER=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo false)
    if [ "$PRE_MANAGER" = true ]; then
      PRE_SERVICE_COUNT=$(docker service ls -q 2>/dev/null | wc -l | tr -d ' ')
    fi
  fi

  apt-mark unhold "${PKG_LIST[@]}" >/dev/null 2>&1 || true

  INSTALL_PKGS=(docker-ce docker-ce-cli)
  if [ "$DOCKER_WANT" != latest ]; then
    INSTALL_PKGS=("docker-ce=${DOCKER_WANT}" "docker-ce-cli=${DOCKER_WANT}")
  fi
  if [ -n "$CONTAINERD_WANT" ]; then
    INSTALL_PKGS+=("containerd.io=${CONTAINERD_WANT}")
  else
    INSTALL_PKGS+=(containerd.io)
  fi
  INSTALL_PKGS+=(docker-buildx-plugin docker-compose-plugin)

  log "installing: ${INSTALL_PKGS[*]}"
  apt-get install -y -qq -o Dpkg::Options::=--force-confnew "${INSTALL_PKGS[@]}" >/dev/null

  systemctl daemon-reload
  if [ "$WAS_INSTALLED" = 1 ]; then
    log "restarting containerd + docker"
    systemctl restart containerd docker
  else
    systemctl enable --now docker containerd >/dev/null
  fi

  DOCKER_UP=0
  for _ in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then DOCKER_UP=1; break; fi
    sleep 2
  done
  [ "$DOCKER_UP" = 1 ] || fail "docker did not come back up after install/restart"

  if [ "$WAS_INSTALLED" = 1 ] && [ "$PRE_MANAGER" = true ] && [ "$PRE_SERVICE_COUNT" -gt 0 ]; then
    log "REQUIRED FOLLOW-UP: docker/containerd upgraded in place on a swarm manager running $PRE_SERVICE_COUNT service(s)"
    cat <<'EOF'

################################################################################
# REQUIRED FOLLOW-UP
#
# Upgrading Docker/containerd in place restarts containers WITHOUT re-registering
# them on the overlay network: services come back "running" but fail with
# ENOTFOUND on other service names, and dockerd logs "Inconsistent driver and
# libnetwork state". A plain reboot does not have this problem, only an
# in-place package upgrade does. Fix, run now:
#
#   for s in $(docker service ls -q); do docker service update --force -d "$s"; done
#
# Then TEST overlay DNS from inside a running task -- do not trust
# "docker service ls" alone, it reports "running" even while DNS is broken:
#
#   docker exec "$(docker ps -q --filter label=com.docker.swarm.service.name | head -1)" getent hosts <another-service-name>
################################################################################

EOF
  fi
fi

if [ "$DO_UNHOLD" = 1 ]; then
  apt-mark unhold "${PKG_LIST[@]}" >/dev/null 2>&1 || true
  log "unheld: ${PKG_LIST[*]}"
fi
if [ "$DO_HOLD" = 1 ]; then
  apt-mark hold "${PKG_LIST[@]}" >/dev/null
  log "held: ${PKG_LIST[*]}"
fi

docker version --format 'docker client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null || true
CONTAINERD_BIN_VER=$(containerd --version 2>/dev/null | awk '{print $3}')
echo "containerd $CONTAINERD_BIN_VER"
echo "docker-ce=$(pkg_ver docker-ce) docker-ce-cli=$(pkg_ver docker-ce-cli) containerd.io=$(pkg_ver containerd.io)"
