#!/usr/bin/env bash
# verify_web.sh --ip TARGET_IP host1 [host2 ...]
# Read-only DNS/HTTPS/TLS check for a list of hostnames against a target IP. Run it after
# pointing DNS at a new server (or beforehand, since every request forces --resolve host:443:IP
# regardless of what DNS currently says) to confirm each host: resolves to the right IP, answers
# HTTPS, and serves a certificate that actually covers it - not the router's default fallback
# certificate (e.g. Traefik's self-signed "TRAEFIK DEFAULT CERT", the classic symptom of a
# missing or misrouted proxy rule) and not some other unrelated self-signed certificate.
#
# Usage: verify_web.sh --ip TARGET_IP host1 [host2 ...]
#
# Per host, prints:
#   dns   - A record(s) currently returned by the system resolver, and whether TARGET_IP is
#           among them (getent ahostsv4, falling back to dig +short, falling back to host)
#   https - HTTP status code from `curl --resolve host:443:TARGET_IP` (forces the connection to
#           TARGET_IP no matter what DNS says, so this also works before switching DNS)
#   tls   - certificate issuer, subject, notAfter and Subject Alternative Name from
#           `openssl s_client -servername host -connect TARGET_IP:443 | openssl x509`, with
#           warnings for a missing/failed handshake, issuer==subject (self-signed, which is
#           exactly what Traefik's default cert looks like), or a SAN that does not list host
#
# Exit code: 0 if every host passed every check, 1 if any host failed any check.
# Read-only: makes DNS lookups and outbound HTTPS/TLS connections, changes nothing on disk.
set +e
export LC_ALL=C

has(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<'EOF'
Usage: verify_web.sh --ip TARGET_IP host1 [host2 ...]

Checks, for each hostname: its DNS A record(s) against TARGET_IP, the HTTPS status code when
forced to connect to TARGET_IP, and the TLS certificate's issuer/subject/expiry/SAN served
there - flagging a Traefik default cert, any other self-signed cert, or a SAN mismatch.

  --ip TARGET_IP   the server every host is expected to resolve to / be checked against
  -h, --help       this text

Exit code: 0 if every host passes every check, 1 otherwise (or 2 on a usage error).
Requires curl and openssl; getent, dig or host is used for the DNS check (best available).
EOF
}

IP=""
HOSTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ip) [ $# -ge 2 ] || { echo "verify_web.sh: --ip needs a value" >&2; exit 2; }; IP=$2; shift 2 ;;
    --ip=*) IP=${1#*=}; shift ;;
    --) shift; HOSTS+=("$@"); break ;;
    -*) echo "verify_web.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done

if [ -z "$IP" ]; then
  echo "verify_web.sh: --ip is required" >&2
  usage >&2
  exit 2
fi
if [ ${#HOSTS[@]} -eq 0 ]; then
  echo "verify_web.sh: at least one hostname is required" >&2
  usage >&2
  exit 2
fi
if ! has curl; then
  echo "verify_web.sh: curl is required" >&2
  exit 2
fi
if ! has openssl; then
  echo "verify_web.sh: openssl is required" >&2
  exit 2
fi

resolve_a(){
  local h="$1"
  if has getent; then
    getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u
  elif has dig; then
    dig +short A "$h" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
  elif has host; then
    host -t A "$h" 2>/dev/null | awk '/has address/{print $NF}' | sort -u
  fi
}

# true if the comma-separated "DNS:a, DNS:b" SAN string covers host: an exact "DNS:host" entry,
# or a "DNS:*.suffix" wildcard entry where host is exactly one label under that suffix (RFC 6125:
# a wildcard covers only the single leftmost label, never the bare suffix itself and never a
# deeper subdomain). Without this, a perfectly valid wildcard certificate (common behind Traefik/
# any DNS-01 issued cert) would be flagged as a SAN mismatch on every single host it covers.
san_matches(){
  local san_list="$1" host="$2" e suffix prefix entries
  IFS=',' read -ra entries <<< "$san_list"
  for e in "${entries[@]}"; do
    e="${e# }"
    case "$e" in
      "DNS:$host") return 0 ;;
      DNS:'*.'*)
        suffix="${e#DNS:\*.}"
        case "$host" in
          *".$suffix")
            prefix="${host%".$suffix"}"
            case "$prefix" in
              *.*|'') : ;;
              *) return 0 ;;
            esac
            ;;
        esac
        ;;
    esac
  done
  return 1
}

# openssl s_client hangs on a filtered port instead of erroring out; cap it with `timeout` when
# available (most Linux hosts; not always on stock Git Bash / macOS).
tls_probe(){
  local h="$1" ip="$2"
  if has timeout; then
    timeout 12 openssl s_client -servername "$h" -connect "$ip:443" </dev/null 2>/dev/null
  else
    openssl s_client -servername "$h" -connect "$ip:443" </dev/null 2>/dev/null
  fi
}

FAIL=0
for h in "${HOSTS[@]}"; do
  echo "== $h"
  host_fail=0

  ips=$(resolve_a "$h")
  if [ -z "$ips" ]; then
    echo "  dns: NO_A_RECORD"
    host_fail=1
  else
    echo "  dns: $(printf '%s' "$ips" | tr '\n' ' ')"
    if ! printf '%s\n' "$ips" | grep -qx "$IP"; then
      echo "  dns: WARNING does not include target $IP"
      host_fail=1
    fi
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$h:443:$IP" "https://$h/" 2>/dev/null)
  code="${code:-000}"
  echo "  https: code=$code"
  [ "$code" != "000" ] || host_fail=1

  certtext=$(tls_probe "$h" "$IP" | openssl x509 -noout -issuer -subject -enddate -ext subjectAltName 2>/dev/null)
  issuer=$(printf '%s\n' "$certtext" | sed -n 's/^issuer=//p')
  subject=$(printf '%s\n' "$certtext" | sed -n 's/^subject=//p')
  enddate=$(printf '%s\n' "$certtext" | sed -n 's/^notAfter=//p')
  san=$(printf '%s\n' "$certtext" | grep -A1 'Subject Alternative Name' | tail -n1 | sed 's/^ *//')

  if [ -z "$issuer" ] && [ -z "$subject" ]; then
    echo "  tls: WARNING could not read a certificate (handshake failed / connection refused / no TLS on 443)"
    host_fail=1
  else
    echo "  tls: issuer=${issuer:-?} notAfter=${enddate:-?}"
    echo "  tls: SAN=${san:-?}"
    case "$issuer" in
      *"TRAEFIK DEFAULT CERT"*)
        echo "  tls: WARNING TRAEFIK DEFAULT CERT - no router rule matched this host, or it is misrouted"
        host_fail=1
        ;;
      *)
        if [ -n "$issuer" ] && [ "$issuer" = "$subject" ]; then
          echo "  tls: WARNING self-signed certificate (issuer == subject)"
          host_fail=1
        fi
        ;;
    esac
    if [ -n "$san" ] && ! san_matches "$san" "$h"; then
      echo "  tls: WARNING SAN does not list $h"
      host_fail=1
    fi
  fi

  [ "$host_fail" -eq 0 ] && echo "  result: OK" || { echo "  result: FAIL"; FAIL=1; }
done

exit "$FAIL"
