#!/usr/bin/env bash
# Prompt hook: permission mode parsing, first-run protocol, once per session, re-armed by SessionStart,
# plugin-mode silence, resume.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
M=$(mktemp -d)
trap 'rm -rf "$T" "$M"' EXIT
export TMPDIR="$M" CLAUDE_PROJECT_DIR="$T"
fail(){ echo "FAIL: $*"; exit 1; }
hook(){ bash hooks/vps-clone-hook "$@"; }
ups(){ printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","permission_mode":"%s","prompt":"%s"}' "$1" "$2" "$3"; }

out=$(ups s1 bypassPermissions "hi" | hook --always)
grep -q 'permission_mode=bypassPermissions' <<<"$out" || fail "mode not parsed"
grep -q 'FIRST RUN' <<<"$out" || fail "first run not announced"
grep -q 'Risks:' <<<"$out" || fail "risk line missing"
grep -q 'dangerously' <<<"$out" && fail "reopen line shown in bypass mode"

out=$(ups s1 bypassPermissions "again" | hook --always)
[ -z "$out" ] || fail "must speak only once per session"

printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}' | hook --always >/dev/null
out=$(ups s1 bypassPermissions "after compact" | hook --always)
grep -q 'FIRST RUN' <<<"$out" || fail "SessionStart must re-arm the output"

out=$(ups s2 default "hi" | hook --always)
grep -q 'dangerously-skip-permissions' <<<"$out" || fail "reopen line missing in default mode"

out=$(ups s3 default "fix my css" | hook)
[ -z "$out" ] || fail "plugin mode must be silent for unrelated prompts without a workspace"
out=$(ups s4 default "/vps-clone-helper:vps-clone" | hook)
grep -q 'FIRST RUN' <<<"$out" || fail "plugin mode must speak when the skill is invoked"

mkdir -p "$T/.vps-clone"
printf '# s\n\n## Next step\nrun parity\n\n## Phases\n' > "$T/.vps-clone/STATE.md"
out=$(ups s5 auto "continue" | hook)
grep -q 'run parity' <<<"$out" || fail "next step not shown"
grep -q 'reopen' <<<"$out" || fail "bypass reminder missing on resume"

out=$(hook --always </dev/null)
grep -q 'permission_mode=unknown' <<<"$out" || fail "empty stdin must give unknown"
echo "hook ok"
