#!/bin/bash
# export_docker.sh - READ-ONLY export of everything needed to rebuild a Docker host / Swarm elsewhere.
# Writes nothing on the server. Emits a text stream of files separated by markers; unpack it locally:
#   python sshx.py src1 --script remote/export_docker.sh > "$VPSCLONE_DIR/export/src1.stream"
#   python stacks.py unpack "$VPSCLONE_DIR/export/src1.stream" "$VPSCLONE_DIR/export/src1"
# Output CONTAINS SECRETS (env vars, compose files). Keep it inside $VPSCLONE_DIR.
set +e
export LC_ALL=C
file(){ echo "@@@VPSCLONE-FILE $1@@@"; }
has(){ command -v "$1" >/dev/null 2>&1; }
has docker || { file ERROR.txt; echo "docker not installed on $(hostname)"; exit 0; }

file host.txt
echo "hostname=$(hostname) docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
dpkg-query -W -f='${Package}=${Version}\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null
docker info --format 'swarm={{.Swarm.LocalNodeState}} manager={{.Swarm.ControlAvailable}} nodeaddr={{.Swarm.NodeAddr}}'

file daemon.json; cat /etc/docker/daemon.json 2>/dev/null
for f in /etc/systemd/system/docker.service.d/*.conf; do [ -f "$f" ] && { file "systemd/$(basename "$f")"; cat "$f"; }; done

file images.tsv
docker images --digests --format '{{.Repository}}\t{{.Tag}}\t{{.Digest}}\t{{.ID}}' 2>/dev/null
file image_repodigests.tsv
for i in $(docker images -q | sort -u); do
  echo -e "$i\t$(docker image inspect "$i" --format '{{join .RepoTags ","}}\t{{join .RepoDigests ","}}')"
done

file volumes.json; docker volume ls -q | xargs -r docker volume inspect 2>/dev/null
file networks.json; docker network ls -q --filter type=custom | xargs -r docker network inspect 2>/dev/null
file containers.json; docker ps -aq | xargs -r docker inspect 2>/dev/null

SWARM=$(docker info --format '{{.Swarm.LocalNodeState}}/{{.Swarm.ControlAvailable}}' 2>/dev/null)
if [ "$SWARM" = active/true ]; then
  file swarm/nodes.json; docker node ls -q | xargs -r docker node inspect 2>/dev/null
  file swarm/stacks.txt; docker stack ls --format '{{.Name}}\t{{.Services}}' 2>/dev/null
  for s in $(docker service ls --format '{{.Name}}'); do
    file "swarm/services/$s.json"; docker service inspect "$s"
  done
  for c in $(docker config ls --format '{{.Name}}'); do
    file "swarm/configs/$c.json"; docker config inspect "$c"
  done
  file swarm/secrets.txt
  echo "# Swarm secret VALUES cannot be read back from the API. Find them in the stack files/env or inside the"
  echo "# running containers (/run/secrets/<name>) and recreate them on the target."
  docker secret ls --format '{{.Name}}\t{{.CreatedAt}}' 2>/dev/null
fi

# Portainer keeps the compose file of every stack it created in <portainer_data>/compose/<stack id>/
for v in $(docker volume ls -q | grep -i portainer); do
  mp=$(docker volume inspect -f '{{.Mountpoint}}' "$v")
  [ -d "$mp/compose" ] || continue
  find "$mp/compose" -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.env' -o -name '.env' \) -size -2M 2>/dev/null | while read -r f; do
    file "portainer/${f#"$mp"/compose/}"; cat "$f"; echo
  done
done

# Stack/compose files kept on disk (CLI-deployed stacks such as traefik/portainer, compose projects):
# any small *.yml/*.yaml with a top-level "services:" key, plus .env files next to them.
{
  find /root /opt /srv /home -maxdepth 4 -type f \( -name '*.yml' -o -name '*.yaml' \) -size -2M 2>/dev/null \
    | grep -v -e '/node_modules/' -e '/\.git/' | while read -r f; do
        grep -q -E '^services:' "$f" 2>/dev/null && { echo "$f"; ls "$(dirname "$f")"/.env "$(dirname "$f")"/*.env 2>/dev/null; }
      done
  docker ps -a --format '{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | tr ',' '\n'
  docker ps -a --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | while read -r d; do [ -n "$d" ] && ls "$d"/.env "$d"/*.env 2>/dev/null; done
} | grep -v '^$' | grep -v '/var/lib/docker/' | sort -u | while read -r f; do
  [ -f "$f" ] && { file "disk$f"; cat "$f"; echo; }
done
file END.txt; echo "export complete $(date -u +%FT%TZ)"
