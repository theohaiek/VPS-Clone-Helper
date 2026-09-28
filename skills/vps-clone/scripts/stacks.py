#!/usr/bin/env python3
"""stacks.py - turn a raw export_docker.sh stream into deployable, cleaned-up stack files.

Pipeline (each step writes/reads plain files under $VPSCLONE_DIR, nothing implicit):
  1. unpack STREAM OUTDIR              split the export_docker.sh stream into real files
  2. names  EXPORTDIR                  suggest a stack name for each compose file found
  3. pins   EXPORTDIR                  build {"repo:tag": "repo:tag@sha256:..."} from the export
  4. render --src --names --mapping --out   apply the mapping and write OUTDIR/<stack>.yml
  5. hosts  DIR                        list every hostname routed by the stacks in DIR

Usage:
  stacks.py unpack STREAM OUTDIR
  stacks.py names EXPORTDIR [--write names.json]
  stacks.py pins EXPORTDIR [--write pins.json]
  stacks.py render --src EXPORTDIR --names names.json --mapping mapping.json --out OUTDIR
                    [--pins pins.json] [--secrets secrets.json]
  stacks.py hosts DIR

mapping.json (all keys optional):
  "replace":            {"old.example.com": "new.example.org"}   literal replace, longest key first
  "rotate_env":         ["POSTGRES_PASSWORD", ...]                rotate every current value of these
                          vars to a new random 32-char value, same new value everywhere it appears
                          (DSNs/URLs follow). Stable across re-runs via --secrets. Refuses (reports,
                          does not replace) values shorter than 8 chars or found inside an "image:" line.
  "keep_env":            ["N8N_ENCRYPTION_KEY", ...]               identity keys: never rotated, even
                          if also listed in rotate_env (keep_env wins; a conflict is reported).
  "set_env":             {"N8N_METRICS": "false"}                  force a value on every line that
                          already assigns that key (any of "- K=v", '- "K=v"', "K: v", 'K: "v"').
  "image_override":      {"repo:tag": "repo:tag2@sha256:..."}      applied AFTER pinning, matched on
                          the image's repo:tag ignoring whatever digest pinning attached.
  "drop_lines_matching": ["--log.filePath="]                       drop any line containing this text.

Never prints a secret value: every report/console mention is truncated to 3 chars + an ellipsis.
Python 3.8+, standard library only.
"""
import argparse
import glob
import json
import os
import re
import secrets as secretsmod
import sys
from datetime import datetime, timezone

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def localpath(p):
    """Git Bash with MSYS_NO_PATHCONV=1 hands native Windows Python paths like /c/Users/x, which
    Python would read as C:\\c\\Users\\x. Convert them to C:/Users/x."""
    if os.name == "nt" and p:
        m = re.match(r"^/([a-zA-Z])(/.*)?$", p)
        if m:
            return f"{m.group(1).upper()}:{m.group(2) or '/'}"
    return p

MARKER_RE = re.compile(r"^@@@VPSCLONE-FILE (.*)@@@[ \t]*$", re.MULTILINE)
COMPOSE_GLOBS = ("portainer", "disk")


def die(msg, code=2):
    sys.stderr.write(f"[stacks] {msg}\n")
    sys.exit(code)


def mask(value):
    """Never show a secret in full: first 3 chars + an ellipsis."""
    if not value:
        return "(empty)"
    return value[:3] + "…"


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def norm_rel(path):
    return path.replace(os.sep, "/").replace("\\", "/")


# ---------- generic json/file helpers ----------

def load_json(path, default=None):
    if not path:
        return {} if default is None else default
    if not os.path.exists(path):
        return {} if default is None else default
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data, chmod600=False):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    if chmod600:
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass


def read_text(path):
    with open(path, encoding="utf-8", errors="replace", newline=None) as f:
        return f.read()


def write_text(path, text):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


# ---------- unpack ----------

def safe_relpath(raw):
    """Reject path traversal / absolute paths / drive letters. Returns (ok, relpath_or_reason)."""
    rel = (raw or "").strip()
    if not rel:
        return False, "empty path"
    norm = norm_rel(rel)
    if norm.startswith("/"):
        return False, "absolute path"
    if re.match(r"^[A-Za-z]:", norm):
        return False, "drive letter"
    parts = norm.split("/")
    if any(p == ".." for p in parts):
        return False, "path traversal (..)"
    if any(p == "" for p in parts):
        return False, "empty path segment"
    return True, norm


def cmd_unpack(args):
    text = read_text(args.stream)
    matches = list(MARKER_RE.finditer(text))
    if not matches:
        die(f"no '@@@VPSCLONE-FILE ...@@@' markers found in {args.stream}")
    written, skipped = [], []
    for i, m in enumerate(matches):
        raw_rel = m.group(1)
        start = m.end()
        if start < len(text) and text[start] == "\n":
            start += 1
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        content = text[start:end]  # already CRLF->LF via universal-newline read; last file may lack a trailing "\n"
        ok, rel_or_reason = safe_relpath(raw_rel)
        if not ok:
            skipped.append((raw_rel, rel_or_reason))
            sys.stderr.write(f"[stacks] SKIP unsafe path {raw_rel!r}: {rel_or_reason}\n")
            continue
        dest = os.path.join(args.outdir, *rel_or_reason.split("/"))
        write_text(dest, content)
        written.append(rel_or_reason)
    print(f"[stacks] unpacked {len(written)} file(s) to {args.outdir}")
    if skipped:
        print(f"[stacks] skipped {len(skipped)} unsafe path(s): " + ", ".join(r for r, _ in skipped))
        return 1
    return 0


# ---------- compose parsing (no PyYAML: line-based, top-level "services:" block only) ----------

def parse_compose_service_keys(text):
    keys = []
    in_services = False
    for line in text.split("\n"):
        if not in_services:
            if re.match(r"^services:\s*(#.*)?$", line):
                in_services = True
            continue
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            break  # back to top level: services: block is over
        if indent == 2:
            m = re.match(r"^ {2}([A-Za-z0-9_.-]+):", line)
            if m:
                keys.append(m.group(1))
    return keys


def find_compose_candidates(exportdir):
    """Every *.yml/*.yaml under portainer/ and disk/ - the files `render` can turn into a stack."""
    out = []
    for sub in COMPOSE_GLOBS:
        base = os.path.join(exportdir, sub)
        if not os.path.isdir(base):
            continue
        for ext in ("*.yml", "*.yaml"):
            for p in glob.glob(os.path.join(base, "**", ext), recursive=True):
                out.append(norm_rel(os.path.relpath(p, exportdir)))
    return sorted(out)


def swarm_service_names(exportdir):
    d = os.path.join(exportdir, "swarm", "services")
    if not os.path.isdir(d):
        return []
    return sorted(os.path.splitext(f)[0] for f in os.listdir(d) if f.endswith(".json"))


# ---------- names ----------

def suggest_name(relpath, exportdir, services):
    text = read_text(os.path.join(exportdir, *relpath.split("/")))
    service_keys = parse_compose_service_keys(text)
    votes = {}
    for key in service_keys:
        for full in services:
            if full == key:
                votes[full] = votes.get(full, 0) + 1
            elif full.endswith("_" + key):
                stack = full[: -(len(key) + 1)]
                votes[stack] = votes.get(stack, 0) + 1
    if votes:
        best = sorted(votes.items(), key=lambda kv: (-kv[1], kv[0]))[0]
        total = max(len(service_keys), 1)
        return best[0], f"{best[1]}/{total} services matched"
    if relpath.startswith("disk/"):
        stem = os.path.splitext(os.path.basename(relpath))[0]
        if re.match(r"^(docker-)?compose([._-].*)?$", stem) and relpath.count("/") >= 2:
            # compose project: docker-compose.yml is named by its directory (= compose project name)
            return relpath.split("/")[-2], "compose project (directory name; no swarm service matched)"
        return stem, "filename fallback (no swarm service matched)"
    return None, "UNMATCHED (no swarm service matched; add it to names.json by hand)"


def cmd_names(args):
    services = swarm_service_names(args.exportdir)
    candidates = find_compose_candidates(args.exportdir)
    if not candidates:
        print("[stacks] no compose files found under portainer/ or disk/")
    suggestions = {}
    rows = []
    for rel in candidates:
        name, why = suggest_name(rel, args.exportdir, services)
        if name:
            suggestions[rel] = name
        rows.append((rel, name or "-", why))
    # The same stack found both in Portainer's store and as a file on disk: the Portainer copy is what is
    # deployed (Portainer-managed stack); the disk file is usually an old or generated copy. Keep Portainer's.
    in_portainer = {n for r, n in suggestions.items() if r.startswith("portainer/")}
    for rel in [r for r, n in suggestions.items() if r.startswith("disk/") and n in in_portainer]:
        del suggestions[rel]
        rows = [(r, n, (w + "; skipped: Portainer has this stack") if r == rel else w) for r, n, w in rows]
    width = max((len(r[0]) for r in rows), default=8)
    for rel, name, why in rows:
        print(f"{rel:<{width}}  {name:<20}  {why}")
    if args.write:
        save_json(args.write, suggestions)
        print(f"[stacks] wrote {len(suggestions)} suggestion(s) to {args.write}")
    return 0


# ---------- image ref helpers ----------

def split_image_ref(ref):
    """'repo[:tag][@digest]' -> (repo, tag_or_None, digest_or_None)."""
    repo_tag, sep, digest = ref.partition("@")
    digest = digest if sep else None
    if ":" in repo_tag:
        maybe_repo, _, maybe_tag = repo_tag.rpartition(":")
        if maybe_repo and "/" not in maybe_tag:
            return maybe_repo, maybe_tag, digest
    return repo_tag, None, digest


# ---------- pins ----------

def pins_from_swarm(exportdir):
    pins, rows = {}, []
    d = os.path.join(exportdir, "swarm", "services")
    if not os.path.isdir(d):
        return pins, rows
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        path = os.path.join(d, fn)
        try:
            data = json.load(open(path, encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            sys.stderr.write(f"[stacks] WARN: cannot parse {path}: {e}\n")
            continue
        entry = data[0] if isinstance(data, list) and data else (data if isinstance(data, dict) else None)
        if not entry:
            continue
        image = (
            entry.get("Spec", {})
            .get("TaskTemplate", {})
            .get("ContainerSpec", {})
            .get("Image")
        )
        if not image or "@" not in image:
            continue
        repo, tag, digest = split_image_ref(image)
        if not digest:
            continue
        key = f"{repo}:{tag}" if tag else repo
        pins[key] = image
        rows.append((key, digest, f"swarm:{fn}"))
    return pins, rows


def pins_from_repodigests(exportdir):
    pins, rows = {}, []
    path = os.path.join(exportdir, "image_repodigests.tsv")
    if not os.path.exists(path):
        return pins, rows
    for line in read_text(path).split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        _image_id, tags_field, digests_field = parts[0], parts[1], parts[2]
        tags = [t for t in tags_field.split(",") if t and t != "<none>:<none>"]
        digests = [d for d in digests_field.split(",") if d and d != "<none>@<none>"]
        digest_by_repo = {}
        for d in digests:
            drepo, _dtag, ddigest = split_image_ref(d)
            if ddigest:
                digest_by_repo[drepo] = f"{drepo}@{ddigest}"
        for t in tags:
            repo, tag, _ = split_image_ref(t)
            pinned = digest_by_repo.get(repo)
            if not pinned or not tag:
                continue
            key = f"{repo}:{tag}"
            pins[key] = f"{repo}:{tag}@{pinned.split('@', 1)[1]}"
            rows.append((key, pinned.split("@", 1)[1], "image_repodigests.tsv"))
    return pins, rows


def cmd_pins(args):
    swarm_pins, swarm_rows = pins_from_swarm(args.exportdir)
    tsv_pins, tsv_rows = pins_from_repodigests(args.exportdir)
    pins = dict(tsv_pins)
    for k, v in swarm_pins.items():
        if k in pins and pins[k] != v:
            sys.stderr.write(f"[stacks] NOTE: {k} digest differs between swarm and image_repodigests.tsv; using swarm (running spec)\n")
        pins[k] = v  # swarm (the actually-running task spec) wins on conflict
    rows = sorted(set(swarm_rows) | set(tsv_rows), key=lambda r: r[0])
    if not rows:
        print("[stacks] no pinned images found (no swarm/services/*.json or image_repodigests.tsv)")
    width = max((len(r[0]) for r in rows), default=8)
    for key, digest, src in rows:
        short = digest if len(digest) <= 19 else digest[:19] + "…"
        print(f"{key:<{width}}  {short:<22}  {src}")
    if args.write:
        save_json(args.write, pins)
        print(f"[stacks] wrote {len(pins)} pin(s) to {args.write}")
    return 0


# ---------- env-line matching (list and mapping forms, quoted and not) ----------

def env_patterns(key):
    k = re.escape(key)
    return (
        ("list_q", re.compile(r"^(?P<pre>\s*-\s*)(?P<q>[\"'])" + k + r"=(?P<val>.*)(?P=q)(?P<post>[ \t]*)$")),
        ("list_u", re.compile(r"^(?P<pre>\s*-\s*)" + k + r"=(?P<val>.*?)(?P<post>[ \t]*)$")),
        ("map_q", re.compile(r"^(?P<pre>\s*)" + k + r":[ \t]*(?P<q>[\"'])(?P<val>.*)(?P=q)(?P<post>[ \t]*)$")),
        ("map_u", re.compile(r"^(?P<pre>\s*)" + k + r":[ \t]*(?P<val>.*?)(?P<post>[ \t]*)$")),
        # .env files next to compose projects: KEY=value, KEY="value", export KEY=value
        ("dotenv", re.compile(r"^(?P<pre>\s*(?:export\s+)?)" + k + r"=(?P<q>[\"']?)(?P<val>.*?)(?P=q)(?P<post>[ \t]*)$")),
    )


def match_env_line(line, key):
    for kind, pat in env_patterns(key):
        m = pat.match(line)
        if m:
            return kind, m
    return None, None


def render_env_line(kind, m, key, value):
    pre, post = m.group("pre"), m.group("post")
    if kind == "list_q":
        q = m.group("q")
        return f"{pre}{q}{key}={value}{q}{post}"
    if kind == "list_u":
        return f"{pre}{key}={value}{post}"
    if kind == "map_q":
        q = m.group("q")
        return f"{pre}{key}: {q}{value}{q}{post}"
    if kind == "dotenv":
        q = m.group("q")
        return f"{pre}{key}={q}{value}{q}{post}"
    return f"{pre}{key}: {value}{post}"  # map_u


IMAGE_LINE_RE = re.compile(r"^(?P<pre>[ \t]*image:[ \t]*)(?P<q>[\"']?)(?P<val>[^\"'\s]+)(?P=q)(?P<post>.*)$")


# ---------- hostnames (Traefik Host(), HostRegexp(), VIRTUAL_HOST=, caddy labels) ----------

HOST_RE = re.compile(r"Host\(([^)]*)\)")
HOST_BACKTICK_RE = re.compile(r"`([^`]*)`")
HOSTREGEXP_RE = re.compile(r"HostRegexp\(([^)]*)\)")


def extract_hosts(text):
    hosts, notes = set(), []
    for line in text.split("\n"):
        for m in HOST_RE.finditer(line):
            for h in HOST_BACKTICK_RE.findall(m.group(1)):
                if h:
                    hosts.add(h)
        for m in HOSTREGEXP_RE.finditer(line):
            notes.append(f"HostRegexp ignored: {m.group(0)}")
        _, m = match_env_line(line, "VIRTUAL_HOST")
        if m:
            hosts |= {h.strip() for h in m.group("val").split(",") if h.strip()}
        _, m = match_env_line(line, "caddy")
        if m:
            val = m.group("val").strip()
            if val and "{" not in val and not val.startswith("$"):
                hosts |= {h.strip() for h in re.split(r"[,\s]+", val) if h.strip() and "." in h}
    return hosts, notes


def cmd_hosts(args):
    files = sorted(
        glob.glob(os.path.join(args.dir, "**", "*.yml"), recursive=True)
        + glob.glob(os.path.join(args.dir, "**", "*.yaml"), recursive=True)
    )
    all_hosts, all_notes = set(), []
    for f in files:
        h, n = extract_hosts(read_text(f))
        all_hosts |= h
        all_notes.extend(f"{os.path.relpath(f, args.dir)}: {note}" for note in n)
    for h in sorted(all_hosts):
        print(h)
    for n in all_notes:
        print(f"# {n}", file=sys.stderr)
    if not all_hosts:
        print(f"[stacks] no hostnames found under {args.dir}", file=sys.stderr)
    return 0


# ---------- render ----------

def apply_replace(text, replace_map):
    for old, new in sorted(replace_map.items(), key=lambda kv: -len(kv[0])):
        if old:
            text = text.replace(old, new)
    return text


def new_secret(n=32):
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(secretsmod.choice(alphabet) for _ in range(n))


def collect_env_values(contents, key):
    """key -> set of every literal value assigned to it, across all given file contents."""
    values = set()
    for text in contents.values():
        for line in text.split("\n"):
            _, m = match_env_line(line, key)
            if m:
                values.add(m.group("val"))
    return values


def image_lines(text):
    return [line for line in text.split("\n") if IMAGE_LINE_RE.match(line)]


def apply_set_env(text, set_env):
    lines = text.split("\n")
    for i, line in enumerate(lines):
        for key, value in set_env.items():
            kind, m = match_env_line(line, key)
            if kind:
                lines[i] = render_env_line(kind, m, key, value)
                line = lines[i]
    return "\n".join(lines)


def apply_image_pins(text, pins, image_override, relpath, report):
    lines = text.split("\n")
    for i, line in enumerate(lines):
        m = IMAGE_LINE_RE.match(line)
        if not m:
            continue
        val, q, pre, post = m.group("val"), m.group("q"), m.group("pre"), m.group("post")
        if "@" not in val:
            pinned = pins.get(val)
            if pinned:
                val = pinned
            else:
                report["unpinned"].append(f"{relpath}: {val}")
        bare = val.split("@", 1)[0]
        if bare in image_override:
            val = image_override[bare]
            report["overridden"].append(f"{relpath}: {bare} -> {val}")
        lines[i] = f"{pre}{q}{val}{q}{post}"
    return "\n".join(lines)


def apply_drop_lines(text, patterns, relpath, report):
    if not patterns:
        return text
    kept, dropped = [], 0
    for line in text.split("\n"):
        if any(p and p in line for p in patterns):
            dropped += 1
            continue
        kept.append(line)
    if dropped:
        report["dropped"].append(f"{relpath}: {dropped} line(s)")
    return "\n".join(kept)


def cmd_render(args):
    names = load_json(args.names)
    mapping = load_json(args.mapping)
    pins = load_json(args.pins) if args.pins else {}
    secrets_map = load_json(args.secrets) if args.secrets else {}
    secrets_map = dict(secrets_map)  # own copy; we only ever add keys, never mutate caller's

    replace_map = mapping.get("replace", {}) or {}
    rotate_env = list(mapping.get("rotate_env", []) or [])
    keep_env = list(mapping.get("keep_env", []) or [])
    set_env = mapping.get("set_env", {}) or {}
    image_override = mapping.get("image_override", {}) or {}
    drop_patterns = list(mapping.get("drop_lines_matching", []) or [])

    report = {
        "rendered": [], "skipped": [], "leftover_replace": [], "rotated": [], "refused": [],
        "protected": [], "warnings": [], "unpinned": [], "overridden": [], "dropped": [],
        "leftover_rotated": [], "hosts": set(), "host_notes": [],
    }

    candidates = find_compose_candidates(args.src)
    used_names = {}
    rel_to_stack = {}  # relpath -> stack name, resolved once (names.json may use "/" or os.sep keys)
    out_name = {}  # relpath -> output file (<stack>.yml, or <stack>.env for a compose project's .env)
    stage1 = {}  # relpath -> content after "replace", for every file that HAS a name mapping
    for rel in candidates:
        stack = names.get(rel) or names.get(rel.replace("/", os.sep))
        if not stack:
            report["skipped"].append(rel)
            continue
        if stack in used_names:
            report["warnings"].append(
                f"stack name collision: '{stack}' used by both {used_names[stack]} and {rel} (last one wins)"
            )
        used_names[stack] = rel
        rel_to_stack[rel] = stack
        out_name[rel] = f"{stack}.yml"
        text = read_text(os.path.join(args.src, *rel.split("/")))
        stage1[rel] = apply_replace(text, replace_map)
        # Compose projects keep their secrets in a .env next to the compose file: render it too, with the
        # same replace/rotate/set_env, as <stack>.env (copy it into the project dir on the target as .env).
        env_rel = (rel.rsplit("/", 1)[0] + "/.env") if "/" in rel else ".env"
        env_path = os.path.join(args.src, *env_rel.split("/"))
        if rel.startswith("disk/") and os.path.isfile(env_path) and env_rel not in stage1:
            rel_to_stack[env_rel] = stack
            out_name[env_rel] = f"{stack}.env"
            stage1[env_rel] = apply_replace(read_text(env_path), replace_map)

    # rotate_env: collect candidate values across every file that will be rendered
    overlap = sorted(set(rotate_env) & set(keep_env))
    for k in overlap:
        report["warnings"].append(f"{k} is in both keep_env and rotate_env; keep_env wins (not rotated)")
    effective_rotate = [v for v in rotate_env if v not in keep_env]

    protected_values = set()
    for key in keep_env:
        protected_values |= collect_env_values(stage1, key)

    all_image_lines_text = "\n".join(l for t in stage1.values() for l in image_lines(t))

    rotate_values = set()
    for key in effective_rotate:
        rotate_values |= collect_env_values(stage1, key)

    rotation_map = {}
    for value in sorted(rotate_values, key=lambda v: -len(v)):
        if value in protected_values:
            report["protected"].append(mask(value))
            continue
        if len(value) < 8:
            report["refused"].append(f"{mask(value)} (too short: {len(value)} chars)")
            continue
        if value in all_image_lines_text:
            report["refused"].append(f"{mask(value)} (appears inside an image: line)")
            continue
        new_val = secrets_map.get(value)
        if not new_val:
            new_val = new_secret()
            secrets_map[value] = new_val
        rotation_map[value] = new_val
        report["rotated"].append(f"{mask(value)} -> {mask(new_val)}")

    # apply rotation (longest old value first), set_env, image pins/overrides, drop_lines_matching
    final = {}
    for rel, text in stage1.items():
        for old, new in sorted(rotation_map.items(), key=lambda kv: -len(kv[0])):
            text = text.replace(old, new)
        text = apply_set_env(text, set_env)
        text = apply_image_pins(text, pins, image_override, rel, report)
        text = apply_drop_lines(text, drop_patterns, rel, report)
        final[rel] = text

    # leftovers
    # A literal "old" value can legitimately reappear in the rendered text when its own "new"
    # replacement contains "old" as a substring (e.g. replace "acme.com" -> "acme.com.br"): that is
    # not a leftover, apply_replace() already replaced every real occurrence. Strip out instances of
    # "new" before searching, so only a genuine unreplaced (or cross-mapping-reintroduced) "old"
    # is reported.
    for rel, text in final.items():
        stack = rel_to_stack[rel]
        for old, new in replace_map.items():
            if not old:
                continue
            probe = text.replace(new, "") if new else text
            if old in probe:
                report["leftover_replace"].append(f"{old!r} still present in {out_name[rel]} (from {rel})")
        for old in rotation_map:
            if old in text:
                report["leftover_rotated"].append(f"{mask(old)} still present in {out_name[rel]} (from {rel})")

    # write output + collect hostnames
    os.makedirs(args.out, exist_ok=True)
    for rel, text in final.items():
        stack = rel_to_stack[rel]
        out_path = os.path.join(args.out, out_name[rel])
        write_text(out_path, text)
        report["rendered"].append(f"{rel} -> {out_name[rel]}")
        h, n = extract_hosts(text)
        report["hosts"] |= h
        report["host_notes"].extend(f"{out_name[rel]}: {note}" for note in n)

    if args.secrets and rotation_map:
        save_json(args.secrets, secrets_map, chmod600=True)
    elif rotation_map and not args.secrets:
        report["warnings"].append("rotate_env used without --secrets: new values will NOT be stable across re-runs")

    write_report(os.path.join(args.out, "report.txt"), args, report)
    print(f"[stacks] rendered {len(report['rendered'])} stack(s) to {args.out}")
    if report["skipped"]:
        print(f"[stacks] skipped {len(report['skipped'])} file(s) with no name mapping (see report.txt)")
    leftover = bool(report["leftover_replace"] or report["leftover_rotated"])
    if leftover:
        print("[stacks] LEFTOVERS found - see report.txt", file=sys.stderr)
    return 1 if leftover else 0


def write_report(path, args, r):
    lines = [
        "VPS-Clone stacks render report",
        f"generated: {now_iso()}",
        f"source: {args.src}",
        f"names:  {args.names}",
        f"mapping: {args.mapping}",
        f"output: {args.out}",
        "",
        "== files ==",
    ]
    lines += [f"rendered: {x}" for x in r["rendered"]] or ["(none rendered)"]
    lines += [f"skipped (no name mapping): {x}" for x in r["skipped"]]
    if r["warnings"]:
        lines += ["", "== warnings =="] + r["warnings"]
    lines += ["", "== replace =="]
    lines += [f"LEFTOVER: {x}" for x in r["leftover_replace"]] or ["(no leftover 'replace' keys)"]
    lines += ["", "== rotate_env =="]
    lines += [f"rotated: {x}" for x in r["rotated"]]
    lines += [f"protected (keep_env): {x}" for x in r["protected"]]
    lines += [f"refused: {x}" for x in r["refused"]]
    lines += [f"LEFTOVER: {x}" for x in r["leftover_rotated"]]
    if not (r["rotated"] or r["protected"] or r["refused"] or r["leftover_rotated"]):
        lines.append("(rotate_env not used or nothing found)")
    lines += ["", "== images =="]
    lines += [f"overridden: {x}" for x in r["overridden"]]
    lines += [f"UNPINNED: {x}" for x in r["unpinned"]] or ["(no unpinned images)"]
    lines += ["", "== dropped lines =="]
    lines += [f"{x}" for x in r["dropped"]] or ["(none)"]
    lines += ["", "== hostnames =="]
    lines += sorted(r["hosts"]) or ["(none found)"]
    lines += [f"# {x}" for x in r["host_notes"]]
    write_text(path, "\n".join(lines) + "\n")


# ---------- main ----------

def main():
    p = argparse.ArgumentParser(prog="stacks.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("unpack", help="split an export_docker.sh stream into files")
    sp.add_argument("stream")
    sp.add_argument("outdir")

    sp = sub.add_parser("names", help="suggest a stack name for each compose file")
    sp.add_argument("exportdir")
    sp.add_argument("--write", metavar="names.json")

    sp = sub.add_parser("pins", help="build repo:tag -> repo:tag@sha256:... from the export")
    sp.add_argument("exportdir")
    sp.add_argument("--write", metavar="pins.json")

    sp = sub.add_parser("render", help="apply mapping.json and write OUTDIR/<stack>.yml")
    sp.add_argument("--src", required=True)
    sp.add_argument("--names", required=True)
    sp.add_argument("--mapping", required=True)
    sp.add_argument("--out", required=True)
    sp.add_argument("--pins")
    sp.add_argument("--secrets")

    sp = sub.add_parser("hosts", help="list hostnames routed by the stacks in DIR")
    sp.add_argument("dir")

    args = p.parse_args()
    for k in ("stream", "outdir", "exportdir", "write", "src", "names", "mapping", "out", "pins", "secrets", "dir"):
        if getattr(args, k, None):
            setattr(args, k, localpath(getattr(args, k)))
    if args.cmd == "unpack":
        sys.exit(cmd_unpack(args))
    if args.cmd == "names":
        sys.exit(cmd_names(args))
    if args.cmd == "pins":
        sys.exit(cmd_pins(args))
    if args.cmd == "render":
        sys.exit(cmd_render(args))
    if args.cmd == "hosts":
        sys.exit(cmd_hosts(args))


if __name__ == "__main__":
    main()
