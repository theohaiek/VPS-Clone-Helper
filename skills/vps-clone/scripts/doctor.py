#!/usr/bin/env python3
"""doctor.py - prerequisite checker + workspace bootstrapper for vps-clone (stdlib only).

Never assumes anything is installed; every check is wrapped so a missing tool never crashes
the script. Run this first, before touching any server.

Usage:
  doctor.py [--json] [--fix] [--source HOST[:PORT] ...] [--domain DOMAIN ...] [--quiet]

  --json      machine-readable output instead of the table
  --fix       only auto-installs the one thing that's safe to auto-install: paramiko
              (python -m pip install --user paramiko). Everything else just gets an
              exact install command printed - nothing else is touched automatically.
  --source    HOST or HOST:PORT (repeatable) - TCP reachability probe only, no auth attempted
  --domain    DOMAIN (repeatable) - guesses the DNS provider via a DNS-over-HTTPS NS lookup
  --quiet     hide OK rows in the table (JSON output is unaffected)

What it does on every run:
  - creates $VPSCLONE_DIR (default ./.vps-clone, relative to the current directory) with its
    own .gitignore ('*'), exactly like sshx.py's ensure_dir - this workspace holds secrets and
    must never be committed.
  - writes $VPSCLONE_DIR/env.sh (POSIX, for Git Bash/macOS/Linux) and env.ps1 (PowerShell),
    both exporting VPSCLONE_DIR, S (this scripts/ dir), PY (the python running this file),
    MSYS_NO_PATHCONV=1 and PYTHONUTF8=1. Every later shell command in this workflow starts
    with:  . "$VPSCLONE_DIR/env.sh" &&  ...

Exit code: 0 unless a BLOCKING item is missing (python<3.8, paramiko, ssh, or ssh-keygen).
Every other missing item is WARN/OPTIONAL and does not affect the exit code.
"""
import argparse
import importlib.util
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

SCRIPTS = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------------------


def item(section, name, status, detail="", fix="", blocking=False):
    return {"section": section, "item": name, "status": status, "detail": detail, "fix": fix, "blocking": blocking}


def truncate(s, n):
    s = s or ""
    return s if len(s) <= n else s[: max(0, n - 1)] + "\u2026"


def to_git_bash_path(path):
    """C:\\Users\\x -> C:/Users/x. Not /c/Users/x: env.sh exports MSYS_NO_PATHCONV=1 (so remote paths like
    /root/x reach ssh untouched), which also stops Git Bash from translating /c/... for native Windows
    programs, and Python would read /c/Users/x as C:\\c\\Users\\x. Git Bash itself accepts C:/Users/x.
    Passthrough (forward slashes) on non-Windows paths."""
    p = os.path.abspath(path)
    if len(p) >= 2 and p[1] == ":":
        return p[0].upper() + ":" + p[2:].replace("\\", "/")
    return p.replace("\\", "/")


def normalize_input_path(p):
    """A path coming from an env var (e.g. VPSCLONE_DIR) may be a Git-Bash/MSYS posix path
    like /c/Users/x even though THIS python.exe is native Windows: MSYS auto-conversion only
    rewrites command-line arguments, never environment variable values, so os.path.abspath()
    would otherwise treat '/c/Users/x' as rooted on the current drive and produce
    'C:\\c\\Users\\x'. Convert it to a real Windows path first when that shape is detected."""
    if os.name == "nt":
        m = re.match(r"^/([A-Za-z])(/.*)?$", p)
        if m:
            drive = m.group(1).upper()
            rest = (m.group(2) or "").replace("/", "\\")
            return f"{drive}:{rest}" if rest else f"{drive}:\\"
    return p


def expand_path(p):
    return os.path.expandvars(os.path.expanduser(p))


def find_existing(paths):
    for p in paths:
        if "%APPDATA%" in p and os.name != "nt":
            continue
        ep = expand_path(p)
        try:
            if os.path.exists(ep):
                return ep
        except Exception:
            continue
    return None


def run_version(cmd_args, timeout=5):
    try:
        # Resolve to the full path so npm-installed .cmd/.bat shims (e.g. "claude" on Windows)
        # don't hit WinError 2 - CreateProcess only auto-appends .exe, never .cmd/.bat, when
        # given a bare name. subprocess.run(list, shell=True) on Windows quotes the whole list
        # into one command line and hands it to cmd.exe, which resolves the shim correctly.
        exe = shutil.which(cmd_args[0]) or cmd_args[0]
        use_shell = os.name == "nt" and exe.lower().endswith((".cmd", ".bat"))
        args = [exe] + list(cmd_args[1:])
        r = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout, shell=use_shell)
        combined = ((r.stdout or "") + (r.stderr or "")).strip().splitlines()
        return combined[0][:70] if combined else None
    except Exception:
        return None


def os_family():
    s = platform.system()
    if s == "Windows":
        return "windows"
    if s == "Darwin":
        return "macos"
    return "linux"


INSTALL_HINTS = {
    "ssh": {
        "windows": "winget install Microsoft.OpenSSH.Beta  (also provides ssh-keygen, scp)",
        "macos": "already included with macOS",
        "linux": "sudo apt install openssh-client",
    },
    "git": {
        "windows": "winget install --id Git.Git",
        "macos": "brew install git",
        "linux": "sudo apt install git",
    },
    "curl": {
        "windows": "already included in Windows 10 1803+  (or: winget install cURL.cURL)",
        "macos": "already included with macOS",
        "linux": "sudo apt install curl",
    },
    "claude": {
        "windows": "npm install -g @anthropic-ai/claude-code",
        "macos": "npm install -g @anthropic-ai/claude-code",
        "linux": "npm install -g @anthropic-ai/claude-code",
    },
    "node": {
        "windows": "winget install OpenJS.NodeJS.LTS  (also provides npx)",
        "macos": "brew install node",
        "linux": "sudo apt install nodejs npm",
    },
    "gh": {
        "windows": "winget install --id GitHub.cli",
        "macos": "brew install gh",
        "linux": "sudo apt install gh  (needs the official GitHub apt repo)",
    },
    "jq": {
        "windows": "winget install jqlang.jq",
        "macos": "brew install jq",
        "linux": "sudo apt install jq",
    },
    "rsync": {
        "windows": "no native Windows binary; this toolkit uses sshx.py (paramiko) instead",
        "macos": "brew install rsync",
        "linux": "sudo apt install rsync",
    },
    "python": {
        "windows": "winget install Python.Python.3.12",
        "macos": "brew install python3",
        "linux": "sudo apt install python3",
    },
    "hcloud": {
        "windows": "winget install hetznercloud.cli",
        "macos": "brew install hcloud",
        "linux": "download a release from https://github.com/hetznercloud/cli",
    },
    "doctl": {
        "windows": "download a release zip from https://github.com/digitalocean/doctl/releases",
        "macos": "brew install doctl",
        "linux": "snap install doctl",
    },
    "vultr-cli": {
        "windows": "download a release from https://github.com/vultr/vultr-cli/releases",
        "macos": "brew install vultr/vultr-cli/vultr-cli",
        "linux": "download a release from https://github.com/vultr/vultr-cli/releases",
    },
    "linode-cli": {
        "windows": "pip3 install linode-cli --upgrade",
        "macos": "brew install linode-cli",
        "linux": "pip3 install linode-cli --upgrade",
    },
    "aws": {
        "windows": "winget install Amazon.AWSCLI",
        "macos": "brew install awscli",
        "linux": "sudo apt install awscli",
    },
    "gcloud": {
        "windows": "see https://cloud.google.com/sdk/docs/install",
        "macos": "brew install --cask google-cloud-sdk",
        "linux": "see https://cloud.google.com/sdk/docs/install",
    },
    "oci": {
        "windows": "see https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm",
        "macos": 'bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"',
        "linux": 'bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"',
    },
    "ovhcloud": {
        "windows": "download a release from https://github.com/ovh/ovhcloud-cli",
        "macos": "download a release from https://github.com/ovh/ovhcloud-cli",
        "linux": "download a release from https://github.com/ovh/ovhcloud-cli",
    },
    "hostinger": {
        "windows": "see https://github.com/hostinger/api-cli",
        "macos": "see https://github.com/hostinger/api-cli",
        "linux": "see https://github.com/hostinger/api-cli",
    },
    "cntb": {
        "windows": "download a release from https://github.com/contabo/cntb/releases",
        "macos": "download a release from https://github.com/contabo/cntb/releases",
        "linux": "download a release from https://github.com/contabo/cntb/releases",
    },
}


def install_hint(key):
    hints = INSTALL_HINTS.get(key)
    if not hints:
        return "see the tool/provider's documentation"
    fam = os_family()
    return hints.get(fam, hints.get("linux", "see documentation"))


# --------------------------------------------------------------------------------------
# workspace: create $VPSCLONE_DIR, write env.sh / env.ps1
# --------------------------------------------------------------------------------------


def workspace_dir():
    d = os.environ.get("VPSCLONE_DIR")
    if d:
        return os.path.abspath(normalize_input_path(d))
    return os.path.abspath(os.path.join(os.getcwd(), ".vps-clone"))


def ensure_workspace(ws):
    """Mirrors sshx.py's ensure_dir(): same .gitignore content, same idempotent create."""
    os.makedirs(ws, exist_ok=True)
    gi = os.path.join(ws, ".gitignore")
    if not os.path.exists(gi):
        with open(gi, "w", encoding="utf-8", newline="\n") as f:
            f.write("# secrets and job state - never commit\n*\n")


def write_env_files(ws):
    ws_posix = to_git_bash_path(ws)
    scripts_posix = to_git_bash_path(SCRIPTS)
    py_posix = to_git_bash_path(sys.executable)

    sh_path = os.path.join(ws, "env.sh")
    with open(sh_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("#!/usr/bin/env sh\n")
        f.write("# generated by doctor.py - source this before any vps-clone command:\n")
        f.write('#   . "$VPSCLONE_DIR/env.sh" && ...\n')
        f.write(f'export VPSCLONE_DIR="{ws_posix}"\n')
        f.write(f'export S="{scripts_posix}"\n')
        f.write(f'export PY="{py_posix}"\n')
        f.write("export MSYS_NO_PATHCONV=1\n")
        f.write("export PYTHONUTF8=1\n")

    ps1_path = os.path.join(ws, "env.ps1")
    with open(ps1_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("# generated by doctor.py - dot-source this before any vps-clone command:\n")
        f.write("#   . $env:VPSCLONE_DIR\\env.ps1 ; ...\n")
        f.write(f'$env:VPSCLONE_DIR = "{ws}"\n')
        f.write(f'$env:S = "{SCRIPTS}"\n')
        f.write(f'$env:PY = "{sys.executable}"\n')
        f.write('$env:MSYS_NO_PATHCONV = "1"\n')
        f.write('$env:PYTHONUTF8 = "1"\n')

    return sh_path, ps1_path


def read_hosts_summary(ws):
    path = os.path.join(ws, "hosts.json")
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as f:
            hosts = json.load(f)
        out = []
        for alias, h in hosts.items():
            if not isinstance(h, dict):
                continue
            out.append({"alias": alias, "role": h.get("role", "target"), "host": h.get("host", "?")})
        return out
    except Exception:
        return []


def read_state_next_step(ws):
    path = os.path.join(ws, "STATE.md")
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
        for i, line in enumerate(lines):
            if line.strip().startswith("## Next step"):
                return [l for l in lines[i + 1 : i + 6]]
        return []
    except Exception:
        return []


# --------------------------------------------------------------------------------------
# SYSTEM
# --------------------------------------------------------------------------------------


def fix_paramiko():
    try:
        r = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--user", "paramiko"],
            capture_output=True,
            text=True,
            timeout=180,
        )
        return r.returncode == 0, ((r.stdout or "") + (r.stderr or ""))
    except Exception as e:
        return False, str(e)


def check_paramiko(do_fix):
    spec = importlib.util.find_spec("paramiko")
    if spec:
        ver = None
        try:
            import importlib.metadata as md

            ver = md.version("paramiko")
        except Exception:
            pass
        return True, f"paramiko {ver}" if ver else "paramiko installed"
    if do_fix:
        ok, log = fix_paramiko()
        if ok and importlib.util.find_spec("paramiko"):
            return True, "installed just now by --fix"
        return False, f"--fix install failed: {truncate(log.strip(), 200)}"
    return False, "not installed"


def check_system(args):
    out = []
    system = platform.system()
    msystem = os.environ.get("MSYSTEM", "")
    if system == "Windows" and msystem:
        detail = f"Windows / Git Bash (MSYSTEM={msystem})"
    elif system == "Windows":
        detail = "Windows (native shell, not Git Bash)"
    elif system == "Darwin":
        detail = f"macOS {platform.mac_ver()[0] or ''}".strip()
    else:
        detail = f"Linux ({platform.platform()})"
    out.append(item("SYSTEM", "os_shell", "OK", detail))

    if system == "Windows" and msystem:
        if os.environ.get("MSYS_NO_PATHCONV"):
            out.append(item("SYSTEM", "MSYS_NO_PATHCONV", "OK", "set in this shell"))
        else:
            out.append(
                item(
                    "SYSTEM",
                    "MSYS_NO_PATHCONV",
                    "OK",
                    "exported by env.sh (keeps /root/x intact); start every command with . .vps-clone/env.sh",
                )
            )
    else:
        out.append(item("SYSTEM", "MSYS_NO_PATHCONV", "OK", "not needed on this shell"))

    pyver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    if sys.version_info >= (3, 8):
        out.append(item("SYSTEM", "python", "OK", f"{pyver} ({sys.executable})"))
    else:
        out.append(
            item("SYSTEM", "python", "MISSING", pyver, "install Python >= 3.8: " + install_hint("python"), blocking=True)
        )

    ok, detail = check_paramiko(args.fix)
    out.append(
        item(
            "SYSTEM",
            "paramiko",
            "OK" if ok else "MISSING",
            detail,
            "" if ok else "python -m pip install --user paramiko   (or rerun doctor.py with --fix)",
            blocking=not ok,
        )
    )
    return out


# --------------------------------------------------------------------------------------
# TOOLS
# --------------------------------------------------------------------------------------


def which_item(section, name, blocking=False, version_cmd=None, hint_key=None, missing_status="WARN"):
    hint_key = hint_key or name
    path = shutil.which(name)
    if path:
        detail = path
        if version_cmd:
            v = run_version(version_cmd)
            if v:
                detail = f"{path}  ({v})"
        return item(section, name, "OK", detail)
    status = "MISSING" if blocking else missing_status
    return item(section, name, status, "not found in PATH", install_hint(hint_key), blocking=blocking)


def check_tools(args):
    return [
        which_item("TOOLS", "ssh", blocking=True, version_cmd=["ssh", "-V"]),
        which_item("TOOLS", "ssh-keygen", blocking=True, hint_key="ssh"),
        which_item("TOOLS", "scp", hint_key="ssh", missing_status="WARN"),
        which_item("TOOLS", "git", version_cmd=["git", "--version"], missing_status="WARN"),
        which_item("TOOLS", "curl", version_cmd=["curl", "--version"], missing_status="WARN"),
        which_item("TOOLS", "claude", version_cmd=["claude", "--version"], missing_status="WARN"),
        which_item("TOOLS", "node", version_cmd=["node", "--version"], missing_status="WARN"),
        which_item("TOOLS", "npx", hint_key="node", missing_status="WARN"),
        which_item("TOOLS", "gh", missing_status="OPTIONAL"),
        which_item("TOOLS", "jq", missing_status="OPTIONAL"),
        which_item("TOOLS", "rsync", missing_status="OPTIONAL"),
    ]


# --------------------------------------------------------------------------------------
# PROVIDERS (CLI + auth config file + token env var, by name only)
# --------------------------------------------------------------------------------------

# key, display name, cli binary (or None), token env vars, auth config file candidates, category
PROVIDERS = [
    ("hetzner", "Hetzner Cloud", "hcloud", ["HCLOUD_TOKEN"], ["~/.config/hcloud/cli.toml"], "provider"),
    ("hetzner_dns", "Hetzner DNS", None, ["HETZNER_DNS_TOKEN"], [], "dns"),
    (
        "digitalocean",
        "DigitalOcean",
        "doctl",
        ["DIGITALOCEAN_ACCESS_TOKEN", "DIGITALOCEAN_TOKEN"],
        ["~/.config/doctl/config.yaml", "%APPDATA%/doctl/config.yaml"],
        "provider+dns",
    ),
    ("vultr", "Vultr", "vultr-cli", ["VULTR_API_KEY"], ["~/.vultr-cli.yaml"], "provider"),
    (
        "linode",
        "Linode/Akamai",
        "linode-cli",
        ["LINODE_CLI_TOKEN", "LINODE_TOKEN"],
        ["~/.config/linode-cli"],
        "provider+dns",
    ),
    (
        "aws",
        "AWS (EC2/Lightsail/Route53)",
        "aws",
        ["AWS_ACCESS_KEY_ID", "AWS_PROFILE"],
        ["~/.aws/credentials"],
        "provider+dns",
    ),
    ("gcp", "Google Cloud", "gcloud", ["GOOGLE_APPLICATION_CREDENTIALS"], ["~/.config/gcloud"], "provider+dns"),
    ("oci", "Oracle Cloud", "oci", ["OCI_CLI_CONFIG_FILE"], ["~/.oci/config"], "provider"),
    ("ovh", "OVHcloud", "ovhcloud", [], [], "provider"),
    ("hostinger", "Hostinger", "hostinger", ["HOSTINGER_API_TOKEN"], ["~/.hostinger.yaml"], "provider+dns"),
    ("contabo", "Contabo", "cntb", ["CNTB_OAUTH2_CLIENT_ID"], ["~/.cntb.yaml"], "provider"),
    ("cloudflare", "Cloudflare DNS", None, ["CLOUDFLARE_API_TOKEN", "CF_API_TOKEN"], [], "dns"),
    ("godaddy", "GoDaddy DNS", None, ["GODADDY_API_KEY"], [], "dns"),
    ("namecheap", "Namecheap DNS", None, ["NAMECHEAP_API_KEY"], [], "dns"),
    ("porkbun", "Porkbun DNS", None, ["PORKBUN_API_KEY"], [], "dns"),
]


def check_providers(args):
    out = []
    for _key, display, cli, env_vars, config_paths, _category in PROVIDERS:
        cli_path = shutil.which(cli) if cli else None
        set_envs = [v for v in env_vars if os.environ.get(v)]
        cfg = find_existing(config_paths) if config_paths else None

        parts = []
        if cli_path:
            parts.append(f"cli={cli_path}")
        if cfg:
            parts.append(f"config={cfg}")
        if set_envs:
            parts.append("env set: " + ",".join(set_envs))
        detail = "; ".join(parts) if parts else "not detected"

        if (cli_path or not cli) and (cfg or set_envs):
            status = "OK"
        elif cli_path and not (cfg or set_envs):
            status = "WARN"
            detail += "  (CLI installed, no auth config/token env var found)"
        else:
            status = "OPTIONAL"

        fix = ""
        if status != "OK":
            fixes = []
            if cli and not cli_path:
                fixes.append(f"install: {install_hint(cli)}")
            if not set_envs and not cfg and env_vars:
                fixes.append("auth: set " + " or ".join(env_vars))
            fix = "; ".join(fixes)
        out.append(item("PROVIDERS", display, status, detail, fix))
    return out


# --------------------------------------------------------------------------------------
# MCP: claude mcp list + npm global MCP binaries fallback listing
# --------------------------------------------------------------------------------------

MCP_LINE_RE = re.compile(
    r"^(?P<name>[^:]+):\s*(?P<target>.+?)\s*(?:\((?P<transport>[^)]+)\)\s*)?-\s+(?P<symbol>\S+)\s*(?P<statustext>.*)$"
)

PROVIDER_KEYWORDS = [
    # "google" alone is deliberately excluded: it false-matches common non-VPS MCPs
    # (Google Drive, Google Maps, Google Workspace, ...); "gcp"/"google cloud" are specific.
    "hetzner", "hcloud", "digitalocean", "vultr", "linode", "akamai", "aws", "lightsail",
    "gcp", "google cloud", "oracle", "oci", "ovh", "hostinger", "contabo",
]
DNS_KEYWORDS = ["cloudflare", "dns", "route53", "hostinger", "godaddy", "namecheap", "porkbun"]


def parse_mcp_line(line):
    m = MCP_LINE_RE.match(line.strip())
    if not m:
        return None
    name = m.group("name").strip()
    target = m.group("target").strip()
    transport = (m.group("transport") or "?").strip()
    symbol = m.group("symbol").strip()
    statustext = m.group("statustext").strip()
    low = (symbol + " " + statustext).lower()
    ok = symbol in ("\u2714", "\u2713") or ("connected" in low and "disconnected" not in low)
    needs_auth = symbol == "!" or "authentication" in low
    return {
        "name": name,
        "target": target,
        "transport": transport,
        "raw_status": f"{symbol} {statustext}".strip(),
        "ok": ok,
        "needs_auth": needs_auth,
    }


def classify_mcp(name, target):
    text = f"{name} {target}".lower()
    is_provider = any(k in text for k in PROVIDER_KEYWORDS)
    is_dns = any(k in text for k in DNS_KEYWORDS)
    if is_provider and is_dns:
        return "provider+dns"
    if is_provider:
        return "provider"
    if is_dns:
        return "dns"
    return "other"


def list_npm_mcp_binaries():
    """Cheap listing only - never runs 'npm root -g' (slow, walks the whole global tree)."""
    found = []
    try:
        if os.name == "nt":
            appdata = os.environ.get("APPDATA")
            if appdata:
                base = os.path.join(appdata, "npm")
                if os.path.isdir(base):
                    for name in os.listdir(base):
                        if "mcp" in name.lower():
                            found.append(os.path.join(base, name))
        else:
            r = subprocess.run(["npm", "prefix", "-g"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=5)
            if r.returncode == 0:
                base = os.path.join(r.stdout.strip(), "bin")
                if os.path.isdir(base):
                    for name in os.listdir(base):
                        if "mcp" in name.lower():
                            found.append(os.path.join(base, name))
    except Exception:
        pass
    return found


def check_mcp(args):
    out = []
    claude_path = shutil.which("claude")
    if not claude_path:
        out.append(
            item(
                "MCP",
                "claude mcp list",
                "WARN",
                "claude CLI not found - cannot enumerate MCP servers this way",
                "install claude CLI: " + install_hint("claude"),
            )
        )
    else:
        try:
            # On Windows, npm-installed CLIs are often .cmd/.bat shims that CreateProcess
            # cannot exec directly (WinError 2) unless routed through cmd.exe.
            use_shell = os.name == "nt" and claude_path.lower().endswith((".cmd", ".bat"))
            r = subprocess.run(
                [claude_path, "mcp", "list"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60, shell=use_shell
            )
            raw = (r.stdout or "") + (r.stderr or "")
            # A real entry always has a "name:" prefix; progress/banner lines (e.g. "Checking
            # MCP server health...") don't and would otherwise be miscounted as unparsed noise.
            lines = [l for l in raw.splitlines() if l.strip() and ":" in l]
            parsed = []
            unparsed = 0
            for l in lines:
                p = parse_mcp_line(l)
                if p:
                    parsed.append(p)
                else:
                    unparsed += 1
            if not parsed and not unparsed:
                out.append(item("MCP", "claude mcp list", "OPTIONAL", "no MCP servers configured", "claude mcp add <name> ..."))
            else:
                for p in parsed:
                    cat = classify_mcp(p["name"], p["target"])
                    status = "OK" if p["ok"] else "WARN"
                    out.append(
                        item(
                            "MCP",
                            f"mcp:{p['name']}",
                            status,
                            f"[{cat}] {p['transport']} - {p['raw_status']}",
                            "" if p["ok"] else f"claude mcp get {p['name']}   (check auth/connection)",
                        )
                    )
                if unparsed:
                    out.append(
                        item(
                            "MCP",
                            "claude mcp list (unparsed)",
                            "WARN",
                            f"{unparsed} line(s) in an unrecognized format - inspect manually",
                            "run: claude mcp list",
                        )
                    )
        except subprocess.TimeoutExpired:
            out.append(item("MCP", "claude mcp list", "WARN", "timed out after 60s", "run 'claude mcp list' manually"))
        except Exception as e:
            out.append(item("MCP", "claude mcp list", "WARN", f"error running it: {e}", ""))

    out.append(
        item(
            "MCP",
            "chrome/claude.ai connectors",
            "OPTIONAL",
            "claude-in-chrome and claude.ai connectors may not appear in 'claude mcp list'",
            "check in-session: ToolSearch query 'claude-in-chrome' or the provider's name",
        )
    )

    npm_bins = list_npm_mcp_binaries()
    out.append(
        item(
            "MCP",
            "npm_global_mcp_binaries",
            "OK" if npm_bins else "OPTIONAL",
            ", ".join(os.path.basename(p) for p in npm_bins) if npm_bins else "none found",
            "" if npm_bins else "npm install -g <package> if a provider needs a stdio MCP server",
        )
    )
    return out


# --------------------------------------------------------------------------------------
# DNS: DNS-over-HTTPS NS lookup, walking up to the registrable domain
# --------------------------------------------------------------------------------------

NS_MAP = [
    ("cloudflare.com", "Cloudflare"),
    ("dns-parking.com", "Hostinger"),
    ("hostinger", "Hostinger"),
    ("awsdns", "AWS Route53"),
    ("digitalocean.com", "DigitalOcean"),
    ("hetzner", "Hetzner DNS"),
    ("domaincontrol.com", "GoDaddy"),
    ("registrar-servers.com", "Namecheap"),
    ("dns.br", "registro.br (no API - manual/browser)"),
    ("googledomains", "Google Domains"),
    ("ns-cloud", "Google Cloud DNS"),
    ("azure-dns", "Azure DNS"),
    ("vultr.com", "Vultr"),
    ("linode.com", "Linode"),
    ("ovh.net", "OVHcloud"),
    ("porkbun", "Porkbun"),
    ("contabo", "Contabo"),
]


def classify_ns(ns_list):
    text = " ".join(ns_list).lower()
    for suffix, provider in NS_MAP:
        if suffix in text:
            return provider
    return None


def doh_query(name, rtype, timeout=8):
    bases = ["https://cloudflare-dns.com/dns-query", "https://dns.google/resolve"]
    last_err = None
    for base in bases:
        try:
            qs = urllib.parse.urlencode({"name": name, "type": rtype})
            req = urllib.request.Request(f"{base}?{qs}", headers={"Accept": "application/dns-json"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8", "replace"))
            return (data.get("Answer") or []), base
        except Exception as e:
            last_err = e
            continue
    return [], last_err


def registrable_domain_candidates(domain):
    parts = domain.strip(".").split(".")
    return [".".join(parts[i:]) for i in range(max(0, len(parts) - 1))]


def dns_provider_guess(domain, timeout=8):
    result = {"domain": domain, "checked_domain": None, "ns": [], "a_records": [], "provider_guess": None}
    for cand in registrable_domain_candidates(domain):
        answers, src = doh_query(cand, "NS", timeout)
        ns_list = [a.get("data", "").rstrip(".") for a in answers if a.get("type") == 2]
        if ns_list:
            result["checked_domain"] = cand
            result["ns"] = ns_list
            result["provider_guess"] = classify_ns(ns_list)
            break
    a_answers, _ = doh_query(domain, "A", timeout)
    result["a_records"] = [a.get("data") for a in a_answers if a.get("type") == 1]
    return result


def check_dns(domains):
    out = []
    for d in domains:
        try:
            res = dns_provider_guess(d)
            if res["ns"]:
                detail = f"NS ({res['checked_domain']}): {', '.join(res['ns'][:4])}"
                if res["a_records"]:
                    detail += f"  | A: {', '.join(res['a_records'][:4])}"
                if res["provider_guess"]:
                    detail += f"  -> {res['provider_guess']}"
                    out.append(item("DNS", d, "OK", detail))
                else:
                    out.append(item("DNS", d, "WARN", detail + "  -> unknown provider", "check the NS suffix manually"))
            else:
                out.append(
                    item(
                        "DNS",
                        d,
                        "WARN",
                        "no NS answer via DoH (cloudflare-dns.com / dns.google)",
                        "check spelling/propagation, or query manually",
                    )
                )
        except Exception as e:
            out.append(item("DNS", d, "WARN", f"lookup failed: {e}", ""))
    return out


# --------------------------------------------------------------------------------------
# NETWORK: TCP reachability of --source, no auth attempted
# --------------------------------------------------------------------------------------


def parse_hostport(s, default_port=22):
    s = s.strip()
    m = re.match(r"^\[(?P<host>[^\]]+)\](:(?P<port>\d+))?$", s)
    if m:
        return m.group("host"), int(m.group("port") or default_port)
    if s.count(":") == 1:
        host, port = s.split(":")
        if port.isdigit():
            return host, int(port)
    return s, default_port


def check_network(sources):
    out = []
    for s in sources:
        try:
            host, port = parse_hostport(s)
            with socket.create_connection((host, port), timeout=6):
                out.append(item("NETWORK", s, "OK", f"TCP connect to {host}:{port} succeeded"))
        except Exception as e:
            out.append(
                item("NETWORK", s, "WARN", f"UNREACHABLE: {e}", "check IP/port, firewall, or that the server is up")
            )
    return out


# --------------------------------------------------------------------------------------
# WORKSPACE summary
# --------------------------------------------------------------------------------------


def check_workspace(ws, env_sh, env_ps1):
    out = [
        item("WORKSPACE", "workspace_dir", "OK", ws),
        item("WORKSPACE", "env.sh", "OK", env_sh),
        item("WORKSPACE", "env.ps1", "OK", env_ps1),
    ]
    hosts = read_hosts_summary(ws)
    if hosts:
        detail = "; ".join(f"{h['alias']}({h['role']}:{h['host']})" for h in hosts)
        out.append(item("WORKSPACE", "hosts.json", "OK", truncate(detail, 200)))
    else:
        out.append(item("WORKSPACE", "hosts.json", "OPTIONAL", "no hosts registered yet", "sshx.py add <alias> <ip> ..."))
    next_step = read_state_next_step(ws)
    if next_step:
        joined = " | ".join(l.strip() for l in next_step if l.strip())
        out.append(item("WORKSPACE", "STATE.md next step", "OK", truncate(joined, 200)))
    else:
        out.append(item("WORKSPACE", "STATE.md next step", "OPTIONAL", "no STATE.md / no '## Next step' section yet"))
    return out


# --------------------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------------------

SECTION_ORDER = ["SYSTEM", "TOOLS", "PROVIDERS", "DNS", "MCP", "WORKSPACE", "NETWORK"]


def print_table(checks, quiet, ws, env_sh, env_ps1, blocking_missing):
    w_item, w_status, w_detail = 26, 9, 46
    header = f"{'ITEM':<{w_item}} {'STATUS':<{w_status}} {'DETAIL':<{w_detail}} FIX"
    print(f"vps-clone doctor - workspace: {ws}")
    for section in SECTION_ORDER:
        rows = [c for c in checks if c["section"] == section]
        if not rows:
            continue
        print(f"\n== {section} ==")
        print(header)
        print("-" * min(119, w_item + w_status + w_detail + 20))
        for c in rows:
            if quiet and c["status"] == "OK":
                continue
            print(
                f"{truncate(c['item'], w_item):<{w_item}} {c['status']:<{w_status}} "
                f"{truncate(c['detail'], w_detail):<{w_detail}} {truncate(c['fix'], 40)}"
            )
    print()
    if blocking_missing:
        print(f"{len(blocking_missing)} BLOCKING issue(s):")
        for c in blocking_missing:
            print(f"  - {c['item']}: {c['fix']}")
    else:
        print("No blocking issues.")


# --------------------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------------------


def safe(section_name, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:
        return [item(section_name, fn.__name__, "WARN", f"internal error while running this check: {e}")]


def main():
    parser = argparse.ArgumentParser(
        prog="doctor.py",
        description="Prerequisite checker + workspace bootstrapper for vps-clone.",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--fix", action="store_true", help="auto-install paramiko if missing (nothing else)")
    parser.add_argument("--source", action="append", default=[], metavar="HOST[:PORT]", help="TCP reachability probe (repeatable)")
    parser.add_argument("--domain", action="append", default=[], metavar="DOMAIN", help="guess DNS provider via NS lookup (repeatable)")
    parser.add_argument("--quiet", action="store_true", help="hide OK rows in the table")
    args = parser.parse_args()

    ws = workspace_dir()
    try:
        ensure_workspace(ws)
        ws_error = None
    except Exception as e:
        ws_error = str(e)

    checks = []
    checks += safe("SYSTEM", check_system, args)
    checks += safe("TOOLS", check_tools, args)
    checks += safe("PROVIDERS", check_providers, args)
    if args.domain:
        checks += safe("DNS", check_dns, args.domain)
    checks += safe("MCP", check_mcp, args)

    try:
        env_sh, env_ps1 = write_env_files(ws)
    except Exception as e:
        env_sh, env_ps1 = "", ""
        checks.append(item("WORKSPACE", "env.sh", "WARN", f"could not write env files: {e}"))

    checks += safe("WORKSPACE", check_workspace, ws, env_sh, env_ps1)
    if ws_error:
        checks.append(item("WORKSPACE", "workspace_dir", "WARN", f"could not create workspace: {ws_error}"))
    if args.source:
        checks += safe("NETWORK", check_network, args.source)

    blocking_missing = [c for c in checks if c.get("blocking") and c["status"] == "MISSING"]
    exit_code = 1 if blocking_missing else 0

    if args.json:
        print(
            json.dumps(
                {
                    "workspace": ws,
                    "env_sh": env_sh,
                    "env_ps1": env_ps1,
                    "checks": checks,
                    "blocking_missing": [c["item"] for c in blocking_missing],
                    "exit_code": exit_code,
                },
                indent=2,
                ensure_ascii=False,
            )
        )
    else:
        print_table(checks, args.quiet, ws, env_sh, env_ps1, blocking_missing)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
