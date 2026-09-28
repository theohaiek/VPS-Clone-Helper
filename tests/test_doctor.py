"""doctor.py: never crashes, valid --json, creates the workspace, env.sh usable by native Python from Git Bash."""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCTOR = os.path.join(ROOT, "skills", "vps-clone", "scripts", "doctor.py")


def main():
    with tempfile.TemporaryDirectory() as t:
        ws = os.path.join(t, "ws")
        env = dict(os.environ, VPSCLONE_DIR=ws, PYTHONUTF8="1")
        r = subprocess.run([sys.executable, DOCTOR, "--json", "--domain", "example.com", "--source", "127.0.0.1:1"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=240)
        assert r.returncode in (0, 1), r.stderr
        data = json.loads(r.stdout)
        assert isinstance(data, dict) and data, "empty json"
        assert os.path.isfile(os.path.join(ws, ".gitignore")), "workspace .gitignore missing"
        env_sh = open(os.path.join(ws, "env.sh"), encoding="utf-8").read()
        for var in ("VPSCLONE_DIR", "S", "PY", "MSYS_NO_PATHCONV", "PYTHONUTF8"):
            assert re.search(rf"^export {var}=", env_sh, re.M), f"env.sh lacks {var}"
        if os.name == "nt":
            # MSYS_NO_PATHCONV=1 is exported, so Git Bash passes paths verbatim to native Python:
            # they must be C:/... style, never /c/... (which Python reads as C:\c\...).
            assert not re.search(r'^export (S|PY|VPSCLONE_DIR)="/[a-zA-Z]/', env_sh, re.M), env_sh
        s_dir = re.search(r'^export S="([^"]+)"', env_sh, re.M).group(1)
        assert os.path.isfile(os.path.join(s_dir, "sshx.py")), f"S does not point to the scripts dir: {s_dir}"
        assert "\r" not in env_sh
    print("doctor ok")


if __name__ == "__main__":
    main()
