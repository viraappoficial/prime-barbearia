---
name: sync-memory-to-git
description: "Always mirror memory updates into the project repo's memoria-claude/ folder and push, so Gabriel can access context from any machine."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 276cc831-811b-45dd-a594-f885a50f232f
  modified: 2026-07-25T14:09:51.367Z
---

Gabriel wants the memory files (this whole `memory/` directory) also kept as a synced copy inside the actual git repo, at `C:\Users\Usuario\Downloads\prime\memoria-claude\`, committed and pushed to GitHub.

**Why:** The real memory lives outside git, tied to this specific machine/path (`~/.claude/projects/.../memory/`). Gabriel sometimes works from a different PC and wants that PC's Claude session to be able to read the same context by pulling the repo and reading `memoria-claude/*.md`.

**How to apply:** Whenever a memory file in `~/.claude/projects/C--Users-Usuario-Downloads-prime/memory/` is created or edited, copy the updated file(s) into `C:\Users\Usuario\Downloads\prime\memoria-claude\` (same filename) and commit+push that folder along with whatever other work is being pushed in that turn — don't wait to be asked again. If on another machine and starting fresh (no local memory files exist yet under `~/.claude/projects/...`), check the project repo for `memoria-claude/*.md` and read those to recover context.
