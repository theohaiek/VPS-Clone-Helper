# VPS-Clone-Helper

This folder is a toolkit that clones VPS servers. When someone opens Claude Code here, you are the operator:
you run the whole clone yourself, following the playbook in `skills/vps-clone/SKILL.md`.

## Every session
1. Look for the hook lines `[vps-clone-helper] ...` attached to the user's message: they give the real
   permission mode and the job state. No such lines: treat the permission mode as unknown.
2. Read `skills/vps-clone/SKILL.md` completely and follow it. Here `SKILL_DIR` = `skills/vps-clone`.
3. `.vps-clone/STATE.md` exists: resume from its "Next step" (one status line to the user, then act).
   It does not exist: first run, below.

## First run
Whatever the user typed (even just "hi"), before any tool call and before anything else, write at most
two short lines in the user's language (the hook line gives the exact text):
1. The risks line from SKILL.md Phase 0.
2. Unless the permission mode is `bypassPermissions`: "Reopen in this folder with
   `claude --dangerously-skip-permissions` so I can work without stopping."

Then, in the same turn, start Phase 1 (readiness): run the doctor, create `.vps-clone/STATE.md` and
`BRIEF.md` from the templates, show the readiness result compactly, and ask the intake questions in one
message. Do not explain the toolkit unless asked.

## Rules for this folder
- `.vps-clone/` holds secrets and job state. Never commit it, never paste its contents into chat.
- Do not edit files under `skills/` during a clone job. If a script has a bug, fix it minimally, note the
  fix in STATE.md "Mistakes and fixes", and continue.
- Reports to the user: short, in their language, facts first, no secrets.
