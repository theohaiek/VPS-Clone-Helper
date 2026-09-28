#!/usr/bin/env bash
# firewall.sh - idempotent host firewall for a vps-clone cluster node (iptables + ip6tables).
# Blocks the internal control-plane and database ports of the cluster from the public internet
# while leaving the other node(s) of the same cluster (PEERS) with unrestricted access, and never
# touching 22/80/443/ICMP. Run it directly, or persist it across docker restarts/reboots with
# --install. Safe to re-run any time: every run rebuilds its own chains from scratch.
#
# Usage examples (from the controller, over SSH):
#   sshx.py tgt1 --script remote/firewall.sh --peers "198.51.100.21" --install
#   sshx.py tgt1 'bash /root/vps-clone/scripts/firewall.sh --status'
set -euo pipefail

log(){ echo "[firewall $(hostname) $(date -u +%H:%M:%S)] $*"; }
has(){ command -v "$1" >/dev/null 2>&1; }

CONF_FILE="${CONF_FILE:-/etc/vps-clone/firewall.env}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/vps-clone-firewall}"
DROPIN="${DROPIN:-/etc/systemd/system/docker.service.d/vps-clone-firewall.conf}"

# Resolve our own path on disk (needed by --install). Empty when run via `bash -s` / piped stdin,
# in which case there is nothing on disk to copy and --install refuses with a clear message.
SCRIPT_PATH=""
if [ -f "$0" ] && [ -r "$0" ]; then
  case "$0" in
    /*) SCRIPT_PATH="$0" ;;
    *) SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" ;;
  esac
fi

usage(){
  cat <<'EOF'
Usage: firewall.sh [--install|--status|--remove] [--peers "ip ip ..."] [--iface IFACE] [-h]

Idempotent iptables/ip6tables firewall for one node of a vps-clone cluster:
  - VPSCLONE-INPUT (hooked into INPUT): drops BLOCK_TCP/BLOCK_UDP ports arriving on IFACE.
  - VPSCLONE-FWD (hooked into DOCKER-USER): drops NEW connections to FWD_BLOCK_TCP ports that
    Docker Swarm's ingress mesh would otherwise publish on every node, bypassing INPUT.
  Loopback and ESTABLISHED,RELATED are always allowed first. PEERS (the other node(s) of this
  cluster) are allowed unrestricted access in both chains. 22/80/443/ICMP are never touched,
  even if you put them in BLOCK_TCP/BLOCK_UDP by mistake.

Actions (default: apply now, without persisting):
  --install   apply now AND install to /usr/local/sbin plus a docker.service.d systemd drop-in
              (ExecStartPost) so the rules survive every docker restart and every reboot.
              Requires running this script from a real file on disk (see the examples below).
  --status    print whether the chains/hooks are active, rule counts and drop counts.
  --remove    remove the hooks, the chains, the installed copy and the drop-in. Leaves the
              config file (CONF_FILE below) alone.

Flags:
  --peers "IP IP"  Space-separated IPs of the other node(s) in this cluster (IPv4 and/or IPv6 -
                   IPv6 peers are automatically placed in the ip6tables chain). Persisted.
  --iface IFACE    Public interface to filter on. Default: auto-detected from the default route
                   (`ip route show default`). Persisted.

Every value can also come from the environment (same names: IFACE, PEERS, BLOCK_TCP, BLOCK_UDP,
FWD_BLOCK_TCP) or from the config file below; precedence is flag > environment > config file >
built-in default. The effective config is always written back to the config file, so an
unattended re-run (e.g. triggered by systemd with no arguments at all) keeps working:

  Config file: /etc/vps-clone/firewall.env
    IFACE           public interface (auto-detected if unset)
    PEERS           space-separated peer IPs, "" by default
    BLOCK_TCP       default: 2377 7946 3306 5432 6379 27017 5672 15672 9000 9443 8080
    BLOCK_UDP       default: 7946 4789
    FWD_BLOCK_TCP   default: 3306 5432 6379 27017 5672

Examples:
  # first run on a freshly bootstrapped node, from a copy already on disk:
  bash /root/vps-clone/scripts/firewall.sh --peers "198.51.100.21" --install
  # check it later:
  bash /root/vps-clone/scripts/firewall.sh --status

A host firewall is not a substitute for a provider-level cloud firewall / security group; where
your provider has one, enable it too (deny-by-default inbound except 22/80/443) as a complement.
EOF
}

strip_protected(){
  # Defense in depth: 22/80/443 must never end up in a block list, no matter what the config says.
  local out="" p
  for p in $1; do
    case "$p" in
      22|80|443) ;;
      *) out="$out $p" ;;
    esac
  done
  printf '%s' "${out# }"
}

detect_iface(){
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' 2>/dev/null || true
}

ensure_iptables(){
  has iptables && return 0
  if has apt-get; then
    log "iptables not found, installing it"
    apt-get update -qq
    apt-get install -y iptables >/dev/null
  else
    echo "firewall.sh: iptables not found and apt-get is unavailable; this script targets Debian/Ubuntu hosts" >&2
    exit 1
  fi
}

have_ip6tables(){
  has ip6tables && ip6tables -L -n >/dev/null 2>&1
}

need_root(){
  [ "$(id -u)" = 0 ] || { echo "firewall.sh: must run as root" >&2; exit 1; }
}

resolve_config(){
  # Priority for every knob: CLI flag > environment variable at invocation > persisted config
  # file > built-in default. Capture env values BEFORE sourcing the file, since the file (once
  # it exists) would otherwise silently clobber a one-off environment override.
  local _env_iface="${IFACE:-}" _env_peers="${PEERS:-}"
  local _env_block_tcp="${BLOCK_TCP:-}" _env_block_udp="${BLOCK_UDP:-}" _env_fwd_block_tcp="${FWD_BLOCK_TCP:-}"

  if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
  fi

  IFACE="${IFACE_ARG:-${_env_iface:-${IFACE:-}}}"
  PEERS="${PEERS_ARG:-${_env_peers:-${PEERS:-}}}"
  BLOCK_TCP="${_env_block_tcp:-${BLOCK_TCP:-2377 7946 3306 5432 6379 27017 5672 15672 9000 9443 8080}}"
  BLOCK_UDP="${_env_block_udp:-${BLOCK_UDP:-7946 4789}}"
  FWD_BLOCK_TCP="${_env_fwd_block_tcp:-${FWD_BLOCK_TCP:-3306 5432 6379 27017 5672}}"

  [ -n "$IFACE" ] || IFACE="$(detect_iface)"
  [ -n "$IFACE" ] || { echo "firewall.sh: cannot auto-detect the public interface (no default route); pass --iface" >&2; exit 1; }

  BLOCK_TCP="$(strip_protected "$BLOCK_TCP")"
  BLOCK_UDP="$(strip_protected "$BLOCK_UDP")"
  FWD_BLOCK_TCP="$(strip_protected "$FWD_BLOCK_TCP")"
}

write_conf(){
  mkdir -p "$(dirname "$CONF_FILE")"
  cat > "$CONF_FILE" <<EOF
# Written by vps-clone-helper firewall.sh. Edit freely; every run re-reads and re-writes it.
IFACE=$IFACE
PEERS="$PEERS"
BLOCK_TCP="$BLOCK_TCP"
BLOCK_UDP="$BLOCK_UDP"
FWD_BLOCK_TCP="$FWD_BLOCK_TCP"
EOF
}

split_peers(){
  peers_v4=""
  peers_v6=""
  local p
  for p in $PEERS; do
    case "$p" in
      *:*) peers_v6="$peers_v6 $p" ;;
      *) peers_v4="$peers_v4 $p" ;;
    esac
  done
}

build_input(){
  local cmd="$1" peers="$2" p port
  "$cmd" -N VPSCLONE-INPUT 2>/dev/null || "$cmd" -F VPSCLONE-INPUT
  "$cmd" -A VPSCLONE-INPUT -i lo -j RETURN
  "$cmd" -A VPSCLONE-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for p in $peers; do "$cmd" -A VPSCLONE-INPUT -s "$p" -j RETURN; done
  for port in $BLOCK_TCP; do "$cmd" -A VPSCLONE-INPUT -i "$IFACE" -p tcp --dport "$port" -j DROP; done
  for port in $BLOCK_UDP; do "$cmd" -A VPSCLONE-INPUT -i "$IFACE" -p udp --dport "$port" -j DROP; done
  "$cmd" -C INPUT -j VPSCLONE-INPUT 2>/dev/null || "$cmd" -I INPUT 1 -j VPSCLONE-INPUT
}

build_fwd(){
  local cmd="$1" peers="$2" p port
  "$cmd" -N DOCKER-USER 2>/dev/null || true
  "$cmd" -N VPSCLONE-FWD 2>/dev/null || "$cmd" -F VPSCLONE-FWD
  for p in $peers; do "$cmd" -A VPSCLONE-FWD -s "$p" -j RETURN; done
  for port in $FWD_BLOCK_TCP; do "$cmd" -A VPSCLONE-FWD -i "$IFACE" -p tcp --dport "$port" -m conntrack --ctstate NEW -j DROP; done
  "$cmd" -A VPSCLONE-FWD -j RETURN
  "$cmd" -C DOCKER-USER -j VPSCLONE-FWD 2>/dev/null || "$cmd" -I DOCKER-USER 1 -j VPSCLONE-FWD
}

summary(){
  local v4_in v4_fwd v6_in=0 v6_fwd=0 npeers
  v4_in=$(iptables -S VPSCLONE-INPUT 2>/dev/null | grep -c -- '-j DROP' || true)
  v4_fwd=$(iptables -S VPSCLONE-FWD 2>/dev/null | grep -c -- '-j DROP' || true)
  if [ "$HAVE_V6" = 1 ]; then
    v6_in=$(ip6tables -S VPSCLONE-INPUT 2>/dev/null | grep -c -- '-j DROP' || true)
    v6_fwd=$(ip6tables -S VPSCLONE-FWD 2>/dev/null | grep -c -- '-j DROP' || true)
  fi
  npeers=$(printf '%s' "$PEERS" | wc -w | tr -d ' ')
  log "applied on $IFACE: INPUT drops v4=$v4_in v6=$v6_in, FWD drops v4=$v4_fwd v6=$v6_fwd, peers=$npeers"
  if [ "$npeers" = 0 ]; then
    log "WARNING: no PEERS configured -- if this cluster has other node(s), they are now blocked from the ports above too (Swarm 2377/7946, DB ports, ...). Re-run with --peers \"<other node IP(s)>\" to allow them."
  fi
  log "reminder: a provider-level cloud firewall (security group) is a good complement to this host firewall, not a replacement for it"
}

do_apply(){
  need_root
  resolve_config
  ensure_iptables
  split_peers
  write_conf
  build_input iptables "$peers_v4"
  build_fwd iptables "$peers_v4"
  HAVE_V6=0
  if have_ip6tables; then
    HAVE_V6=1
    build_input ip6tables "$peers_v6"
    build_fwd ip6tables "$peers_v6"
  else
    log "ip6tables unavailable or IPv6 disabled: skipping IPv6 rules"
  fi
  summary
}

do_install(){
  need_root
  if [ -z "$SCRIPT_PATH" ]; then
    echo "firewall.sh: --install needs to run from a real file on this host, not piped via stdin." >&2
    echo "Copy it first, e.g.: sshx.py <alias> --put-tree skills/vps-clone/scripts/remote /root/vps-clone/scripts" >&2
    echo "then run: sshx.py <alias> 'bash /root/vps-clone/scripts/firewall.sh --install'" >&2
    exit 1
  fi
  do_apply
  install -m 700 "$SCRIPT_PATH" "$INSTALL_PATH"
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nExecStartPost=-%s\n' "$INSTALL_PATH" > "$DROPIN"
  systemctl daemon-reload
  log "installed at $INSTALL_PATH; docker will re-apply it via $DROPIN on every start/restart/reboot"
}

do_status(){
  need_root
  resolve_config
  echo "config: iface=$IFACE peers=[$PEERS]"
  local spec cmd hook chain rest rules drops hooked
  for spec in "iptables:INPUT:VPSCLONE-INPUT" "iptables:DOCKER-USER:VPSCLONE-FWD" \
              "ip6tables:INPUT:VPSCLONE-INPUT" "ip6tables:DOCKER-USER:VPSCLONE-FWD"; do
    cmd="${spec%%:*}"
    rest="${spec#*:}"
    hook="${rest%%:*}"
    chain="${rest#*:}"
    if ! has "$cmd"; then
      echo "$cmd: not installed on this host"
      continue
    fi
    if "$cmd" -L "$chain" -n >/dev/null 2>&1; then
      rules=$("$cmd" -S "$chain" 2>/dev/null | grep -c '^-A' || true)
      drops=$("$cmd" -S "$chain" 2>/dev/null | grep -c -- '-j DROP' || true)
      if "$cmd" -C "$hook" -j "$chain" 2>/dev/null; then hooked=yes; else hooked=no; fi
      echo "$cmd $chain (hook=$hook active=$hooked): $rules rules, $drops drops"
    else
      echo "$cmd $chain: not present (never applied)"
    fi
  done
  if [ -f "$DROPIN" ]; then
    echo "persisted: $DROPIN"
  else
    echo "not persisted (run --install to survive docker restarts/reboots)"
  fi
}

do_remove(){
  need_root
  local cmd
  for cmd in iptables ip6tables; do
    has "$cmd" || continue
    if "$cmd" -C INPUT -j VPSCLONE-INPUT 2>/dev/null; then "$cmd" -D INPUT -j VPSCLONE-INPUT; fi
    if "$cmd" -C DOCKER-USER -j VPSCLONE-FWD 2>/dev/null; then "$cmd" -D DOCKER-USER -j VPSCLONE-FWD; fi
    "$cmd" -F VPSCLONE-INPUT 2>/dev/null || true
    "$cmd" -F VPSCLONE-FWD 2>/dev/null || true
    "$cmd" -X VPSCLONE-INPUT 2>/dev/null || true
    "$cmd" -X VPSCLONE-FWD 2>/dev/null || true
  done
  if [ -f "$DROPIN" ]; then
    rm -f "$DROPIN"
    systemctl daemon-reload 2>/dev/null || true
  fi
  [ -f "$INSTALL_PATH" ] && rm -f "$INSTALL_PATH"
  log "removed hooks, chains and persistence (config left at $CONF_FILE)"
}

ACTION=apply
IFACE_ARG=""
PEERS_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) ACTION=install; shift ;;
    --status) ACTION=status; shift ;;
    --remove) ACTION=remove; shift ;;
    --peers) PEERS_ARG="${2:?--peers needs a value, e.g. --peers \"198.51.100.21\"}"; shift 2 ;;
    --peers=*) PEERS_ARG="${1#*=}"; shift ;;
    --iface) IFACE_ARG="${2:?--iface needs a value, e.g. --iface eth0}"; shift 2 ;;
    --iface=*) IFACE_ARG="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "firewall.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$ACTION" in
  apply) do_apply ;;
  install) do_install ;;
  status) do_status ;;
  remove) do_remove ;;
esac
