# INFRA_INVENTORY: a cross-session credential ledger for parallel Claude Code

When you run multiple Claude Code sessions in parallel — different projects, different terminals, the same Windows user — they don't see each other's work. The credentials one session creates are invisible to the next. The MCP server one session installs doesn't show up until the other restarts.

This is a 5-minute pattern that prevents the most expensive failure mode of multi-session Claude Code: duplicate infrastructure.

**TL;DR**
- A file-based append-only credential ledger at `~/.claude/INFRA_INVENTORY.md`
- Every session reads it at startup, writes to it whenever it creates a new PAT / API key / MCP / env var
- A 4-step pre-check forces verification before creating new infra
- Pairs well with real-time presence tools like `claude-presence`, but solves a different problem (audit history, not live coordination)

---

## The problem

I run several Claude Code sessions in parallel against different web platforms — a marketplace, a wellness app, a LINE bot. Each lives in its own folder. Each has its own `.mcp.json`, its own Vercel deployment, its own Supabase project.

But they share one Windows user. One `~/.claude.json`. One Anthropic account. One set of Windows env vars. One memory graph.

The first time I noticed: two sessions both created GitHub Personal Access Tokens for the same purpose. Session 1 made `claude-code-mcp` PAT, stored in env var. Session 2 didn't know — it created `claude-code-mcp-2`, stored in a different env var. Both worked. Neither knew the other existed. Months later, when one expired, I rotated the wrong one.

The cost wasn't catastrophic. But the pattern was: parallel sessions, no shared state, drift accumulates silently.

---

## The pattern

A single Markdown file at `~/.claude/INFRA_INVENTORY.md`. Append-only. Plain text. No daemon, no database, no MCP server.

Every Claude Code session does two things:

**On startup:** read this file (it's already in CLAUDE.md include scope, so it's automatically in context).

**Whenever creating new infra** (PAT, API key, MCP, env var, OAuth app, webhook, domain): append an entry.

```markdown
- 2026-05-15 · PAT · "claude-code-mcp" · scope repo+workflow · for github MCP · stored in: Windows User env `GITHUB_TOKEN`
- 2026-05-14 · API_KEY · Supabase PAT · for moodee project · stored in: Windows User env `MOODEE_SUPABASE_PAT`
- 2026-05-13 · MCP · custom MCP at `https://example.app/api/mcp/ops` · OAuth 2.1 + PKCE · 10 tools wrapping vendor APIs
- 2026-05-08 · ENV_VAR · `ANALYTICS_HMAC_SECRET` · 32-byte hex · stored in: Vercel env (3 envs)
```

The format is rigid enough to grep and loose enough to write fast:

```
- {YYYY-MM-DD} · {TYPE} · {NAME} · {SCOPE/PURPOSE} · stored in: {LOCATION}
```

**Types:** `PAT` · `API_KEY` · `MCP` · `OAUTH_APP` · `ENV_VAR` · `WEBHOOK` · `DOMAIN` · `SECRET`

**Critical rule:** **never write actual token values.** Names and locations only. The file lives alongside other Claude config — if it leaks, names should not be enough to reconstruct credentials.

---

## The 4-step pre-check

Before any Claude Code session creates a new credential or MCP, it runs this:

1. **Check Windows User env vars** — `[Environment]::GetEnvironmentVariable("VAR_NAME", "User")` — does this credential already exist by name?
2. **Read `~/.claude/INFRA_INVENTORY.md`** — does it list this credential under any other name?
3. **Check `~/.claude/memory-graph.json`** (or project memory) — has a previous session noted creating this for a specific project?
4. **Run `claude mcp list`** — for MCP, is this server already installed?

If the credential exists with sufficient scope → reuse. Don't create a duplicate.

If the credential exists but scope is insufficient → ask the user to **rotate or expand** the existing one. Don't create a parallel one.

Only create new if all 4 checks return empty.

This pre-check lives in CLAUDE.md as a global rule for every session. The cost is one read of a small Markdown file. The savings: preventing every variant of "you already have one of these, somewhere".

---

## Project ownership map

Beyond the chronological log, the file also holds a static table mapping each credential / MCP to which project it belongs to:

```markdown
| Resource | Owner project | Cross-project? | Notes |
|---|---|---|---|
| `APP_A_API_KEY` (Windows env) | App A | HIGH risk · scoped to App A account | Use with project-ref guard |
| `APP_B_API_KEY` (Windows env) | App B | scoped to App B account · cannot see App A | Token isolated by vendor account |
| `SHARED_TOKEN` (Windows env) | shared — one global account | OK | All projects bill to same account |
| GitHub PATs (×2) | shared — Classic PAT = all repos | MEDIUM risk · prefer Fine-grained PATs per repo | Used by github MCP user-scope |
```

This table protects against cross-project credential leakage. Before any session uses a sensitive credential, it can verify: "does the project I'm in own this resource?"

For sensitive operations (database PATCH, payment write, deploy), the rule is: **read the ownership row, verify cwd matches expected project, then proceed.**

---

## Why a file beats an MCP for this

The obvious alternative is a real-time MCP server that registers each session and lets them query each other. [`claude-presence`](https://github.com/garniergeorges/claude-presence) is exactly this — a small MCP server with presence registry, advisory locks, and a broadcast inbox.

But for credential audit specifically, a static file beats a dynamic service:

| Use case | File ledger | MCP server |
|---|---|---|
| Credential history audit | append-only log | weak (presence is live, not historical) |
| Project ownership map | readable table | weak (no built-in tabular query) |
| Cross-session coordination | weak (not real-time) | live registry |
| Resource locks (CI · ports) | weak | advisory locks |
| Broadcast inbox | weak | designed for this |

**They are complementary, not competing.** Keep the file for audit. Add a real-time presence MCP for live coordination if you need it.

Critically, the file is:
- Automatically loaded into every session via `CLAUDE.md` include
- Greppable from the command line
- Diffable in git
- Survives MCP server crashes / npm package removal
- Zero dependencies

---

## What it caught

A few weeks after adopting this pattern, I started a new session in a different project. The session asked me about a database connection. I asked it to set up a Supabase token. Before doing anything, it ran the 4-step pre-check.

It found: I already had `APP_A_SUPABASE_PAT` env var for project A. I had `APP_B_SUPABASE_PAT` for project B. The current project — project C — had no Supabase token yet. **Per the project ownership map, project C should NOT inherit either existing PAT** (different Supabase accounts).

The session declined to reuse. It walked me through creating a new project C–scoped PAT, named it `APP_C_SUPABASE_PAT`, and logged it correctly. The previous PATs stayed clean, scoped to their own projects.

Without the pre-check, the easiest path would have been: reuse `APP_A_SUPABASE_PAT`. It would have worked. And it would have given project C session full credentials to project A's database. The audit trail wouldn't exist.

This is a class of mistake that's invisible until it breaks something.

---

## Notes for adoption

- Initial setup: 5 minutes. Create the file with sections for `## GitHub` · `## Supabase` · `## Stripe` etc. Add the 4-step pre-check as a global CLAUDE.md rule.
- First few weeks: you'll forget to log. Set up a `PostToolUse` hook that watches for `vercel env add` / `claude mcp add` and appends a stub entry automatically.
- Migration from no-system: paste your existing Windows env var names (without values) into the file. Even without dates, having names visible prevents future duplicates.
- Pair with [claude-presence](https://github.com/garniergeorges/claude-presence) if you need real-time coordination on top of audit history.

---

## Related

- [`garniergeorges/claude-presence`](https://github.com/garniergeorges/claude-presence) — real-time presence MCP (complementary tool)
- [Claude Code · Agent Teams docs](https://code.claude.com/docs/en/agent-teams) — official orchestration patterns
- [Inter-session communication for multi-Claude workflows · Issue #24798](https://github.com/anthropics/claude-code/issues/24798)
- Companion writeup: [Splitting Claude Code into Two Contexts on One Windows Machine](../README.md) — the broader multi-context setup this pattern was extracted from
