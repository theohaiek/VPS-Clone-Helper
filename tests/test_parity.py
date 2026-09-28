"""parity.py on synthetic exports: identical after domain mapping + rotated secret -> SAME; real drift -> DIFF/MISSING."""
import copy
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARITY = os.path.join(ROOT, "skills", "vps-clone", "scripts", "parity.py")
DIG = "sha256:" + "d" * 64


def svc(name, env, replicas=1, host="app.old.example.com"):
    return [{
        "ID": "id-" + name, "Version": {"Index": 7}, "CreatedAt": "2026-01-01T00:00:00Z", "UpdatedAt": "2026-01-02T00:00:00Z",
        "Spec": {
            "Name": name,
            "Labels": {"traefik.http.routers.app.rule": f"Host(`{host}`)"},
            "TaskTemplate": {"ContainerSpec": {"Image": f"ghcr.io/acme/app:1.2@{DIG}", "Env": env},
                             "Placement": {"Constraints": ["node.role == manager"]}},
            "Mode": {"Replicated": {"Replicas": replicas}},
        },
        "Endpoint": {"VirtualIPs": [{"Addr": "10.0.1.5/24"}]},
    }]


def write_export(d, services, nodes):
    os.makedirs(os.path.join(d, "swarm", "services"))
    for s in services:
        with open(os.path.join(d, "swarm", "services", s[0]["Spec"]["Name"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(s, f)
    with open(os.path.join(d, "swarm", "nodes.json"), "w", encoding="utf-8") as f:
        json.dump(nodes, f)


def node(hostname, role):
    return {"ID": "n-" + hostname, "Spec": {"Role": role, "Labels": {}, "Availability": "active"},
            "Description": {"Hostname": hostname}}


def run(*a):
    return subprocess.run([sys.executable, PARITY, *a], capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=dict(os.environ, PYTHONUTF8="1"))


def main():
    with tempfile.TemporaryDirectory() as t:
        src, same, drift = (os.path.join(t, x) for x in ("src", "same", "drift"))
        nodes = [node("manager01", "manager"), node("database01", "worker")]
        s_app = svc("app_app", ["DB_PASSWORD=OldSecretPass123", "URL=https://app.old.example.com"])
        s_db = svc("db_db", ["POSTGRES_PASSWORD=OldSecretPass123"])
        write_export(src, [s_app, s_db], nodes)

        t_app = svc("app_app", ["DB_PASSWORD=NewSecretPass4567", "URL=https://app.new.example.org"], host="app.new.example.org")
        t_app[0]["ID"] = "other"; t_app[0]["Version"]["Index"] = 99
        t_db = svc("db_db", ["POSTGRES_PASSWORD=NewSecretPass4567"], host="app.new.example.org")
        write_export(same, [t_app, t_db], copy.deepcopy(nodes))

        d_app = copy.deepcopy(t_app); d_app[0]["Spec"]["Mode"]["Replicated"]["Replicas"] = 3
        d_app[0]["Spec"]["TaskTemplate"]["ContainerSpec"]["Env"].append("ERLANG_COOKIE_X=Zq8vT2mW9kR4pL7nB3xY")
        write_export(drift, [d_app], [node("manager01", "manager")])

        mapping = os.path.join(t, "mapping.json")
        json.dump({"replace": {"old.example.com": "new.example.org"}}, open(mapping, "w", encoding="utf-8"))
        secrets = os.path.join(t, "secrets.json")
        json.dump({"OldSecretPass123": "NewSecretPass4567"}, open(secrets, "w", encoding="utf-8"))

        r = run(src, same, "--mapping", mapping, "--secrets", secrets)
        assert r.returncode == 0, r.stdout + r.stderr
        r = run(src, drift, "--mapping", mapping, "--secrets", secrets, "--json")
        assert r.returncode == 1, r.stdout + r.stderr
        out = r.stdout
        json.loads(out)  # --json must be valid JSON
        assert "MISSING_ON_TARGET" in out and "Replicas" in out, out
        assert "OldSecretPass123" not in out and "NewSecretPass4567" not in out, "secret printed"
        assert "Zq8vT2mW9kR4pL7nB3xY" not in out, "random-looking value printed in clear"
    print("parity ok")


if __name__ == "__main__":
    main()
