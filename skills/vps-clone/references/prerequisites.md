# Prerequisites and the Readiness Gate

Read this once, at Phase 1. It defines what "ready" means before any mutating step, and how to get
ready without asking the human for anything they did not have to give.

## 1. What "ready" means

Every row of the checklist in section 11 is OK, MISSING-but-fixed, or explicitly waived by the brief
(e.g. no DNS change requested). Nothing here is optional to check silently and skip; `doctor.py`
prints the table, you act on every MISSING row before Phase 2, and you record the result in
`.vps-clone/STATE.md`.

## 2. Local tools

### 2.1 `doctor.py`

```
doctor.py [--json] [--fix] [--source HOST[:PORT] ...] [--domain DOMAIN ...] [--quiet]
```

- With no flags: prints a human table `ITEM | STATUS | FIX` and creates `.vps-clone/` + `env.sh` if
  missing. `--json` prints the same data machine-readable (same schema, for a script or a later Claude
  turn to re-check without re-reading the table).
- `--fix` attempts the safe, local fixes it can (currently: `pip install --user paramiko` when
  paramiko is missing). It never touches remote servers or provider accounts.
- `--source HOST[:PORT]` adds a TCP-reachability probe for that address (does not need credentials —
  only proves port 22 answers before you spend a retry budget on `sshx.py check`).
- `--domain DOMAIN` resolves the zone's NS records via DNS-over-HTTPS and guesses the DNS provider
  from the NS suffix (see table in `providers.md` for which suffix maps to which provider). Repeatable.
- Status values: `OK` (present and working), `MISSING` (blocking — the gate cannot pass), `OPTIONAL`
  (nice to have, e.g. `gh`/`jq`/`rsync`), `WARN` (present but degraded, e.g. token env var name found
  but empty).
- Exit code: `0` if no `MISSING` (blocking) row remains, `1` otherwise. Every individual check is
  wrapped in try/except inside the script — a single failing check (e.g. `claude mcp list` timing out)
  degrades that one row to `WARN`/`MISSING`, it never crashes the whole run.
- Run it with whichever Python interpreter has 3.8+, picked at runtime:
  ```bash
  for p in python3 python "py -3"; do $p -c 'import sys; assert sys.version_info >= (3, 8)' 2>/dev/null && { PYB="$p"; break; }; done
  $PYB "<SKILL_DIR>/scripts/doctor.py" --fix
  ```

### 2.2 Install commands per OS

| Tool | Check | Windows | macOS | Linux (Debian/Ubuntu) |
|---|---|---|---|---|
| `ssh`/`ssh-keygen`/`scp` | `ssh -V` | ships with Git for Windows, or `winget install Microsoft.OpenSSH.Beta` for native OpenSSH | ships with macOS | `apt install openssh-client` |
| `python3` | `python3 --version` | `winget install Python.Python.3.12` | `brew install python3` | `apt install python3 python3-pip` |
| `paramiko` | `python3 -c "import paramiko"` | `python -m pip install --user paramiko` | `pip3 install --user paramiko` | `pip3 install --user paramiko` |
| `git` | `git --version` | `winget install --id Git.Git` | `brew install git` | `apt install git` |
| `curl` | `curl --version` | ships with Windows 10 1803+ | ships with macOS | `apt install curl` |
| `node`/`npx` (stdio MCPs) | `node --version` | `winget install OpenJS.NodeJS.LTS` | `brew install node` | `apt install nodejs npm` |
| `jq` (optional) | `jq --version` | `winget install jqlang.jq` | `brew install jq` | `apt install jq` |
| `gh` (optional) | `gh --version` | `winget install --id GitHub.cli` | `brew install gh` | `apt install gh` (needs GitHub's apt repo) |
| `rsync` (optional, not required) | `rsync --version` | not native, unreliable via scoop — do not depend on it | `brew install rsync` | `apt install rsync` |

Provider CLIs (`hcloud`, `doctl`, `vultr-cli`, `linode-cli`, `aws`, `gcloud`, `oci`, `ovhcloud`,
`hostinger`, `cntb`) have their own install/auth table in `providers.md` — `doctor.py` detects
whichever of these are already on PATH plus their auth/config files and token env vars (names only,
never values).

### 2.3 Windows / Git Bash traps

| Trap | Symptom | Fix |
|---|---|---|
| MSYS path conversion | a remote path like `/etc` or `/root` gets rewritten to `C:/Program Files/Git/etc` before it reaches `ssh`/the remote shell | `export MSYS_NO_PATHCONV=1` (value irrelevant, only needs to exist) — `env.sh` written by `doctor.py` already exports it for every command that sources it |
| Two `ssh.exe` on PATH | behavior differs depending on which one resolves first (Windows OpenSSH vs Git's bundled ssh) | `where ssh` (or `Get-Command ssh -All` in PowerShell); prefer the native `C:\Windows\System32\OpenSSH\ssh.exe` for consistency with the Windows `ssh-agent` service |
| No `rsync` on Windows | `command -v rsync` fails, nothing to fall back to natively | not a gap: `sshx.py` uses paramiko SFTP (`--put`/`--put-tree`/`--get`) for files and `sshx.py pipe` for streaming (`tar czf - . \| ssh dst 'tar xzf -'`-equivalent without a local `tar`) — never plan around having rsync |
| `ssh-agent` service disabled | `ssh-add` fails with "could not open a connection" | not needed here (`sshx.py` uses `key_filename=`, not the agent) — only matters if you shell out to raw `ssh` yourself |
| CRLF in a script generated on Windows, run on Linux | `bad interpreter`, silent syntax error remotely | not your problem if you use `sshx.py --put`/`--put-tree`/`--script` — it strips `\r\n` -> `\n` for known text extensions automatically |

## 3. Permission mode

The only documented way to know the session's permission mode from inside the conversation is the
`UserPromptSubmit` hook: it receives `permission_mode` in its stdin JSON (`default`, `plan`,
`acceptEdits`, `auto`, `dontAsk`, or `bypassPermissions`; `SessionStart` does not receive it, verified on
Claude Code 2.1.284) and this toolkit's hook (`hooks/vps-clone-hook`) prints it once per session
as a `[vps-clone-helper] permission_mode=...` context line. There is no tool call that reads it later in the session — trust what Phase 0
saw at startup, and treat any permission prompt that actually appears mid-run as proof the mode is
not `bypassPermissions` after all.

- Not `bypassPermissions`: Phase 0 tells the user to reopen with `claude --dangerously-skip-permissions`
  (equivalent to `--permission-mode bypassPermissions`) in one line, and still starts Phase 1 in the
  same turn; the next session resumes from `STATE.md`, so reopening loses nothing.
- In `bypassPermissions`, Claude Code still does **not** auto-approve: `AskUserQuestion` and any tool
  requiring live interaction, and `rm`/`rmdir` on critical local paths (filesystem root, `~`) — those
  still prompt with a timeout even in bypass. This is about the local Claude Code process; it has no
  bearing on running commands as root **on the remote target/source servers over SSH**, which is normal
  and expected for this skill.
- Bypass mode itself refuses to let the Claude Code process run as root/sudo on Linux/macOS (not
  Windows) unless inside a recognized sandbox — if the human is running the harness as root, ask them
  to rerun as a normal user.

## 4. Source access

Register every source node before reading anything from it:

```bash
. .vps-clone/env.sh && "$PY" "$S/sshx.py" add src1 203.0.113.10 --user root --key keys/source_id_ed25519 --role source
# or, password auth:
. .vps-clone/env.sh && "$PY" "$S/sshx.py" add src1 203.0.113.10 --user root --password-env SRC1_PASSWORD --role source
```

- Key or password, either works — `sshx.py` is pure paramiko, so a password-only source needs no
  `sshpass`/Plink/Expect workaround (those are the usual raw-`ssh` fallback, not needed here).
- `--password-env VAR` reads the password from an environment variable the user exported before
  starting Claude; prefer it over `--password` on the command line when the human can set an env var.
- Non-root login: add `--sudo`; `sshx.py` then wraps every command as `sudo -n bash -c '...'`
  (non-interactive — if the account needs a sudo password, treat that host as read-only-blocked and
  ask once, since prompting for a sudo password mid-command cannot be scripted safely).
- Role `source` makes `sshx.py` refuse anything that looks mutating (see `MUTATING` pattern in
  `sshx.py`) unless `--allow-write` is passed for that one call — used only for temporary dumps under
  `/tmp` that get deleted afterward.
- Verify with:
  ```bash
  . .vps-clone/env.sh && "$PY" "$S/sshx.py" check src1
  ```
  This prints login user/uid, root-or-sudo-nopasswd status, OS/kernel/arch, CPU/RAM/swap, root disk
  size+usage, hostname/timezone, and Docker server version + swarm state if Docker is present — enough
  to fill the topology map in Phase 2 without a full inventory run yet.

## 5. Target provider access

Try in this order, stop at the first that works, and use it for the whole clone (do not mix methods
mid-run without a reason):

1. **API token / CLI context** — fastest and fully scriptable. `doctor.py` reports which provider
   CLIs are on PATH and whether they look authenticated (config file present, or the provider's token
   env var name is set — never its value). Full install/auth/command reference: `providers.md`.
2. **Provider MCP server**, if one is connected (see section 7) — same capabilities as the API, driven
   through tool calls instead of shell commands.
3. **Logged-in browser via Claude in Chrome** — last resort, only when neither of the above is
   available (e.g. the provider has no CLI/MCP, or the account only has interactive 2FA). Before
   creating or buying anything this way: read the account name/email shown in the panel and match it
   against the account named in `BRIEF.md`. The one real failure this guards against: being logged into
   the wrong account's browser session and provisioning (or worse, buying) into someone else's account.
   Full protocol (form filling, multi-value fields, order confirmation): `providers.md`.

## 6. DNS access

Same order of preference as section 5: token/CLI first, DNS MCP second, logged-in browser last.
`doctor.py --domain <domain>` narrows the search by guessing the provider from the zone's NS records
(Cloudflare, Route53/AWS, DigitalOcean, Hetzner DNS, Hostinger, GoDaddy, Namecheap, Google, Azure,
Vultr, Linode, OVH, Porkbun, Contabo — matched by NS suffix; `registro.br` has no public API at all,
flag it as manual/browser-only immediately). DNS provider CLI/API commands:
`providers.md`, "DNS: create an A record" section.

## 7. MCP discovery

```bash
claude mcp list            # every configured server + connection status
claude mcp get "<name>"    # transport, URL/command, headers (redacted), OAuth status
```

Inside the session, without a shell: `ToolSearch` with a query naming providers, e.g.
`"hetzner OR cloudflare OR digitalocean OR vultr OR linode OR aws OR hostinger OR route53 OR godaddy OR namecheap OR dns"`.
An empty result means the server is not connected — go add it (section 8), do not ask the human to do
it unless adding it also needs a credential only they have.

**Fallback (plan B, not the primary path):** an MCP binary installed globally via npm but never
registered with `claude mcp add` can still be driven directly over stdio with raw JSON-RPC 2.0,
talking to the `.cmd`/binary in `%APPDATA%\npm\<binary>.cmd` (or the platform equivalent):

```
-> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-03-26","capabilities":{},"clientInfo":{"name":"vps-clone","version":"1.0"}}}
<- {"jsonrpc":"2.0","id":1,"result":{...}}
-> {"jsonrpc":"2.0","method":"notifications/initialized"}
-> {"jsonrpc":"2.0","id":2,"method":"tools/list"}
<- {"jsonrpc":"2.0","id":2,"result":{"tools":[...]}}
-> {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"<tool>","arguments":{...}}}
<- {"jsonrpc":"2.0","id":3,"result":{...}}
```

Only reach for this when `claude mcp add` genuinely cannot be used in the environment (e.g. no shell
access to register it, or a workspace-trust dialog you cannot answer) — it exists so a working
integration is never blocked by registration mechanics alone.

## 8. Adding MCP servers

```bash
# any remote HTTP MCP (generic pattern) — Cloudflare official remote server
claude mcp add --transport http cloudflare https://mcp.cloudflare.com

# DigitalOcean — official remote server (preferred)
claude mcp add --transport http digitalocean https://mcp.digitalocean.com
# DigitalOcean — local stdio alternative, needs a token [unverified exact npm package name]
claude mcp add digitalocean-local -e DIGITALOCEAN_API_TOKEN="<token>" -- npx @digitalocean/mcp

# Hostinger — OAuth in the browser (preferred, no token to manage)
claude mcp add --transport http hostinger https://mcp.hostinger.com
# Hostinger — token-based stdio alternative, needs Node >= 24
claude mcp add hostinger -e HOSTINGER_API_TOKEN="<token>" -- npx -y hostinger-api-mcp@latest
```

Scope flags: `--scope project` writes to the repo's `.mcp.json` (shared, triggers a trust dialog for
whoever opens the repo next); `--scope user` applies to every session on this machine; default is
local/session-only. For a one-off clone job, `--scope user` is usually right — the credential and the
convenience should outlive this one job.

Per-provider MCP repos and star counts beyond the two examples above: the `MCP` row of each
provider's table in `providers.md`.

## 9. Claude in Chrome

- Check connection: `/chrome` inside the session (shows `Status: Enabled` / `Extension: Installed`),
  or list connected browsers with the tool once loaded:
  `ToolSearch query "select:mcp__claude-in-chrome__list_connected_browsers"`, then call it — empty/
  error means the extension is not connected.
- Launch with it explicitly: `claude --chrome` (first time shows a per-site permission dialog).
- Requirements: Chrome/Edge/Brave/Arc/Vivaldi/Opera (Chromium-based) with the "Claude in Chrome"
  extension >=1.0.36 installed; a direct Anthropic login (Pro/Max/Team/Enterprise) via `/login` — it
  does **not** work with an API key, a long-lived `claude setup-token`, or Bedrock/Vertex/Foundry
  auth; not supported under WSL.
- If Claude tries to use the browser and the extension is not detected in an interactive session,
  Claude Code itself shows an install/skip prompt — that is the human's cue to install it, not
  something to script around.
- Troubleshooting: `chrome://extensions` to confirm it is enabled; on Windows the native-messaging
  host registration lives under `%LOCALAPPDATA%` / `HKCU\Software\Google\Chrome\NativeMessagingHosts\`.

## 10. What to ask the human, and when

Everything not in this table, do yourself (Iron rule 5 in `SKILL.md`) — discover tools, register
hosts, read account identity, run commands. Ask exactly once per item, batched into the Phase 1 intake
message when possible.

| Ask for | Why it cannot be done autonomously |
|---|---|
| Source SSH credential (password or key path), if truly not discoverable | Only the human has it |
| 2FA code / captcha solve | Cannot be automated; do not attempt to bypass |
| Purchase approval beyond the cap in `BRIEF.md`, or any purchase at all if the brief marks it unauthorized | Rule 6 — money needs a yes |
| Login to a provider/DNS panel when no token, CLI context, MCP, or existing browser session works | No credential exists yet for Claude to use |
| A destructive action the brief does not cover (deleting the source, dropping data, skipping the read-only guard permanently) | Outside the scope Claude was given consent for |
| Confirmation that a browser session belongs to the right account, only if the identity shown is ambiguous | Wrong-account purchases are the one mistake with no undo |

## 11. Readiness checklist

| Item | How to verify | Fix |
|---|---|---|
| `ssh` / `ssh-keygen` / `scp` | `ssh -V` | section 2.2 |
| `python3` >= 3.8 | `python3 --version` (or `python`, `py -3`) | section 2.2 |
| `paramiko` | `python3 -c "import paramiko"` | `pip install --user paramiko`, or `doctor.py --fix` |
| Workspace created | `.vps-clone/env.sh` exists | run `doctor.py` once (creates it) |
| Permission mode | the hook line said `permission_mode=bypassPermissions` | reopen with `claude --dangerously-skip-permissions` |
| `claude mcp list` reachable | command returns without erroring | not blocking — `doctor.py` degrades this row to WARN and falls back to text parsing |
| Source SSH reachable | `sshx.py check src1` (or `src2`, ...) succeeds | fix credential/IP with the human, or `doctor.py --source IP:22` to isolate a network-vs-auth problem |
| Source root/sudo | `check` output shows `root=yes` or `root=sudo-nopasswd` | if only `root=NO`, inventory still works read-only; note the limitation in `STATE.md`, ask for a better credential only if later phases need writes |
| Target provider access | token/CLI auth OK, or provider MCP connected, or Chrome connected and logged into the right account | section 5 |
| DNS access (only if the brief changes DNS) | token/CLI auth OK, or DNS MCP connected, or Chrome connected | section 6 |
| `node`/`npx` (only if a stdio MCP is needed) | `node --version` >= the MCP's requirement (e.g. Hostinger needs >=24) | section 2.2 |
| `jq`/`gh`/`rsync` | any present | optional — never a blocker |
