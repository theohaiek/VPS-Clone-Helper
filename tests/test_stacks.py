"""stacks.py end to end on a synthetic export: unpack -> names -> pins -> render (+ re-render), traversal guard."""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STACKS = os.path.join(ROOT, "skills", "vps-clone", "scripts", "stacks.py")
OLD_PW = "OldSecretPass123"
D_APP = "sha256:" + "a" * 64
D_DB = "sha256:" + "b" * 64
D_TR = "sha256:" + "c" * 64


def service(name, image):
    return json.dumps([{"ID": "x", "Spec": {"Name": name, "TaskTemplate": {"ContainerSpec": {"Image": image}}}}])


def stream():
    files = {
        "swarm/services/app_app.json": service("app_app", f"ghcr.io/acme/app:1.2@{D_APP}"),
        "swarm/services/db_db.json": service("db_db", f"postgres:16@{D_DB}"),
        "swarm/services/traefik_traefik.json": service("traefik_traefik", f"traefik:v2.11.57@{D_TR}"),
        "portainer/3/docker-compose.yml": f"""version: "3.7"
services:
  app:
    image: ghcr.io/acme/app:1.2
    environment:
      - DB_URL=postgres://app:{OLD_PW}@db:5432/app
      - DB_PASSWORD={OLD_PW}
      - APP_KEY=base64:keepThisIdentityKey000
      - LOG_LEVEL=debug
    deploy:
      labels:
        - traefik.http.routers.app.rule=Host(`app.old.example.com`)
""",
        "portainer/4/docker-compose.yml": f"""services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: "{OLD_PW}"
""",
        "disk/opt/shop/docker-compose.yml": """services:
  shop:
    image: ghcr.io/acme/shop:3
    env_file: .env
""",
        "disk/opt/shop/.env": f"""DB_PASSWORD={OLD_PW}
SHOP_URL=https://shop.old.example.com
""",
        "disk/root/traefik.yml": """services:
  traefik:
    image: traefik:v2.11.57
    command:
      - "--log.level=INFO"
      - "--log.filePath=/var/log/traefik/traefik.log"
""",
    }
    return "".join(f"@@@VPSCLONE-FILE {k}@@@\n{v}\n" for k, v in files.items())


def run(*a):
    return subprocess.run([sys.executable, STACKS, *a], capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=dict(os.environ, PYTHONUTF8="1"))


def main():
    with tempfile.TemporaryDirectory() as t:
        s = os.path.join(t, "src.stream")
        with open(s, "w", encoding="utf-8", newline="\n") as f:
            f.write(stream())
        exp, ren = os.path.join(t, "export"), os.path.join(t, "render")
        os.makedirs(ren)
        r = run("unpack", s, exp)
        assert r.returncode == 0, r.stderr
        assert os.path.exists(os.path.join(exp, "portainer", "3", "docker-compose.yml"))

        names = os.path.join(ren, "names.json")
        r = run("names", exp, "--write", names)
        assert r.returncode == 0, r.stderr
        n = json.load(open(names, encoding="utf-8"))
        assert n.get("portainer/3/docker-compose.yml") == "app", n
        assert n.get("portainer/4/docker-compose.yml") == "db", n
        assert n.get("disk/root/traefik.yml") == "traefik", n

        pins = os.path.join(ren, "pins.json")
        r = run("pins", exp, "--write", pins)
        assert r.returncode == 0, r.stderr
        p = json.load(open(pins, encoding="utf-8"))
        assert p.get("ghcr.io/acme/app:1.2", "").endswith(D_APP), p

        mapping = os.path.join(ren, "mapping.json")
        json.dump({
            "replace": {"old.example.com": "new.example.org"},
            "rotate_env": ["POSTGRES_PASSWORD", "DB_PASSWORD"],
            "keep_env": ["APP_KEY"],
            "set_env": {"LOG_LEVEL": "info"},
            "drop_lines_matching": ["--log.filePath="],
        }, open(mapping, "w", encoding="utf-8"))
        out, secrets = os.path.join(ren, "stacks"), os.path.join(ren, "secrets.json")
        args = ("render", "--src", exp, "--names", names, "--mapping", mapping, "--pins", pins,
                "--secrets", secrets, "--out", out)
        r = run(*args)
        assert r.returncode == 0, r.stdout + r.stderr
        assert OLD_PW not in r.stdout + r.stderr, "secret printed"
        app = open(os.path.join(out, "app.yml"), encoding="utf-8").read()
        db = open(os.path.join(out, "db.yml"), encoding="utf-8").read()
        tr = open(os.path.join(out, "traefik.yml"), encoding="utf-8").read()
        assert OLD_PW not in app + db, "old password left behind"
        assert "app.new.example.org" in app and "old.example.com" not in app
        assert "APP_KEY=base64:keepThisIdentityKey000" in app, "identity key must be kept"
        assert "LOG_LEVEL=info" in app
        assert f"ghcr.io/acme/app:1.2@{D_APP}" in app and f"postgres:16@{D_DB}" in db
        assert "--log.filePath" not in tr
        assert n.get("disk/opt/shop/docker-compose.yml") == "shop", n
        shop_env = open(os.path.join(out, "shop.env"), encoding="utf-8").read()
        assert OLD_PW not in shop_env and "shop.new.example.org" in shop_env, "compose .env not rendered"
        new_pw = app.split("postgres://app:")[1].split("@")[0]
        assert len(new_pw) >= 16 and new_pw in db, "DSN and POSTGRES_PASSWORD must share the new value"
        assert os.path.exists(os.path.join(out, "report.txt"))

        r = run(*args)  # re-render keeps the same new secret
        assert r.returncode == 0, r.stderr
        assert new_pw in open(os.path.join(out, "app.yml"), encoding="utf-8").read(), "rotation not stable"

        r = run("hosts", out)
        assert "app.new.example.org" in r.stdout, r.stdout

        evil = os.path.join(t, "evil.stream")
        with open(evil, "w", encoding="utf-8") as f:
            f.write("@@@VPSCLONE-FILE ../escaped.txt@@@\nx\n@@@VPSCLONE-FILE ok.txt@@@\ny\n")
        run("unpack", evil, os.path.join(t, "evil"))
        assert not os.path.exists(os.path.join(t, "escaped.txt")), "path traversal in unpack"
    print("stacks ok")


if __name__ == "__main__":
    main()
