# VPS-Clone-Helper (for coding agents other than Claude Code)

Claude Code reads `CLAUDE.md`. Any other agent that can run shell commands: follow the same protocol.

1. Read `CLAUDE.md` (first-run protocol) and `skills/vps-clone/SKILL.md` (the playbook).
2. `SKILL_DIR` = `skills/vps-clone`. The workspace is `.vps-clone/` (secrets, never commit it).
3. The permission-mode line comes from a Claude Code hook; other agents skip that line and ask the user to
   run the agent in its own "no confirmation" mode only if the user wants unattended operation.
