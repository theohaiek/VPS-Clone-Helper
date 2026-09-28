#!/bin/bash
# inventory.sh - READ-ONLY inventory of one Linux server. Writes nothing on the server: everything goes to stdout.
# Run it on every source node (and later on every target node, to diff):
#   python sshx.py src1 --script remote/inventory.sh > "$VPSCLONE_DIR/inventory/src1.txt"
# Sections start with "##### NAME". Secrets can appear (env of containers): keep the output inside $VPSCLONE_DIR.
set +e
export LC_ALL=C
sec(){ echo; echo "##### $*"; }
has(){ command -v "$1" >/dev/null 2>&1; }
t(){ timeout "${T:-20}" "$@"; }

sec META
echo "collected_at=$(date -u +%FT%TZ) hostname=$(hostname) fqdn=$(hostname -f 2>/dev/null)"
uptime

sec CLOUD
for f in sys_vendor product_name board_vendor chassis_vendor; do
  [ -r /sys/class/dmi/id/$f ] && echo "dmi_$f=$(cat /sys/class/dmi/id/$f)"
done
M=169.254.169.254
curl -s -f --max-time 2 http://$M/hetzner/v1/metadata 2>/dev/null | grep -E '^(hostname|instance-id|region|availability-zone|public-ipv4):' | sed 's/^/hetzner_/'
curl -s -f --max-time 2 http://$M/metadata/v1.json 2>/dev/null | head -c 600 | sed 's/^/digitalocean=/'
curl -s -f --max-time 2 http://$M/v1.json 2>/dev/null | head -c 600 | sed 's/^/vultr=/'
TOK=$(curl -s -f --max-time 2 -X PUT http://$M/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
[ -n "$TOK" ] && for k in instance-type placement/region placement/availability-zone public-ipv4 ami-id; do
  echo "aws_$k=$(curl -s --max-time 2 -H "X-aws-ec2-metadata-token: $TOK" http://$M/latest/meta-data/$k)"; done
curl -s -f --max-time 2 -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/machine-type' 2>/dev/null | sed 's/^/gcp_machine_type=/'; echo
curl -s -f --max-time 2 -H 'Metadata: true' "http://$M/metadata/instance/compute?api-version=2021-02-01" 2>/dev/null | head -c 600 | sed 's/^/azure=/'
curl -s -f --max-time 2 -H 'Authorization: Bearer Oracle' http://$M/opc/v2/instance/ 2>/dev/null | grep -E '"(shape|region|availabilityDomain)"' | sed 's/^/oracle/'
echo "public_ipv4=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null || echo unknown)"

sec HARDWARE
lscpu 2>/dev/null | grep -E '^(Model name|CPU\(s\)|Vendor ID|Architecture|Hypervisor vendor|Virtualization type):'
free -m
swapon --show 2>/dev/null
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null
df -hPT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null
sec FSTAB; grep -v '^\s*#' /etc/fstab 2>/dev/null | grep -v '^\s*$'

sec OS
cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|ID|VERSION_ID|VERSION_CODENAME)='
echo "kernel=$(uname -r) arch=$(uname -m)"
echo "timezone=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
echo "locale=$(locale 2>/dev/null | grep -E '^LANG=' )"
has cloud-init && echo "cloud_init=$(cloud-init status 2>/dev/null | head -1)"
has unattended-upgrade && echo "unattended_upgrades=installed"
cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null

sec NETWORK
ip -br addr 2>/dev/null
ip route 2>/dev/null | head -20
grep -v '^\s*#' /etc/resolv.conf 2>/dev/null
sec HOSTS_FILE; grep -v '^\s*#' /etc/hosts | grep -v '^\s*$'
sec LISTENING_PORTS; ss -tulpnH 2>/dev/null | awk '{print $1, $5, $7}' | sort -u

sec FIREWALL
has ufw && ufw status verbose 2>/dev/null
has firewall-cmd && firewall-cmd --list-all 2>/dev/null
has iptables && { iptables -S 2>/dev/null | grep -vE '^-A DOCKER( |-ISOLATION)' | head -120; echo "-- nat"; iptables -t nat -S 2>/dev/null | grep -vE 'DOCKER' | head -40; }
has ip6tables && { echo "-- ipv6"; ip6tables -S 2>/dev/null | head -40; }
has nft && { echo "-- nft tables"; nft list tables 2>/dev/null; }

sec SSH
has sshd && sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|allowusers|allowgroups) '
ls /etc/ssh/sshd_config.d/ 2>/dev/null
for d in /root /home/*; do
  [ -f "$d/.ssh/authorized_keys" ] && echo "authorized_keys $d: $(grep -cvE '^\s*(#|$)' "$d/.ssh/authorized_keys") keys" && \
    ssh-keygen -lf "$d/.ssh/authorized_keys" 2>/dev/null | sed 's/^/  /'
done

sec USERS
awk -F: '$7 ~ /(bash|zsh|fish|dash|ksh|csh|\/sh)$/ {print $1, $3, $6, $7}' /etc/passwd
getent group sudo docker wheel 2>/dev/null

sec PACKAGES
if has apt-mark; then echo "manual: $(apt-mark showmanual 2>/dev/null | tr '\n' ' ')"; echo "held: $(apt-mark showhold 2>/dev/null | tr '\n' ' ')";
  dpkg-query -W -f='${Package}=${Version}\n' docker-ce docker-ce-cli containerd.io docker-compose-plugin nginx apache2 caddy postgresql mysql-server mariadb-server redis-server 2>/dev/null
  ls /etc/apt/sources.list.d/ 2>/dev/null
elif has dnf; then dnf repoquery --userinstalled -q 2>/dev/null | tr '\n' ' '; echo
elif has rpm; then rpm -qa --qf '%{NAME}\n' | sort | tr '\n' ' '; echo; fi
has snap && snap list 2>/dev/null

sec SERVICES_ENABLED; systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' '; echo
sec SERVICES_RUNNING; systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' '; echo
sec SERVICES_FAILED; systemctl --failed --no-legend 2>/dev/null
sec CUSTOM_UNITS; find /etc/systemd/system -maxdepth 2 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.conf' \) 2>/dev/null
sec TIMERS; systemctl list-timers --all --no-legend 2>/dev/null | awk '{print $(NF-1), $NF}' | head -40

sec CRON
grep -vE '^\s*(#|$)' /etc/crontab 2>/dev/null
for f in /etc/cron.d/*; do [ -f "$f" ] && { echo "-- $f"; grep -vE '^\s*(#|$)' "$f"; }; done
for f in /var/spool/cron/crontabs/* /var/spool/cron/*; do [ -f "$f" ] && { echo "-- crontab $(basename "$f")"; grep -vE '^\s*(#|$)' "$f"; }; done

sec SYSCTL_CUSTOM
grep -hvE '^\s*(#|;|$)' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null | sort | uniq -c
sysctl vm.overcommit_memory vm.swappiness vm.max_map_count net.core.somaxconn fs.file-max 2>/dev/null

sec LIMITS; grep -hvE '^\s*(#|$)' /etc/security/limits.conf /etc/security/limits.d/*.conf 2>/dev/null

sec WEB_SERVERS
if has nginx; then nginx -v 2>&1; t nginx -T 2>/dev/null | grep -E '^\s*(server_name|listen|root|proxy_pass)\s' | sort | uniq -c | head -80; fi
has apache2ctl && t apache2ctl -S 2>/dev/null | head -60
has caddy && { caddy version; ls /etc/caddy 2>/dev/null; }
if [ -d /etc/letsencrypt/live ]; then for d in /etc/letsencrypt/live/*/; do
  [ -f "$d/cert.pem" ] && echo "letsencrypt $(basename "$d"): $(openssl x509 -in "$d/cert.pem" -noout -enddate -ext subjectAltName 2>/dev/null | tr '\n' ' ')"; done; fi

sec DATABASES_NATIVE
for s in postgresql mysql mariadb mongod redis-server redis memcached rabbitmq-server elasticsearch; do
  st=$(systemctl is-active "$s" 2>/dev/null); [ "$st" = active ] && echo "$s=active"; done
has psql && t sudo -n -u postgres psql -Atc "select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate" 2>/dev/null
has mysql && t mysql -N -e "select table_schema, round(sum(data_length+index_length)/1024/1024,1) from information_schema.tables group by 1" 2>/dev/null

if has docker; then
  sec DOCKER
  docker version --format 'client={{.Client.Version}} server={{.Server.Version}}' 2>/dev/null
  docker info --format 'storage={{.Driver}} logdriver={{.LoggingDriver}} cgroup={{.CgroupDriver}} root={{.DockerRootDir}} swarm={{.Swarm.LocalNodeState}} manager={{.Swarm.ControlAvailable}} nodeaddr={{.Swarm.NodeAddr}}' 2>/dev/null
  echo "-- daemon.json"; cat /etc/docker/daemon.json 2>/dev/null; echo
  ls /etc/systemd/system/docker.service.d/ 2>/dev/null
  sec DOCKER_CONTAINERS; docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
  sec DOCKER_IMAGES; docker images --digests --format '{{.Repository}}:{{.Tag}}\t{{.Digest}}\t{{.ID}}\t{{.Size}}' 2>/dev/null
  sec DOCKER_VOLUMES
  for v in $(docker volume ls -q 2>/dev/null); do
    mp=$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null)
    echo "$v driver=$(docker volume inspect -f '{{.Driver}}' "$v") size=$(T=60 t du -sh "$mp" 2>/dev/null | cut -f1)"
  done
  sec DOCKER_NETWORKS; docker network ls --format '{{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>/dev/null
  sec COMPOSE_PROJECTS
  docker ps -a --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | grep -v '^||$' | sort -u
  if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = active ] && [ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" = true ]; then
    sec SWARM_NODES; docker node ls --format '{{.Hostname}}\t{{.Status}}\t{{.Availability}}\t{{.ManagerStatus}}\t{{.EngineVersion}}' 2>/dev/null
    for n in $(docker node ls -q); do docker node inspect "$n" --format '{{.Description.Hostname}} addr={{.Status.Addr}} role={{.Spec.Role}} labels={{json .Spec.Labels}} cpus={{.Description.Resources.NanoCPUs}} mem={{.Description.Resources.MemoryBytes}}'; done
    sec SWARM_STACKS; docker stack ls 2>/dev/null
    sec SWARM_SERVICES
    docker service ls --format '{{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null
    for s in $(docker service ls -q); do
      docker service inspect "$s" --format '{{.Spec.Name}} constraints={{json .Spec.TaskTemplate.Placement.Constraints}} mounts={{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Source}}:{{.Target}} {{end}}'
      docker service ps "$s" --filter desired-state=running --format '    on {{.Node}} {{.CurrentState}}' 2>/dev/null | head -3
    done
    sec SWARM_SECRETS_CONFIGS; docker secret ls --format 'secret {{.Name}}' 2>/dev/null; docker config ls --format 'config {{.Name}}' 2>/dev/null
  fi
  sec PORTAINER
  for v in $(docker volume ls -q | grep -i portainer); do
    mp=$(docker volume inspect -f '{{.Mountpoint}}' "$v"); [ -d "$mp/compose" ] && { echo "volume $v compose dir: $mp/compose"; ls "$mp/compose"; }
  done
  sec STACK_FILES_ON_DISK
  find /root /opt /srv /home -maxdepth 3 -type f \( -name '*compose*.y*ml' -o -name '*stack*.y*ml' -o -name 'traefik*.y*ml' -o -name 'portainer*.y*ml' \) 2>/dev/null | head -60
  sec DATABASES_IN_CONTAINERS
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    img=$(docker inspect -f '{{.Config.Image}}' "$c")
    case "$img" in
      *postgres*|*postgis*|*timescale*) echo "-- $c ($img)"; t docker exec "$c" sh -c 'psql -U "${POSTGRES_USER:-postgres}" -Atc "select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate"' 2>&1 | head -30;;
      *mysql*|*mariadb*|*percona*) echo "-- $c ($img)"; t docker exec "$c" sh -c 'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" mysql -uroot -N -e "select table_schema, round(sum(data_length+index_length)/1024/1024,1) from information_schema.tables group by 1" 2>&1 || MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" mariadb -uroot -N -e "select table_schema, round(sum(data_length+index_length)/1024/1024,1) from information_schema.tables group by 1"' 2>&1 | head -30;;
      *mongo*) echo "-- $c ($img)"; t docker exec "$c" sh -c 'mongosh --quiet --eval "db.adminCommand({listDatabases:1}).databases.forEach(d=>print(d.name, d.sizeOnDisk))" 2>/dev/null' | head -30;;
      *redis*|*valkey*|*keydb*) echo "-- $c ($img)"; t docker exec "$c" sh -c 'redis-cli INFO keyspace 2>/dev/null' | head -20;;
    esac
  done
fi

sec BIG_DIRS
for d in /var/www /opt /srv /home /root /var/lib/docker/volumes /var/lib/postgresql /var/lib/mysql; do
  [ -d "$d" ] && T=60 t du -xsh "$d" 2>/dev/null
done
echo; echo "##### END"
