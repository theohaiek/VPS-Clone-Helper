#!/usr/bin/env python3
"""parity.py - compare a source and target Docker/Swarm export for parity.

Reads the directories produced by `stacks.py unpack` from an `export_docker.sh` stream
(swarm/services/<name>.json, swarm/nodes.json, networks.json, volumes.json, containers.json)
and reports SAME / DIFF / MISSING_ON_TARGET / EXTRA_ON_TARGET per item. Read-only: writes
nothing, only prints a report and sets its exit code.

Usage:
  parity.py SRC_EXPORTDIR TGT_EXPORTDIR [--mapping mapping.json] [--secrets secrets.json]
            [--ignore-digest] [--ignore-env KEY,...] [--json]

Swarm mode (used when either dir has swarm/services/*.json): compares services (by name),
nodes (count, roles, hostnames, labels), networks (names, driver, attachable) and volumes
(names). Compose/plain-docker mode (used otherwise): compares containers.json by name
(Image, Env, Mounts, Labels, Cmd, Entrypoint, RestartPolicy, PortBindings).

--mapping mapping.json applies its "replace" map (literal substring replace, longest key
first) to every string on the SOURCE side before comparing.
--secrets secrets.json supplies old->new rotated values (accepts either a top-level
{"old": "new", ...} object or {"rotated": {"old": "new", ...}}); those are applied the same
way, so a rotated password shows as SAME instead of DIFF.
--ignore-digest compares "repo:tag@sha256:..." images as "repo:tag" only.
--ignore-env KEY,KEY2 drops those env var names from Env comparisons on both sides.

Exit code: 0 if every item is SAME (a DIFF explained by --mapping/--secrets already reads as
SAME), 1 if any unexplained DIFF/MISSING_ON_TARGET/EXTRA_ON_TARGET remains, 2 on bad input.
"""
import argparse
import json
import os
import re
import sys


class _Missing:
    def __repr__(self):
        return "<missing>"


MISSING = _Missing()
ENV_SENSITIVE_RE = re.compile(r"(PASS|PWD|SECRET|KEY|TOKEN|COOKIE|CERT|CREDENTIAL|AUTH|PRIVATE|SALT|SIGN|LICENSE)", re.IGNORECASE)
# A value that looks random (long, no spaces, letters+digits, not a URL/host/path) is masked whatever
# its variable is called: secret names are open-ended (e.g. RABBITMQ_ERLANG_COOKIE, *_DSN, custom names).
RANDOM_VALUE_RE = re.compile(r"^(?=.*[A-Za-z])(?=.*\d)[A-Za-z0-9+/=_\-]{16,}$")
REVEAL_ENV = set()  # names from --reveal-env: shown in clear even if they look sensitive
ENV_PATH_RE = re.compile(r"(^|\.)Env\[\d+\]$")
# Credentials embedded in a connection string (postgres://user:pass@host, amqp://, redis://, ...)
# regardless of the env var's own name (DATABASE_URL, AMQP_URL, REDIS_URL, MONGO_URI, ...).
ENV_URI_CRED_RE = re.compile(r"(://[^:/@\s]+:)([^@/\s]+)(@)")


# ---------- generic helpers ----------

def load_json(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load_array(path):
    try:
        data = load_json(path)
    except json.JSONDecodeError:
        return []
    if data is None:
        return []
    return data if isinstance(data, list) else [data]


def split_malformed(raw_list):
    """load_array() can hand back a list containing non-object entries (a JSON file that
    parsed but wasn't the expected array-of-objects: a bare string/number, a list of scalars,
    ...). Keep only dict entries so callers can safely use .get() on them, and report how many
    were dropped so a malformed file surfaces as a DIFF instead of being silently ignored."""
    good = [x for x in raw_list if isinstance(x, dict)]
    return good, len(raw_list) - len(good)


def apply_replacements(obj, repl_sorted):
    """Recursively substring-replace every string value in obj (longest key first)."""
    if isinstance(obj, dict):
        return {k: apply_replacements(v, repl_sorted) for k, v in obj.items()}
    if isinstance(obj, list):
        return [apply_replacements(v, repl_sorted) for v in obj]
    if isinstance(obj, str):
        s = obj
        for old, new in repl_sorted:
            if old:
                s = s.replace(old, new)
        return s
    return obj


def strip_digest(img):
    if not isinstance(img, str):
        return img
    if "@sha256:" in img:
        return img.split("@sha256:", 1)[0]
    return img


def diff_values(path, a, b, out):
    """Deep-walk a and b, appending (path, a_leaf, b_leaf) tuples for every mismatch."""
    if a is MISSING or b is MISSING:
        if a != b:
            out.append((path, a, b))
        return
    if isinstance(a, dict) or isinstance(b, dict):
        da = a if isinstance(a, dict) else {}
        db = b if isinstance(b, dict) else {}
        for k in sorted(set(da) | set(db), key=str):
            diff_values(f"{path}.{k}" if path else str(k), da.get(k, MISSING), db.get(k, MISSING), out)
        return
    if isinstance(a, list) or isinstance(b, list):
        la = a if isinstance(a, list) else []
        lb = b if isinstance(b, list) else []
        for i in range(max(len(la), len(lb))):
            av = la[i] if i < len(la) else MISSING
            bv = lb[i] if i < len(lb) else MISSING
            diff_values(f"{path}[{i}]", av, bv, out)
        return
    if a != b:
        out.append((path, a, b))


def mask_env_side(s):
    if not isinstance(s, str) or "=" not in s:
        return s
    name, _, val = s.partition("=")
    if name in REVEAL_ENV:
        return s
    if ENV_SENSITIVE_RE.search(name) or RANDOM_VALUE_RE.match(val):
        return f"{name}=***"
    if ENV_URI_CRED_RE.search(val):
        # e.g. DATABASE_URL=postgres://user:pass@host -> DATABASE_URL=postgres://user:***@host
        return f"{name}={ENV_URI_CRED_RE.sub(r'\1***\3', val)}"
    return s


def finalize_diffs(diffs):
    out = []
    for path, a, b in diffs:
        if ENV_PATH_RE.search(path):
            a = mask_env_side(a) if isinstance(a, str) else a
            b = mask_env_side(b) if isinstance(b, str) else b
        out.append({"path": path, "src": a, "tgt": b})
    return out


def make_item(name, diffs, status=None):
    fdiffs = finalize_diffs(diffs or [])
    if status is None:
        status = "SAME" if not fdiffs else "DIFF"
    return {"name": name, "status": status, "diffs": fdiffs}


# ---------- normalization: swarm services ----------

def list_services(dir_):
    d = os.path.join(dir_, "swarm", "services")
    out = {}
    if os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            if fn.endswith(".json"):
                out[fn[:-5]] = os.path.join(d, fn)
    return out


def load_inspect_single(path):
    try:
        data = load_json(path)
    except json.JSONDecodeError:
        return None
    if isinstance(data, list):
        return data[0] if data else None
    return data


def normalize_service_mount(m):
    return {
        "Type": m.get("Type", ""),
        "Source": m.get("Source", ""),
        "Target": m.get("Target", ""),
        "ReadOnly": bool(m.get("ReadOnly", False)),
    }


def normalize_container_mount(m):
    return {
        "Type": m.get("Type", ""),
        "Source": m.get("Source", ""),
        "Target": m.get("Destination", m.get("Target", "")),
        "ReadOnly": not m.get("RW", True),
    }


def _mount_key(m):
    return (m["Type"], m["Source"], m["Target"], m["ReadOnly"])


def normalize_service(raw, ignore_digest, ignore_env):
    """raw = one element of a swarm/services/<name>.json array (docker service inspect)."""
    spec = dict(raw.get("Spec") or {})

    tt = dict(spec.get("TaskTemplate") or {})
    tt.pop("ForceUpdate", None)
    cs = dict(tt.get("ContainerSpec") or {})
    if ignore_digest and "Image" in cs:
        cs["Image"] = strip_digest(cs["Image"])
    env = [e for e in (cs.get("Env") or []) if e.split("=", 1)[0] not in ignore_env]
    cs["Env"] = sorted(env)
    mounts = [normalize_service_mount(m) for m in (cs.get("Mounts") or [])]
    cs["Mounts"] = sorted(mounts, key=_mount_key)
    tt["ContainerSpec"] = cs
    spec["TaskTemplate"] = tt

    labels = dict(spec.get("Labels") or {})
    if ignore_digest and "com.docker.stack.image" in labels:
        labels["com.docker.stack.image"] = strip_digest(labels["com.docker.stack.image"])
    spec["Labels"] = labels

    return spec


def compare_services(src_dir, tgt_dir, repl_sorted, ignore_digest, ignore_env):
    src_files, tgt_files = list_services(src_dir), list_services(tgt_dir)
    items = []
    for name in sorted(set(src_files) | set(tgt_files)):
        if name in src_files and name in tgt_files:
            src_raw = load_inspect_single(src_files[name])
            tgt_raw = load_inspect_single(tgt_files[name])
            # A file can be valid JSON but not the expected object shape (truncated export,
            # hand-edited fixture, "null", a bare number/string): treat that the same as
            # unreadable rather than crashing normalize_service() with an AttributeError.
            if not isinstance(src_raw, dict) or not isinstance(tgt_raw, dict):
                items.append(make_item(f"service:{name}", [("<file>",
                                                              "<ok>" if isinstance(src_raw, dict) else "unreadable/empty/malformed",
                                                              "<ok>" if isinstance(tgt_raw, dict) else "unreadable/empty/malformed")]))
                continue
            src_raw = apply_replacements(src_raw, repl_sorted)
            src_norm = normalize_service(src_raw, ignore_digest, ignore_env)
            tgt_norm = normalize_service(tgt_raw, ignore_digest, ignore_env)
            d = []
            diff_values("Spec", src_norm, tgt_norm, d)
            items.append(make_item(f"service:{name}", d))
        elif name in src_files:
            items.append(make_item(f"service:{name}", None, "MISSING_ON_TARGET"))
        else:
            items.append(make_item(f"service:{name}", None, "EXTRA_ON_TARGET"))
    return items


# ---------- nodes / networks / volumes ----------

def node_summary(n):
    desc = n.get("Description") or {}
    spec = n.get("Spec") or {}
    status = n.get("Status") or {}
    hostname = desc.get("Hostname") or status.get("Addr") or n.get("ID") or "?"
    return hostname, {"role": spec.get("Role", ""), "availability": spec.get("Availability", ""),
                       "labels": dict(spec.get("Labels") or {})}


def compare_nodes(src_dir, tgt_dir, repl_sorted):
    src_raw = [apply_replacements(n, repl_sorted) for n in load_array(os.path.join(src_dir, "swarm", "nodes.json"))]
    tgt_raw = load_array(os.path.join(tgt_dir, "swarm", "nodes.json"))
    src_raw, src_bad = split_malformed(src_raw)
    tgt_raw, tgt_bad = split_malformed(tgt_raw)

    items = []
    if src_bad or tgt_bad:
        items.append(make_item("nodes:<malformed>", [("<shape>", f"{src_bad} malformed entr(y/ies)", f"{tgt_bad} malformed entr(y/ies)")]))
    d = []
    diff_values("nodes.count", len(src_raw), len(tgt_raw), d)
    items.append(make_item("nodes:count", d))

    src_map = dict(node_summary(n) for n in src_raw)
    tgt_map = dict(node_summary(n) for n in tgt_raw)
    for name in sorted(set(src_map) | set(tgt_map)):
        if name in src_map and name in tgt_map:
            d = []
            diff_values("", src_map[name], tgt_map[name], d)
            items.append(make_item(f"node:{name}", d))
        elif name in src_map:
            items.append(make_item(f"node:{name}", None, "MISSING_ON_TARGET"))
        else:
            items.append(make_item(f"node:{name}", None, "EXTRA_ON_TARGET"))
    return items


def compare_networks(src_dir, tgt_dir, repl_sorted):
    src_raw = [apply_replacements(n, repl_sorted) for n in load_array(os.path.join(src_dir, "networks.json"))]
    tgt_raw = load_array(os.path.join(tgt_dir, "networks.json"))
    src_raw, src_bad = split_malformed(src_raw)
    tgt_raw, tgt_bad = split_malformed(tgt_raw)

    def summary(n):
        return n.get("Name", "?"), {"Driver": n.get("Driver", ""), "Attachable": bool(n.get("Attachable", False))}

    src_map = dict(summary(n) for n in src_raw)
    tgt_map = dict(summary(n) for n in tgt_raw)
    items = []
    if src_bad or tgt_bad:
        items.append(make_item("networks:<malformed>", [("<shape>", f"{src_bad} malformed entr(y/ies)", f"{tgt_bad} malformed entr(y/ies)")]))
    for name in sorted(set(src_map) | set(tgt_map)):
        if name in src_map and name in tgt_map:
            d = []
            diff_values("", src_map[name], tgt_map[name], d)
            items.append(make_item(f"network:{name}", d))
        elif name in src_map:
            items.append(make_item(f"network:{name}", None, "MISSING_ON_TARGET"))
        else:
            items.append(make_item(f"network:{name}", None, "EXTRA_ON_TARGET"))
    return items


def compare_volumes(src_dir, tgt_dir, repl_sorted):
    src_raw = [apply_replacements(n, repl_sorted) for n in load_array(os.path.join(src_dir, "volumes.json"))]
    tgt_raw = load_array(os.path.join(tgt_dir, "volumes.json"))
    src_raw, src_bad = split_malformed(src_raw)
    tgt_raw, tgt_bad = split_malformed(tgt_raw)
    src_names = {n.get("Name", "?") for n in src_raw}
    tgt_names = {n.get("Name", "?") for n in tgt_raw}
    items = []
    if src_bad or tgt_bad:
        items.append(make_item("volumes:<malformed>", [("<shape>", f"{src_bad} malformed entr(y/ies)", f"{tgt_bad} malformed entr(y/ies)")]))
    for name in sorted(src_names | tgt_names):
        if name in src_names and name in tgt_names:
            items.append(make_item(f"volume:{name}", []))
        elif name in src_names:
            items.append(make_item(f"volume:{name}", None, "MISSING_ON_TARGET"))
        else:
            items.append(make_item(f"volume:{name}", None, "EXTRA_ON_TARGET"))
    return items


# ---------- compose/plain docker: containers.json ----------

def normalize_container(raw, ignore_env):
    cfg = raw.get("Config") or {}
    hc = raw.get("HostConfig") or {}
    env = [e for e in (cfg.get("Env") or []) if e.split("=", 1)[0] not in ignore_env]
    mounts = [normalize_container_mount(m) for m in (raw.get("Mounts") or [])]
    return {
        "Image": cfg.get("Image", ""),
        "Env": sorted(env),
        "Mounts": sorted(mounts, key=_mount_key),
        "Labels": dict(cfg.get("Labels") or {}),
        "Cmd": cfg.get("Cmd"),
        "Entrypoint": cfg.get("Entrypoint"),
        "RestartPolicy": dict(hc.get("RestartPolicy") or {}),
        "PortBindings": dict(hc.get("PortBindings") or {}),
    }


def compare_containers(src_dir, tgt_dir, repl_sorted, ignore_env):
    src_raw = [apply_replacements(c, repl_sorted) for c in load_array(os.path.join(src_dir, "containers.json"))]
    tgt_raw = load_array(os.path.join(tgt_dir, "containers.json"))
    src_raw, src_bad = split_malformed(src_raw)
    tgt_raw, tgt_bad = split_malformed(tgt_raw)

    def cname(c):
        return (c.get("Name") or c.get("Id") or "?").lstrip("/")

    src_map = {cname(c): c for c in src_raw}
    tgt_map = {cname(c): c for c in tgt_raw}
    items = []
    if src_bad or tgt_bad:
        items.append(make_item("containers:<malformed>", [("<shape>", f"{src_bad} malformed entr(y/ies)", f"{tgt_bad} malformed entr(y/ies)")]))
    for name in sorted(set(src_map) | set(tgt_map)):
        if name in src_map and name in tgt_map:
            sn = normalize_container(src_map[name], ignore_env)
            tn = normalize_container(tgt_map[name], ignore_env)
            d = []
            diff_values("", sn, tn, d)
            items.append(make_item(f"container:{name}", d))
        elif name in src_map:
            items.append(make_item(f"container:{name}", None, "MISSING_ON_TARGET"))
        else:
            items.append(make_item(f"container:{name}", None, "EXTRA_ON_TARGET"))
    return items


def has_swarm_export(src_dir, tgt_dir):
    for d in (src_dir, tgt_dir):
        p = os.path.join(d, "swarm", "services")
        if os.path.isdir(p) and any(fn.endswith(".json") for fn in os.listdir(p)):
            return True
    return False


# ---------- reporting ----------

def show_val(v):
    if v is MISSING:
        return "<missing>"
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False, sort_keys=True)
    return str(v)


def trunc(v, n=120):
    s = show_val(v)
    return s if len(s) <= n else s[:n - 3] + "..."


def human_report(items):
    lines = []
    counts = {}
    for it in items:
        counts[it["status"]] = counts.get(it["status"], 0) + 1
        lines.append(f"{it['name']:<32} {it['status']}")
        for d in it["diffs"]:
            lines.append(f"  {d['path']}: {trunc(d['src'])} -> {trunc(d['tgt'])}")
    lines.append("")
    summary = ", ".join(f"{v} {k}" for k, v in sorted(counts.items()))
    lines.append(f"SUMMARY: {len(items)} item(s) - {summary}" if items else "SUMMARY: 0 items")
    return "\n".join(lines)


def jv(v):
    return "<missing>" if v is MISSING else v


def json_report(items):
    counts = {}
    out_items = []
    for it in items:
        counts[it["status"]] = counts.get(it["status"], 0) + 1
        out_items.append({
            "name": it["name"],
            "status": it["status"],
            "diffs": [{"path": d["path"], "src": jv(d["src"]), "tgt": jv(d["tgt"])} for d in it["diffs"]],
        })
    ok = all(it["status"] == "SAME" for it in items)
    return {"items": out_items, "summary": counts, "total": len(items), "ok": ok}


# ---------- main ----------

def localpath(p):
    """Git Bash with MSYS_NO_PATHCONV=1 hands native Windows Python paths like /c/Users/x, which
    Python would read as C:\\c\\Users\\x. Convert them to C:/Users/x."""
    if os.name == "nt" and p:
        m = re.match(r"^/([a-zA-Z])(/.*)?$", p)
        if m:
            return f"{m.group(1).upper()}:{m.group(2) or '/'}"
    return p


def main():
    ap = argparse.ArgumentParser(
        prog="parity.py",
        description="Compare a source and target Docker/Swarm export directory for parity.",
        epilog=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("src", help="source export dir (from stacks.py unpack)")
    ap.add_argument("tgt", help="target export dir (from stacks.py unpack)")
    ap.add_argument("--mapping", help="mapping.json; its 'replace' map is applied to the source side")
    ap.add_argument("--secrets", help="secrets.json; old->new rotated values are treated as equal")
    ap.add_argument("--ignore-digest", action="store_true", help="compare images as repo:tag only, ignore @sha256")
    ap.add_argument("--ignore-env", default="", help="comma-separated env var NAMEs to drop from Env comparisons")
    ap.add_argument("--reveal-env", default="", help="comma-separated env var NAMEs to print unmasked (default: anything secret-looking is masked)")
    ap.add_argument("--json", action="store_true", help="machine-readable JSON output")
    args = ap.parse_args()
    for k in ("src", "tgt", "mapping", "secrets"):
        setattr(args, k, localpath(getattr(args, k)))

    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    if not os.path.isdir(args.src):
        sys.stderr.write(f"[parity] source export dir not found: {args.src}\n")
        sys.exit(2)
    if not os.path.isdir(args.tgt):
        sys.stderr.write(f"[parity] target export dir not found: {args.tgt}\n")
        sys.exit(2)

    try:
        mapping = load_json(args.mapping) if args.mapping else None
    except json.JSONDecodeError as e:
        sys.stderr.write(f"[parity] invalid --mapping JSON ({args.mapping}): {e}\n")
        sys.exit(2)
    try:
        secrets = load_json(args.secrets) if args.secrets else None
    except json.JSONDecodeError as e:
        sys.stderr.write(f"[parity] invalid --secrets JSON ({args.secrets}): {e}\n")
        sys.exit(2)

    # Only string values are usable as a literal substring replacement; a mapping.json with a
    # non-string "replace" value (number/bool/null/list/object), or a "replace" key that isn't
    # itself an object, would otherwise crash instead of failing cleanly.
    _replace_raw = (mapping or {}).get("replace") if isinstance(mapping, dict) else None
    replace_map = ({k: v for k, v in _replace_raw.items() if isinstance(v, str)}
                    if isinstance(_replace_raw, dict) else {})

    rotated = {}
    if isinstance(secrets, dict):
        nested = secrets.get("rotated")
        if isinstance(nested, dict):
            rotated.update({str(k): str(v) for k, v in nested.items() if isinstance(v, str)})
        else:
            rotated.update({str(k): str(v) for k, v in secrets.items() if isinstance(v, str) and k != "rotated"})

    combined = {}
    combined.update(rotated)
    combined.update(replace_map)  # explicit mapping.json wins on key collisions
    repl_sorted = sorted(((k, v) for k, v in combined.items() if k), key=lambda kv: -len(kv[0]))

    ignore_env = {x.strip() for x in args.ignore_env.split(",") if x.strip()}
    REVEAL_ENV.update(x.strip() for x in args.reveal_env.split(",") if x.strip())

    if has_swarm_export(args.src, args.tgt):
        items = (compare_services(args.src, args.tgt, repl_sorted, args.ignore_digest, ignore_env)
                  + compare_nodes(args.src, args.tgt, repl_sorted)
                  + compare_networks(args.src, args.tgt, repl_sorted)
                  + compare_volumes(args.src, args.tgt, repl_sorted))
    else:
        items = compare_containers(args.src, args.tgt, repl_sorted, ignore_env)

    ok = all(it["status"] == "SAME" for it in items)
    if args.json:
        print(json.dumps(json_report(items), indent=2, ensure_ascii=False))
    else:
        print(human_report(items))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
