#!/usr/bin/env bash
# portainer.sh - drive the Portainer REST API from the command line. Runs as root on a target server
# that already has Portainer deployed (stack "portainer", service reachable at PORTAINER_URL).
#
# Why this exists instead of "docker stack deploy" for everything:
#   Once a stack is created THROUGH Portainer (this script's `create`), Portainer keeps its own record
#   of that stack's ID and compose content. If you later change it with `docker stack deploy` instead of
#   Portainer's API, Portainer's record goes stale: the UI/API shows the old file, "pull and redeploy"
#   reapplies the WRONG content, and the two sources of truth disagree from then on. So a Portainer-made
#   stack must only ever be changed again with this script's `update`. Conversely, stacks that were
#   deployed by plain `docker stack deploy` before Portainer existed (typically traefik, and Portainer's
#   own stack) were never Portainer's to track -- leave those on `docker stack deploy` / `docker stack rm`.
#
# Other things this script exists to survive:
#   - Portainer >= 2.34 requires a one-time setup token (printed in the container's own log as
#     "setup_token=...", sent back as header X-Setup-Token) to create the first admin user, AND refuses
#     that first-admin creation entirely 5 minutes after the container started ("administrator
#     initialization timeout"). `init` handles both: it re-reads the token from the log on every attempt,
#     and force-updates (restarts) the Portainer service to get a fresh 5-minute window if it expired.
#   - The curl calls run inside a throwaway container so they can reach Portainer by its internal service
#     name over the overlay network, without installing curl or opening a port on the host. Request
#     bodies (they contain the admin password and stack secrets) go to a root-only temp dir (700, files
#     600) mounted read-only; the container runs as uid 0 to read them. The curl image's default non-root
#     user could not read a 700 dir - that broke the original run - and a world-readable dir leaks secrets.
#
# Usage: portainer.sh <command> [args...]        (portainer.sh -h for the full command list)
set -euo pipefail

PORTAINER_URL="${PORTAINER_URL:-http://portainer:9000}"
PORTAINER_NET="${PORTAINER_NET:-network_swarm_public}"
PORTAINER_USER="${PORTAINER_USER:-admin}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
APIDIR="${APIDIR:-/tmp/vps-clone-api}"
PAPI="${PORTAINER_URL%/}/api"

# PORTAINER_PASS is exported so the python3 helper below can read it from os.environ. It is never placed
# on a command line or inside a curl argument, so it never shows up in `ps`, docker's command history, or
# this script's own output.
export PORTAINER_USER
export PORTAINER_PASS

log(){ echo "[portainer $(hostname) $(date -u +%H:%M:%S)] $*"; }
has(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo "[portainer] ERROR: $*" >&2; exit 1; }

usage(){
  cat <<'USAGE'
Usage: portainer.sh <command> [args...]

Commands:
  init                        create the admin user (idempotent) and confirm login
  login-test                  log in and report ok/fail; never prints the password or the token
  endpoint                    print "endpoint_id=<id> swarm_id=<id>"
  list                        list stacks Portainer knows about (ID, NAME, STATUS)
  create NAME FILE            create a swarm stack NAME from compose file FILE (no-op if it exists)
  update NAME FILE [--prune] [--pull]
                               update an existing Portainer-managed stack from FILE
                               --prune  remove services no longer in FILE
                               --pull   force a fresh pull of every image in FILE
  delete NAME                 remove a stack (no-op if it does not exist)

Environment:
  PORTAINER_URL   Portainer base URL (default: http://portainer:9000). A plain http:// URL is reached
                  from a throwaway curlimages/curl container attached to PORTAINER_NET (this is normal
                  for a Portainer service name resolved on the overlay network); an https:// URL is
                  reached with curl on this host instead.
  PORTAINER_NET   overlay network the throwaway curl container joins (default: network_swarm_public)
  PORTAINER_USER  admin username (default: admin)
  PORTAINER_PASS  admin password (required; never printed, never logged, never put on a command line)
  CURL_IMAGE      curl image:tag used for API calls (default: curlimages/curl:8.10.1)
  APIDIR          root-only (700) temp dir for request bodies (default: /tmp/vps-clone-api); the curl
                  container runs as uid 0 so it can read them (lesson: a 700 dir broke a non-root curl)

Examples:
  PORTAINER_PASS=... portainer.sh init
  PORTAINER_PASS=... portainer.sh create postgres /root/vps-clone/stacks/postgres.yml
  PORTAINER_PASS=... portainer.sh update postgres /root/vps-clone/stacks/postgres.yml --pull
USAGE
}

require_pass(){
  : "${PORTAINER_PASS:?PORTAINER_PASS is required (export it, never hardcode it)}"
}

ensure_apidir(){
  mkdir -p "$APIDIR"
  chmod 700 "$APIDIR"
}

require_response(){ # require_response <response-body> <context-for-the-error>
  local resp=$1 ctx=$2
  [ -n "$resp" ] || die "empty response from Portainer ($ctx) at $PORTAINER_URL - check PORTAINER_URL/PORTAINER_NET and that Portainer is up"
}

require_stack_list(){ # require_stack_list <response-body-of-GET-/stacks>
  # GET /stacks answers with a JSON array on success and a JSON object (e.g. {"message":"..."}) on
  # failure (expired token, forbidden, ...). Without this check that object's HTTP body still reads as
  # non-empty and every downstream lookup (parse_stack_id) just finds no match, so a failed listing is
  # silently reported as "stack not found" -- create then tries to make a duplicate, update/delete report
  # a harmless no-op instead of surfacing the real error.
  local resp=$1
  require_response "$resp" "list stacks"
  case "$resp" in
    \[*) ;;
    *) die "unexpected response listing stacks (expected a JSON array): $(printf '%s' "$resp" | parse_error_message)" ;;
  esac
}

# ---- talking to the API -----------------------------------------------------------------------------

data_ref(){ # data_ref <filename-under-APIDIR> -> the --data-binary path curl should use for that file
  if [[ "$PORTAINER_URL" == https://* ]]; then
    printf '@%s/%s' "$APIDIR" "$1"
  else
    printf '@/w/%s' "$1"
  fi
}

pcurl(){ # pcurl <curl-args...> -- runs curl against $PAPI, inside a throwaway container unless https://
  if [[ "$PORTAINER_URL" == https://* ]]; then
    curl -s --max-time 60 "$@"
  else
    has docker || die "docker is required to reach '$PORTAINER_URL' via the throwaway curl container (use an https:// PORTAINER_URL to use curl on this host instead)"
    docker run --rm --user 0:0 --network "$PORTAINER_NET" -v "$APIDIR:/w:ro" "$CURL_IMAGE" -s --max-time 60 "$@"
  fi
}

# ---- request bodies (python3 json.dumps, never string concatenation) -------------------------------

write_json_body(){ # write_json_body <filename-under-APIDIR> -- writes {"Username":..,"Password":..}
  local fname=$1
  ensure_apidir
  python3 -c '
import json, os, sys

data = {"Username": os.environ["PORTAINER_USER"], "Password": os.environ["PORTAINER_PASS"]}
json.dump(data, sys.stdout)
' > "$APIDIR/$fname"
  chmod 600 "$APIDIR/$fname"
}

write_create_body(){ # write_create_body <stackname> <composefile> <swarmid> -> APIDIR/create.json
  ensure_apidir
  python3 -c '
import json, sys

name, path, swarm = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
json.dump({"name": name, "swarmID": swarm, "stackFileContent": content}, sys.stdout)
' "$1" "$2" "$3" > "$APIDIR/create.json"
  chmod 600 "$APIDIR/create.json"
}

write_update_body(){ # write_update_body <composefile> <prune 0|1> <pull 0|1> -> APIDIR/update.json
  ensure_apidir
  python3 -c '
import json, sys

path, prune, pull = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
json.dump({"stackFileContent": content, "env": [], "prune": prune, "pullImage": pull}, sys.stdout)
' "$1" "$2" "$3" > "$APIDIR/update.json"
  chmod 600 "$APIDIR/update.json"
}

# ---- reading responses (jq if present, else python3 - never grep/sed on JSON) ----------------------

pyjson(){ # pyjson <mode> [extra-args...] -- reads a JSON response on stdin
  python3 -c '
import json, sys

mode = sys.argv[1]
args = sys.argv[2:]
try:
    data = json.load(sys.stdin)
except Exception:
    data = None


def out(v):
    print(v if v is not None else "")


if mode == "jwt":
    out(data.get("jwt") if isinstance(data, dict) else None)
elif mode == "endpoint_id":
    out(data[0].get("Id") if isinstance(data, list) and data else None)
elif mode == "swarm_id":
    out(data.get("ID") if isinstance(data, dict) else None)
elif mode == "stack_id":
    name = args[0]
    found = None
    if isinstance(data, list):
        for s in data:
            if s.get("Name") == name:
                found = s.get("Id")
                break
    out(found)
elif mode == "has_id":
    print("yes" if isinstance(data, dict) and data.get("Id") is not None else "no")
elif mode == "list_stacks":
    if isinstance(data, list):
        for s in data:
            print(str(s.get("Id", "?")) + "\t" + str(s.get("Name", "?")) + "\t" + str(s.get("Status", "?")))
elif mode == "error_message":
    if isinstance(data, dict):
        out(data.get("message") or data.get("err"))
    else:
        out(None)
else:
    print("pyjson: unknown mode " + mode, file=sys.stderr)
    sys.exit(1)
' "$@"
}

# every parse_* below always exits 0 (an "empty" result is a normal outcome, not a script-ending error)
parse_jwt(){ if has jq; then jq -r '.jwt // empty' 2>/dev/null; else pyjson jwt; fi || true; }
parse_endpoint_id(){ if has jq; then jq -r '.[0].Id // empty' 2>/dev/null; else pyjson endpoint_id; fi || true; }
parse_swarm_id(){ if has jq; then jq -r '.ID // empty' 2>/dev/null; else pyjson swarm_id; fi || true; }
parse_error_message(){ if has jq; then jq -r '.message // .err // empty' 2>/dev/null; else pyjson error_message; fi || true; }
list_stacks_table(){ if has jq; then jq -r '.[] | [(.Id|tostring), .Name, (.Status|tostring)] | @tsv' 2>/dev/null; else pyjson list_stacks; fi || true; }
parse_stack_id(){ # parse_stack_id <name> -- reads a stacks-list response on stdin
  local name=$1
  if has jq; then jq -r --arg n "$name" '.[] | select(.Name==$n) | .Id' 2>/dev/null; else pyjson stack_id "$name"; fi || true
}
resp_has_id(){ # true if the response on stdin has a non-null "Id" (create/update succeeded)
  if has jq; then jq -e '.Id != null' >/dev/null 2>&1; else [ "$(pyjson has_id)" = yes ]; fi
}

# ---- login / endpoint discovery ----------------------------------------------------------------------

login(){ # login -> prints a JWT on stdout; dies with a clear message on failure
  require_pass
  write_json_body auth.json
  local resp jwt
  resp=$(pcurl -X POST -H 'Content-Type: application/json' "$PAPI/auth" --data-binary "$(data_ref auth.json)" || true)
  rm -f "$APIDIR/auth.json"
  jwt=$(printf '%s' "$resp" | parse_jwt)
  [ -n "$jwt" ] || die "Portainer login failed for user '$PORTAINER_USER' (run 'portainer.sh init' first, or check PORTAINER_URL/PORTAINER_PASS). Response: $(printf '%s' "$resp" | parse_error_message)"
  printf '%s' "$jwt"
}

resolve_endpoint(){ # resolve_endpoint <jwt> -- sets globals EP and SWARM_ID
  local jwt=$1 resp
  EP=""
  for _ in $(seq 1 40); do
    resp=$(pcurl -H "Authorization: Bearer $jwt" "$PAPI/endpoints" || true)
    EP=$(printf '%s' "$resp" | parse_endpoint_id)
    [ -n "$EP" ] && break
    sleep 3
  done
  [ -n "$EP" ] || die "no endpoint registered in Portainer yet (it should self-register a 'local' endpoint right after admin init)"
  resp=$(pcurl -H "Authorization: Bearer $jwt" "$PAPI/endpoints/$EP/docker/swarm" || true)
  SWARM_ID=$(printf '%s' "$resp" | parse_swarm_id)
}

find_portainer_service(){ # the Portainer web service itself -- NEVER portainer_agent, which has no admin API
  docker service ls --filter "name=portainer" --format '{{.Name}}' 2>/dev/null | grep -vi 'agent' | head -1 || true
}

wait_service_running(){ # wait_service_running <service> [timeout-seconds]
  local svc=$1 timeout=${2:-300} start=$SECONDS
  while [ $((SECONDS - start)) -lt "$timeout" ]; do
    docker service ps "$svc" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -q Running && return 0
    sleep 3
  done
  return 1
}

# ---- commands -----------------------------------------------------------------------------------------

cmd_init(){
  require_pass
  has docker || die "docker is required for 'init' (it reads the Portainer service's log and can force-update it)"
  ensure_apidir
  local svc
  svc=$(find_portainer_service)
  [ -n "$svc" ] || die "no Portainer service found (docker service ls --filter name=portainer); deploy the portainer stack first"
  log "using Portainer service: $svc"

  local deadline=$((SECONDS + 600))   # ~10 minutes total, covers a couple of initialization-timeout retries
  local tok resp jwt=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    tok=$(docker service logs "$svc" 2>&1 | grep -oE 'setup_token=[a-f0-9]+' | tail -1 | cut -d= -f2 || true)
    write_json_body init.json
    resp=$(pcurl -X POST -H 'Content-Type: application/json' -H "X-Setup-Token: ${tok:-none}" \
        "$PAPI/users/admin/init" --data-binary "$(data_ref init.json)" || true)
    rm -f "$APIDIR/init.json"

    if printf '%s' "$resp" | grep -qi 'initialization timeout'; then
      log "admin init window expired; force-updating $svc for a fresh one and retrying"
      docker service update --force -d "$svc" >/dev/null 2>&1 || true
      sleep 20
      wait_service_running "$svc" 300 || log "WARN: $svc did not report Running within 300s, retrying anyway"
      sleep 5
      continue
    fi
    printf '%s' "$resp" | resp_has_id && log "admin user created"

    write_json_body auth.json
    resp=$(pcurl -X POST -H 'Content-Type: application/json' "$PAPI/auth" --data-binary "$(data_ref auth.json)" || true)
    rm -f "$APIDIR/auth.json"
    jwt=$(printf '%s' "$resp" | parse_jwt)
    [ -n "$jwt" ] && break
    sleep 5
  done
  [ -n "$jwt" ] || die "could not log in to Portainer within 10 minutes (last response: $(printf '%s' "$resp" | parse_error_message))"
  log "login ok"
  resolve_endpoint "$jwt"
  log "endpoint_id=$EP swarm_id=${SWARM_ID:-none}"
}

cmd_login_test(){
  local jwt
  jwt=$(login)
  [ -n "$jwt" ] && log "login ok (user=$PORTAINER_USER, url=$PORTAINER_URL)"
}

cmd_endpoint(){
  local jwt
  jwt=$(login)
  resolve_endpoint "$jwt"
  echo "endpoint_id=$EP swarm_id=$SWARM_ID"
}

cmd_list(){
  local jwt resp
  jwt=$(login)
  resp=$(pcurl -H "Authorization: Bearer $jwt" "$PAPI/stacks" || true)
  require_stack_list "$resp"
  printf 'ID\tNAME\tSTATUS\n'
  printf '%s' "$resp" | list_stacks_table
}

cmd_create(){ # cmd_create <name> <file>
  local name=$1 file=$2
  [ -f "$file" ] || die "stack file not found: $file"
  local jwt resp existing
  jwt=$(login)
  resolve_endpoint "$jwt"
  [ -n "$SWARM_ID" ] || die "endpoint $EP has no active swarm; portainer.sh only manages swarm stacks"
  resp=$(pcurl -H "Authorization: Bearer $jwt" "$PAPI/stacks" || true)
  require_stack_list "$resp"
  existing=$(printf '%s' "$resp" | parse_stack_id "$name")
  if [ -n "$existing" ]; then
    log "stack '$name' already exists (id $existing); leaving it alone (use 'update' to change it)"
    return 0
  fi
  write_create_body "$name" "$file" "$SWARM_ID"
  resp=$(pcurl -X POST -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' \
      "$PAPI/stacks/create/swarm/string?endpointId=$EP" --data-binary "$(data_ref create.json)" || true)
  rm -f "$APIDIR/create.json"
  if printf '%s' "$resp" | resp_has_id; then
    log "stack '$name' created"
  else
    die "failed to create stack '$name': $(printf '%s' "$resp" | parse_error_message)"
  fi
}

cmd_update(){ # cmd_update <name> <file> [--prune] [--pull]
  local name=$1 file=$2
  shift 2
  local prune=0 pull=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --prune) prune=1 ;;
      --pull) pull=1 ;;
      *) die "update: unknown flag '$1'" ;;
    esac
    shift
  done
  [ -f "$file" ] || die "stack file not found: $file"
  local jwt resp id
  jwt=$(login)
  resolve_endpoint "$jwt"
  resp=$(pcurl -H "Authorization: Bearer $jwt" "$PAPI/stacks" || true)
  require_stack_list "$resp"
  id=$(printf '%s' "$resp" | parse_stack_id "$name")
  [ -n "$id" ] || die "stack '$name' does not exist in Portainer yet (use 'create $name $file' first; never 'docker stack deploy' a Portainer-managed stack)"
  write_update_body "$file" "$prune" "$pull"
  resp=$(pcurl -X PUT -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' \
      "$PAPI/stacks/$id?endpointId=$EP" --data-binary "$(data_ref update.json)" || true)
  rm -f "$APIDIR/update.json"
  if printf '%s' "$resp" | resp_has_id; then
    log "stack '$name' updated (id $id, prune=$prune pull=$pull)"
  else
    die "failed to update stack '$name': $(printf '%s' "$resp" | parse_error_message)"
  fi
}

cmd_delete(){ # cmd_delete <name>
  local name=$1
  local jwt resp id
  jwt=$(login)
  resolve_endpoint "$jwt"
  resp=$(pcurl -H "Authorization: Bearer $jwt" "$PAPI/stacks" || true)
  require_stack_list "$resp"
  id=$(printf '%s' "$resp" | parse_stack_id "$name")
  if [ -z "$id" ]; then
    log "stack '$name' not found; nothing to do"
    return 0
  fi
  # Portainer answers a successful delete with an empty 204 body; any non-empty body here is an error
  # (e.g. forbidden, stack locked) and must not be reported as a successful delete.
  resp=$(pcurl -X DELETE -H "Authorization: Bearer $jwt" "$PAPI/stacks/$id?endpointId=$EP&external=false" || true)
  if [ -n "$resp" ]; then
    die "failed to delete stack '$name': $(printf '%s' "$resp" | parse_error_message)"
  fi
  log "stack '$name' deleted (id $id)"
}

# ---- entry point ---------------------------------------------------------------------------------------

main(){
  if [ $# -eq 0 ]; then
    usage
    die "no command given"
  fi
  if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    return 0
  fi
  has python3 || die "python3 is required (request bodies are built with python3 -c json.dumps, never string concatenation)"

  local cmd=$1
  shift
  case "$cmd" in
    init) cmd_init ;;
    login-test) cmd_login_test ;;
    endpoint) cmd_endpoint ;;
    list) cmd_list ;;
    create)
      [ $# -eq 2 ] || { usage; die "create needs exactly NAME and FILE"; }
      cmd_create "$1" "$2"
      ;;
    update)
      [ $# -ge 2 ] || { usage; die "update needs at least NAME and FILE"; }
      cmd_update "$@"
      ;;
    delete)
      [ $# -eq 1 ] || { usage; die "delete needs exactly NAME"; }
      cmd_delete "$1"
      ;;
    *)
      usage
      die "unknown command: $cmd"
      ;;
  esac
}

main "$@"
