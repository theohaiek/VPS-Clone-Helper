#!/usr/bin/env python3
"""sshx.py - SSH/SFTP helper for cloning VPSs (paramiko). Works on Windows, macOS and Linux.

Hosts live in $VPSCLONE_DIR/hosts.json (default: ./.vps-clone/hosts.json). That folder holds
secrets: it is created with its own .gitignore and must never be committed or pasted anywhere.

Usage:
  sshx.py add <alias> <ip> [--user root] [--port 22] [--key PATH | --password-env VAR | --password PW]
                           [--sudo] [--role source|target] [--note TEXT]
  sshx.py list
  sshx.py forget <alias>                      drop the pinned host key (after rebuilding a server)
  sshx.py check <alias>                       read-only: login, whoami, sudo, OS, CPU/RAM/disk, docker
  sshx.py <alias> '<command>'                 run; remote stdout -> stdout, stderr -> stderr, exit code = remote rc
  sshx.py <alias> --script FILE [ARGS...]     run a local bash script remotely (bash -s -- ARGS)
  sshx.py <alias> --put LOCAL REMOTE          upload one file (scripts/configs get CRLF -> LF)
  sshx.py <alias> --put-tree LOCALDIR REMOTEDIR
  sshx.py <alias> --get REMOTE LOCAL
  sshx.py pipe <src> '<cmd>' <dst> '<cmd>'    stream src stdout into dst stdin through this machine
                                              (e.g. docker save | docker load, pg_dump | psql) - no key on the source
Options: --timeout SEC (default none), --allow-write (see below), --binary (no CRLF fix on put). Put them
anywhere before "--script FILE"; everything after FILE is passed to the script untouched.

Output is byte-exact: nothing is appended to stdout, so `sshx.py a 'tar czf - /etc' > etc.tgz` is safe.
Hosts with role "source" are the server being cloned and are READ-ONLY: commands that look like they
change state are refused unless --allow-write is given (data-mode dumps in /tmp, then deleting them).
"""
import json
import os
import posixpath
import re
import shlex
import stat
import sys
import time

try:
    import paramiko
except ImportError:  # pragma: no cover
    sys.stderr.write("[sshx] paramiko missing: run  python -m pip install --user paramiko\n")
    sys.exit(3)

def localpath(p):
    """Git Bash hands native Windows Python MSYS paths like /c/Users/x (MSYS_NO_PATHCONV=1 disables the
    automatic conversion). Python would read that as C:\\c\\Users\\x. Convert to C:/Users/x."""
    if os.name == "nt" and p:
        m = re.match(r"^/([a-zA-Z])(/.*)?$", p)
        if m:
            return f"{m.group(1).upper()}:{m.group(2) or '/'}"
    return p


DIR = os.path.abspath(localpath(os.environ.get("VPSCLONE_DIR", ".vps-clone")))
HOSTS = os.path.join(DIR, "hosts.json")
KNOWN = os.path.join(DIR, "known_hosts")
TEXT_EXT = {".sh", ".bash", ".py", ".yml", ".yaml", ".json", ".conf", ".cfg", ".env", ".ini",
            ".service", ".timer", ".txt", ".md", ".sql", ".toml", ".j2", ".tpl", ".cron"}

# Best-effort guard for the source server. It only has to catch honest mistakes.
MUTATING = re.compile(
    r"(^|[;&|`(\"']\s*|\s)("
    r"rm\s|rmdir\s|mv\s|dd\s|mkfs|shutdown|reboot|poweroff|halt\b|kill\s|pkill\s|killall\s|"
    r"systemctl\s+(start|stop|restart|reload|enable|disable|mask|daemon-reload)|service\s+\S+\s+(start|stop|restart|reload)|"
    r"apt(-get)?\s+(install|remove|purge|upgrade|dist-upgrade|autoremove)|dnf\s+(install|remove|upgrade)|yum\s+(install|remove|update)|"
    r"pip3?\s+install|npm\s+(install|i)\s|"
    r"docker\s+(rm|rmi|stop|kill|restart|pause|update|prune|system\s+prune|volume\s+(rm|prune|create)|network\s+(rm|create|prune)|"
    r"service\s+(rm|update|scale|create|rollback)|stack\s+(rm|deploy)|swarm\s+(init|join|leave|update)|node\s+(rm|update|demote|promote)|"
    r"compose\s+(up|down|rm|stop|restart|pull|build)|run\s|exec\s+\S+\s+(rm|mysql\s.*(drop|delete|update|insert|alter)))|"
    r"iptables\s+-[AIDFNXP]|ufw\s+(allow|deny|enable|disable|delete|reset)|nft\s+(add|delete|flush)|"
    r"crontab\s+-[er]|useradd|userdel|usermod|passwd|chown\s|chmod\s|chattr|truncate\s|tee\s+(-a\s+)?/(etc|root|var|usr|opt|srv)|"
    r"sed\s+-i|>\s*/(etc|root|var|usr|opt|srv|home)|DROP\s+(DATABASE|TABLE|USER)|ALTER\s+USER|TRUNCATE\s"
    r")", re.IGNORECASE)


def die(msg, code=2):
    sys.stderr.write(f"[sshx] {msg}\n")
    sys.exit(code)


def ensure_dir():
    os.makedirs(DIR, exist_ok=True)
    gi = os.path.join(DIR, ".gitignore")
    if not os.path.exists(gi):
        with open(gi, "w", encoding="utf-8") as f:
            f.write("# secrets and job state - never commit\n*\n")


def load_hosts():
    if not os.path.exists(HOSTS):
        return {}
    with open(HOSTS, encoding="utf-8") as f:
        return json.load(f)


def save_hosts(h):
    ensure_dir()
    with open(HOSTS, "w", encoding="utf-8") as f:
        json.dump(h, f, indent=2)
    try:
        os.chmod(HOSTS, 0o600)
    except OSError:
        pass


def resolve(alias):
    """alias -> dict(host, port, user, key, password, sudo, role)."""
    hosts = load_hosts()
    if alias in hosts:
        h = dict(hosts[alias])
    else:
        m = re.match(r"^(?:([^@]+)@)?([^:@]+)(?::(\d+))?$", alias)
        if not m:
            die(f"unknown host '{alias}' (add it with: sshx.py add {alias} <ip> ...)")
        h = {"user": m.group(1) or "root", "host": m.group(2), "port": int(m.group(3) or 22)}
        for k, v in hosts.items():  # literal IP of a known alias inherits its settings
            if v.get("host") == h["host"]:
                h = dict(v)
                break
    h.setdefault("port", 22)
    h.setdefault("user", "root")
    if h.get("key"):
        h["key"] = localpath(h["key"])
        if not os.path.isabs(h["key"]):  # relative to the workspace, else to the current dir
            in_ws = os.path.join(DIR, h["key"])
            h["key"] = in_ws if os.path.exists(in_ws) or not os.path.exists(h["key"]) else os.path.abspath(h["key"])
    if h.get("password_env"):
        h["password"] = os.environ.get(h["password_env"]) or h.get("password")
        if not h["password"]:
            die(f"env var {h['password_env']} is empty (password for {alias})")
    return h


class PinPolicy(paramiko.MissingHostKeyPolicy):
    """accept-new: first key seen is pinned in $VPSCLONE_DIR/known_hosts; a changed key is refused."""

    def missing_host_key(self, client, hostname, key):
        ensure_dir()
        client.get_host_keys().add(hostname, key.get_name(), key)
        client.save_host_keys(KNOWN)


def connect(h, tries=8):
    last = None
    for i in range(tries):
        c = paramiko.SSHClient()
        if os.path.exists(KNOWN):
            c.load_host_keys(KNOWN)
        c.set_missing_host_key_policy(PinPolicy())
        kw = dict(port=int(h["port"]), username=h["user"], timeout=25, banner_timeout=40, auth_timeout=40)
        if h.get("password"):
            kw.update(password=h["password"], look_for_keys=False, allow_agent=False)
        elif h.get("key"):
            kw.update(key_filename=h["key"], look_for_keys=False, allow_agent=False)
        try:
            c.connect(h["host"], **kw)
            return c
        except paramiko.BadHostKeyException:
            die(f"host key of {h['host']} CHANGED. If you rebuilt that server: sshx.py forget <alias>. "
                f"Otherwise stop: possible MITM.", 4)
        except paramiko.AuthenticationException as e:
            die(f"authentication failed for {h['user']}@{h['host']}: {e}", 5)
        except Exception as e:  # network not up yet, server booting, etc.
            last = e
            time.sleep(min(2 ** i, 20))
    die(f"cannot connect to {h['host']}:{h['port']} after {tries} tries: {last}", 6)


def wrap(h, cmd):
    if h.get("sudo") and h.get("user") != "root":
        return "sudo -n bash -c " + shlex.quote(cmd)
    return cmd


def run(c, cmd, stdin_data=None, timeout=None, out=None, err=None):
    """Stream remote output as it arrives. Returns the remote exit code."""
    out = out or sys.stdout.buffer
    err = err or sys.stderr.buffer
    chan = c.get_transport().open_session()
    chan.exec_command(cmd)
    if stdin_data is not None:
        chan.sendall(stdin_data)
        chan.shutdown_write()
    start = time.time()
    while True:
        busy = False
        while chan.recv_ready():
            out.write(chan.recv(65536)); busy = True
        while chan.recv_stderr_ready():
            err.write(chan.recv_stderr(65536)); busy = True
        if chan.exit_status_ready() and not chan.recv_ready() and not chan.recv_stderr_ready():
            break
        if timeout and time.time() - start > timeout:
            chan.close()
            die(f"timeout after {timeout}s", 124)
        if not busy:
            time.sleep(0.05)
    out.flush(); err.flush()
    return chan.recv_exit_status()


def guard(h, alias, cmd, allow):
    if h.get("role") == "source" and not allow and MUTATING.search(cmd):
        die(f"refused: '{alias}' is the SOURCE (read-only) and this command looks like it changes state:\n  {cmd[:300]}\n"
            f"If it only writes temporary dumps under /tmp (data mode) or removes them, repeat with --allow-write.", 7)


def put_file(sftp, local, remote, binary=False):
    local = localpath(local)
    with open(local, "rb") as f:
        data = f.read()
    if not binary and os.path.splitext(local)[1].lower() in TEXT_EXT:
        data = data.replace(b"\r\n", b"\n")
    with sftp.open(remote, "wb") as f:
        f.write(data)
    mode = os.stat(local).st_mode
    if local.endswith((".sh", ".py")) or mode & stat.S_IXUSR:
        sftp.chmod(remote, 0o755)


def mkdirs(sftp, path):
    parts, cur = path.strip("/").split("/"), ""
    for p in parts:
        cur += "/" + p
        try:
            sftp.stat(cur)
        except IOError:
            sftp.mkdir(cur)


def cmd_pipe(a, allow, timeout):
    """src stdout -> dst stdin, streamed in chunks; progress on stderr. Exit code = first non-zero rc."""
    if len(a) != 4:
        die("usage: sshx.py pipe <src> '<cmd>' <dst> '<cmd>'")
    (sa, scmd, da, dcmd) = a
    sh, dh = resolve(sa), resolve(da)
    guard(sh, sa, scmd, allow)
    guard(dh, da, dcmd, allow)
    sc, dc = connect(sh), connect(dh)
    src = sc.get_transport().open_session(); src.exec_command(wrap(sh, scmd))
    dst = dc.get_transport().open_session(); dst.exec_command(wrap(dh, dcmd))
    total, last, start = 0, 0, time.time()
    while True:
        moved = False
        while src.recv_ready():
            chunk = src.recv(1 << 20); moved = True
            dst.sendall(chunk); total += len(chunk)
        while src.recv_stderr_ready():
            sys.stderr.buffer.write(src.recv_stderr(65536)); moved = True
        while dst.recv_ready():
            sys.stdout.buffer.write(dst.recv(65536)); moved = True
        while dst.recv_stderr_ready():
            sys.stderr.buffer.write(dst.recv_stderr(65536)); moved = True
        if total - last >= 256 << 20:
            last = total
            sys.stderr.write(f"[sshx] pipe {total >> 20} MiB ({(total >> 20) / max(time.time() - start, 1):.1f} MiB/s)\n")
        if src.exit_status_ready() and not src.recv_ready() and not src.recv_stderr_ready():
            break
        if timeout and time.time() - start > timeout:
            die(f"pipe timeout after {timeout}s", 124)
        if not moved:
            time.sleep(0.02)
    dst.shutdown_write()
    while not dst.exit_status_ready() or dst.recv_ready() or dst.recv_stderr_ready():
        if dst.recv_ready():
            sys.stdout.buffer.write(dst.recv(65536))
        elif dst.recv_stderr_ready():
            sys.stderr.buffer.write(dst.recv_stderr(65536))
        else:
            time.sleep(0.05)
    rs, rd = src.recv_exit_status(), dst.recv_exit_status()
    sys.stdout.flush(); sys.stderr.flush()
    sys.stderr.write(f"[sshx] pipe done: {total >> 20} MiB in {time.time() - start:.0f}s  src_rc={rs} dst_rc={rd}\n")
    sc.close(); dc.close()
    sys.exit(rs or rd)


def cmd_add(a):
    if len(a) < 2:
        die("usage: sshx.py add <alias> <ip> [--user U] [--port N] [--key PATH|--password-env VAR|--password PW] [--sudo] [--role source|target]")
    alias, host, rest = a[0], a[1], a[2:]
    h = {"host": host, "port": 22, "user": "root", "role": "target"}
    i = 0
    while i < len(rest):
        k = rest[i]
        if k == "--sudo":
            h["sudo"] = True; i += 1; continue
        if i + 1 >= len(rest):
            die(f"missing value for {k}")
        v = rest[i + 1]
        if k == "--port":
            h["port"] = int(v)
        elif k in ("--user", "--key", "--password", "--role", "--note"):
            h[k[2:]] = v
        elif k == "--password-env":
            h["password_env"] = v
        else:
            die(f"unknown option {k}")
        i += 2
    if h["role"] not in ("source", "target"):
        die("--role must be source or target")
    hosts = load_hosts()
    hosts[alias] = h
    save_hosts(hosts)
    print(f"saved {alias} -> {h['user']}@{host}:{h['port']} role={h['role']} in {HOSTS}")


def cmd_list():
    for k, v in load_hosts().items():
        auth = "key" if v.get("key") else ("password-env" if v.get("password_env") else ("password" if v.get("password") else "agent"))
        print(f"{k:14} {v.get('user','root')}@{v['host']}:{v.get('port',22):<5} role={v.get('role','target'):6} auth={auth:12} {v.get('note','')}")


def cmd_forget(alias):
    h = resolve(alias)
    if not os.path.exists(KNOWN):
        return
    keys = paramiko.HostKeys(KNOWN)
    names = [h["host"], f"[{h['host']}]:{h['port']}"]
    for n in names:
        if n in keys:
            del keys[n]
    keys.save(KNOWN)
    print(f"forgot host key of {h['host']}")


CHECK = r"""
echo "user=$(whoami) uid=$(id -u)"
if [ "$(id -u)" = 0 ]; then echo "root=yes"; elif sudo -n true 2>/dev/null; then echo "root=sudo-nopasswd"; else echo "root=NO"; fi
. /etc/os-release 2>/dev/null; echo "os=${PRETTY_NAME:-unknown} kernel=$(uname -r) arch=$(uname -m)"
echo "cpu=$(nproc) mem_mb=$(free -m | awk '/Mem:/{print $2}') swap_mb=$(free -m | awk '/Swap:/{print $2}')"
df -hP / | awk 'NR==2{print "disk_root="$2" used="$5}'
echo "hostname=$(hostname) tz=$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null)"
if command -v docker >/dev/null 2>&1; then
  echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null) swarm=$(docker info --format '{{.Swarm.LocalNodeState}} manager={{.Swarm.ControlAvailable}}' 2>/dev/null)"
else echo "docker=none"; fi
"""


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); return
    timeout, allow, binary = None, False, False
    # Global options are read only up to "--script FILE": whatever follows belongs to the script.
    end = a.index("--script") + 2 if "--script" in a else len(a)
    head, tail = a[:end], a[end:]
    if "--timeout" in head:
        i = head.index("--timeout"); timeout = float(head[i + 1]); del head[i:i + 2]
    if "--allow-write" in head:
        head.remove("--allow-write"); allow = True
    if "--binary" in head:
        head.remove("--binary"); binary = True
    a = head + tail
    if a[0] == "add":
        return cmd_add(a[1:])
    if a[0] == "list":
        return cmd_list()
    if a[0] == "forget":
        return cmd_forget(a[1])
    if a[0] == "pipe":
        return cmd_pipe(a[1:], allow, timeout)
    if a[0] == "check":
        h = resolve(a[1]); c = connect(h, tries=3)
        rc = run(c, CHECK, timeout=timeout or 60); c.close(); sys.exit(rc)
    if len(a) < 2:
        die("usage: sshx.py <alias> '<command>' | --script F | --put L R | --put-tree L R | --get R L")
    alias, op = a[0], a[1]
    h = resolve(alias)
    if op == "--put":
        if h.get("role") == "source" and not allow:
            die("refused: uploading to the SOURCE server (read-only). Use --allow-write if this is a temp file in /tmp.", 7)
        c = connect(h); s = c.open_sftp(); put_file(s, a[2], a[3], binary); s.close(); c.close()
        sys.stderr.write(f"[sshx] put {a[2]} -> {alias}:{a[3]}\n"); return
    if op == "--put-tree":
        if h.get("role") == "source" and not allow:
            die("refused: uploading to the SOURCE server (read-only).", 7)
        local, remote = localpath(a[2]), a[3].rstrip("/")
        c = connect(h); s = c.open_sftp(); mkdirs(s, remote); n = 0
        for root, dirs, files in os.walk(local):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            rel = os.path.relpath(root, local).replace("\\", "/")
            rdir = remote if rel == "." else posixpath.join(remote, rel)
            mkdirs(s, rdir)
            for f in files:
                if f.startswith("."):
                    continue
                put_file(s, os.path.join(root, f), posixpath.join(rdir, f), binary); n += 1
        s.close(); c.close()
        sys.stderr.write(f"[sshx] put-tree {local} -> {alias}:{remote} ({n} files)\n"); return
    if op == "--get":
        c = connect(h); s = c.open_sftp(); s.get(a[2], localpath(a[3])); s.close(); c.close()
        sys.stderr.write(f"[sshx] get {alias}:{a[2]} -> {a[3]}\n"); return
    if op == "--script":
        with open(localpath(a[2]), "rb") as f:
            script = f.read().replace(b"\r\n", b"\n")
        args = " ".join(shlex.quote(x) for x in a[3:])
        guard(h, alias, script.decode("utf-8", "replace"), allow)
        cmd = wrap(h, f"bash -s -- {args}".strip())
        c = connect(h); rc = run(c, cmd, stdin_data=script, timeout=timeout); c.close()
    else:
        cmd = " ".join(a[1:])
        guard(h, alias, cmd, allow)
        c = connect(h); rc = run(c, wrap(h, cmd), timeout=timeout); c.close()
    if rc:
        sys.stderr.write(f"[sshx] {alias}: exit {rc}\n")
    sys.exit(rc)


if __name__ == "__main__":
    main()
