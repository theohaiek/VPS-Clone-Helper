"""sshx.py: host registry, workspace .gitignore, source guard. No network needed."""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "skills", "vps-clone", "scripts")
sys.path.insert(0, SCRIPTS)
import sshx  # noqa: E402

GUARD = {
    "docker service ls": False, "docker service ps x --no-trunc": False, "docker ps -a": False,
    "docker save repo/img:tag": False, "docker volume ls": False, "cat /etc/hosts": False,
    "systemctl status docker": False, "pg_dumpall -U postgres": False, "iptables -S": False,
    "tar czf - -C /var/lib/docker/volumes/v/_data .": False, "mysqldump --all-databases": False,
    "docker service update --force x": True, "rm -rf /tmp/x": True, "systemctl restart docker": True,
    "echo x > /etc/foo": True, "sed -i s/a/b/ /etc/x": True, "apt-get install -y jq": True,
    "docker stack deploy -c a.yml a": True, "docker compose up -d": True, "iptables -I INPUT 1 -j X": True,
    "reboot": True, "docker volume rm v": True,
    "docker exec x psql -U postgres -c \"DROP TABLE sessions\"": True, "bash -c 'rm -rf /srv/x'": True,
    "sh -c \"systemctl restart nginx\"": True, "echo 'hello world'": False, "grep 'x' /etc/hosts": False,
}


def main():
    if os.name == "nt":
        assert sshx.localpath("/c/Users/x") == "C:/Users/x"
        assert sshx.localpath("/d") == "D:/"
    assert sshx.localpath("/root/vps-clone") == "/root/vps-clone"
    assert sshx.localpath("relative/dir") == "relative/dir"
    bad = [(c, e) for c, e in GUARD.items() if bool(sshx.MUTATING.search(c)) != e]
    assert not bad, f"guard mismatches: {bad}"
    for name in ("inventory.sh", "export_docker.sh"):
        text = open(os.path.join(SCRIPTS, "remote", name), encoding="utf-8").read()
        hits = [m.group(0) for m in sshx.MUTATING.finditer(text)]
        assert not hits, f"read-only script {name} trips the source guard: {hits}"

    with tempfile.TemporaryDirectory() as t:
        env = dict(os.environ, VPSCLONE_DIR=os.path.join(t, "ws"), PYTHONUTF8="1")
        run = lambda *a: subprocess.run([sys.executable, os.path.join(SCRIPTS, "sshx.py"), *a],
                                        env=env, capture_output=True, text=True)
        r = run("add", "src1", "203.0.113.10", "--password", "pw", "--role", "source")
        assert r.returncode == 0, r.stderr
        r = run("add", "tgt1", "198.51.100.20", "--key", "keys/id_ed25519", "--port", "2222")
        assert r.returncode == 0, r.stderr
        hosts = json.load(open(os.path.join(t, "ws", "hosts.json"), encoding="utf-8"))
        assert hosts["src1"]["role"] == "source" and hosts["tgt1"]["port"] == 2222
        assert open(os.path.join(t, "ws", ".gitignore"), encoding="utf-8").read().strip().endswith("*")
        r = run("list")
        assert "src1" in r.stdout and "pw" not in r.stdout, "list must not print passwords"
        r = run("src1", "docker service update --force x")
        assert r.returncode == 7 and "refused" in r.stderr, "source guard must refuse before connecting"
        r = run("add", "x", "1.2.3.4", "--role", "bogus")
        assert r.returncode != 0
    print("sshx ok")


if __name__ == "__main__":
    main()
