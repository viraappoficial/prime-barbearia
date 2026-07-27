---
name: project-supabase-github-integration
description: "Supabase<->GitHub integration connected on prime-barbearia; no Docker locally, so migrations are handled without db pull/diff."
metadata: 
  node_type: memory
  type: project
  originSessionId: d00efe74-0f46-4d74-8409-19a33bc5f619
  modified: 2026-07-27T19:37:51.712Z
---

Supabase's native GitHub integration is connected on the Prime Barbearia project (ref `yojvzwkvtedxqlohpuug`), repo `gabrielparcel-byte/prime-barbearia`, production branch `master`, "Deploy to production" enabled, working directory left blank (supabase/ is at repo root).

Repo was prepped first: `supabase init` + `supabase link --project-ref yojvzwkvtedxqlohpuug`, committed `supabase/config.toml` and `supabase/.gitignore` (commit 07461fa). The `supabase/migrations/` folder was deliberately left EMPTY — Gabriel doesn't have Docker Desktop on this PC (confirmed he hit the same blocker on his home PC too), so `supabase db pull`/`db dump --linked` can't run (they need a Docker shadow database). No baseline migration was generated.

**Why:** Docker install was judged not worth the friction for a one-time baseline; leaving migrations empty is safe because nothing gets applied/reapplied on merge when there's nothing to apply. Confirmed via [[project_backend-migration-plan]] context that Supabase is the intended eventual backend anyway.

**How to apply:** Any future schema change must go through a migration file in `supabase/migrations/` (created via `supabase migration new <name>`, hand-written SQL) that gets auto-applied to production on merge to `master`. Since there's no local Docker to diff/test migrations first, before writing any new migration, check the CURRENT remote schema via the read-only `mcp__supabase__*` tools (e.g. `list_tables`, `execute_sql` for introspection) to avoid conflicting with existing objects. Don't assume Docker is available on Gabriel's machine — don't suggest `db pull`/local dev stack as a quick fix again without checking first.
