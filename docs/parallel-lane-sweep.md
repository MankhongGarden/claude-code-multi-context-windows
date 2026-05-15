# Parallel-Lane Sweep
## How to Close the Loop Between Subagent Output and the State Files That Tracked the Work

This is a pattern I've used to ship cross-cutting work across a multi-lane personal project (Backend / Frontend / CMO / CTO / Legal / Tester / Data Analyst) in one wall-clock pass. The novel part isn't "spawn subagents in parallel" — that's well-covered by Anthropic's [Agent Teams](https://code.claude.com/docs/en/agent-teams), [wshobson/agents](https://github.com/wshobson/agents), and [VoltAgent/awesome-claude-code-subagents](https://github.com/VoltAgent/awesome-claude-code-subagents). The novel part is the **feedback loop back to state**: how the commits each subagent makes are reflected — automatically — in the `HANDOFF_*.md` files that tracked the work.

Verified on a 7-lane sweep: 12 commits, ~12 minutes wall-time vs an estimated 70-90 minutes sequential.

## The setup, briefly

If you've used Claude Code for a real side project, you've probably ended up with a folder structure like this:

```
project/
├── codebase/                    ← your Next.js app, Python service, whatever
└── lane-workspaces/
    ├── Backend/HANDOFF_BACKEND.md
    ├── Frontend/HANDOFF_FRONTEND.md
    ├── CMO/HANDOFF_CMO.md
    ├── CTO/RISKS_REGISTER.md + HANDOFF_BACKEND.md
    ├── Legal/HANDOFF_BACKEND.md
    ├── Tester/HANDOFF_BACKEND.md + HANDOFF_FRONTEND.md
    └── ...
```

Each `HANDOFF_*.md` contains a list of `[ ]` tickable items aimed at a specific lane — "Backend: add column X to table Y", "Frontend: tighten the loading state on page Z", "CTO: review the new RLS policy in migration 042". The lane workers are the people (or now, the subagents) who close these items.

The naive workflow:

```
You: /handoff-do-Backend          → 8 minutes
You: /handoff-do-Frontend         → 12 minutes
You: /handoff-do-CMO              → 15 minutes
You: /handoff-do-CTO              → 10 minutes
You: /handoff-do-Legal            → 8 minutes
You: /handoff-do-Tester           → 12 minutes
You: /handoff-do-DataAnalyst      → 7 minutes
                                  ─────
                                   72 minutes
```

Sequential. The first six lanes wait on the seventh for no reason — they're independent. So fan them out.

## The fan-out

In Claude Code, fanning out subagents in parallel is one call with multiple `Agent` blocks in a single message:

```
Agent({ description: "Backend lane sweep",      subagent_type: "backend-lane",      run_in_background: true, prompt: "..." })
Agent({ description: "Frontend lane sweep",     subagent_type: "frontend-lane",     run_in_background: true, prompt: "..." })
Agent({ description: "CMO lane sweep",          subagent_type: "cmo-lane",          run_in_background: true, prompt: "..." })
Agent({ description: "CTO lane sweep",          subagent_type: "cto-lane",          run_in_background: true, prompt: "..." })
Agent({ description: "Legal lane sweep",        subagent_type: "legal-lane",        run_in_background: true, prompt: "..." })
Agent({ description: "Tester lane sweep",       subagent_type: "tester-lane",       run_in_background: true, prompt: "..." })
Agent({ description: "Data Analyst lane sweep", subagent_type: "data-analyst-lane", run_in_background: true, prompt: "..." })
```

This part is well-known. What's less covered: **each subagent has its own context window and can't see the others' commits.** So the moment lane 2 ships something that affects lane 5, lane 5 has no idea. Worse: when the subagents return, the main session has 7 reports to reconcile against 7 different `HANDOFF_*.md` files. That reconciliation is where the real cost lives — and it's where most of the public patterns leave you on your own.

## The differentiator: `[LANE-ID]` commit tags + `/handoff-sync`

The piece that closes the loop is a one-paragraph convention applied across the whole project:

> Every commit must start with a `[LANE-ID-short]` tag matching the handoff item it ships. For example, a Backend commit that closes item `[BE-08]` in `HANDOFF_BACKEND.md` starts with `[BE-08]`. A Tester commit that closes item `[TES-RLS-2026-05-13]` starts with `[TES-RLS-2026-05-13]`.

That's it. The tag isn't enforced by anything other than the lane subagent's prompt. The payoff: a downstream `/handoff-sync` skill can `git log --since="7 days ago"` and, for every `[X]` item in every `HANDOFF_*.md`, grep for a matching tag. If a tag exists, the item is marked `[x]` with the SHA. **The state files update themselves from git history**, not from a subagent reporting back to a process.

```
Lane subagent:
  - Reads HANDOFF_BACKEND.md
  - Ships item [BE-08]: adds the column
  - Commits "[BE-08] add x_count column to inspection_requests"

/handoff-sync (separate skill, runs after sweep):
  - Reads git log
  - Sees [BE-08]
  - Updates HANDOFF_BACKEND.md: `[x] BE-08 add x_count column (shipped: 8f3a1c)`
```

Two reasons this matters:

1. **The state-file → subagent → state-file roundtrip becomes lossless.** No "the report says it shipped but the file still says open" mismatch. Git is the source of truth; the state file is a view.
2. **A failed sweep is recoverable without re-reading the subagent reports.** If 5 of 7 lanes shipped and 2 crashed, you re-run the 2 — the 5 are already marked DONE because their commits exist.

## Lane discipline (or: why this stops scaling at one boundary)

Parallel sweeps assume the lanes are mostly independent — Backend touches `src/`, `migrations/`, API routes; CMO/Legal/CTO/Tester do NOT edit `src/` or app code and instead file handoffs back to Backend or Frontend. The convention lives in each lane's prompt:

```
You are the <LANE> worker for <PROJECT>. <constraints>

CRITICAL RULES:
- <LANE> only touches <files this lane owns>
- Cross-lane work = file a handoff item in the receiving lane's HANDOFF_*.md
- Every commit needs [LANE-ID-short] prefix matching the handoff item
- Skip user-only items (KYC, payment add, OAuth consent) — file in USER_TODO.md
```

A 7-lane sweep at the same time on the same repo will occasionally produce a merge conflict at the file level — two lanes editing the same `package.json`, two lanes touching the same `.env.example`. In practice, with the lane-discipline rules above, conflict rate is low enough that it's faster to resolve the rare conflict than to serialize.

## Cost optimization: not every lane needs Opus

The `Agent` tool accepts a `model` parameter (`opus` / `sonnet` / `haiku`). If omitted, every subagent inherits the parent model. On a top-tier model, that means a Tester sweep doing mechanical pattern-matching costs the same per output token as a Backend sweep designing a schema migration.

Verified mapping after a few sweeps:

| Lane | Model | Why |
|---|---|---|
| Backend (schema · migrations · API) | `opus` | Architectural reasoning; breaking-change risk |
| CTO (security audit) | `opus` | Critical analysis; false-negatives expensive |
| Legal (compliance audit) | `opus` | Precision; false-positives waste lawyer time |
| Frontend (UI · component work) | `sonnet` | Standard React patterns; sonnet sufficient |
| CMO (copy · brand) | `sonnet` | Writing + judgment; sonnet strong on language |
| Data Analyst (SQL · KPI queries) | `sonnet` | Standard query patterns |
| Tester (mechanical click-through · grep) | `haiku` | Pattern matching against prescribed steps |

Rough math on a typical 7-lane sweep using ~500K tokens spread across lanes: this mapping is ~60% cheaper on output tokens than running all 7 on the top tier, and there's no quality drop on Tester or Frontend that I've been able to measure on real ship cycles.

**When to escalate a downgraded lane:** Tester finds a security flag mid-sweep → next sweep route that finding to CTO at `opus`. Frontend hits a critical regression → next sweep override Frontend to `opus`. The default tier is a starting point, not a contract.

## The mandatory post-sweep review

This is the step I forgot the first three times. Every sweep, regardless of size, ends with a 5-minute reconciliation pass in the main session.

Read each subagent's full `<result>` body (not just the `<summary>` line — summaries lie). For each, sort findings into four buckets:

| Bucket | What goes here | Where it lands |
|---|---|---|
| ⚠️ **Warnings** | Security flags · permission errors · CI surface · "may be an issue" notes | `CTO/RISKS_REGISTER.md` new entry |
| 📋 **Requests / pending** | "Routed to lane X" · "waiting on Y" · sub-handoff items | Tickable entry in receiving lane's `HANDOFF_*.md` with the right `[<TAG>]` |
| 💡 **Lessons** | Surprising pattern · workaround · "had to do X because Y" | New memory entry IF reusable and non-obvious |
| ❌ **Errors** | Pull-rebase failures · stash needed · tsc errors · merge conflicts | Memory if pattern; fix if reachable |

Then bundle the post-review updates into one commit tagged `[POST-REVIEW-SWEEP-<date>]` and push.

I skip this every fifth time, and every fifth time I lose track of something — most often a routed handoff that the receiving lane never sees, because the subagent reported it but the handoff file was never touched.

## Anti-patterns

- **Sequential `Agent` calls when they could be parallel.** Defeats the whole point. One message, multiple `Agent` blocks.
- **Polling for status.** The harness sends a notification when each agent completes. Don't poll, don't sleep.
- **Letting one lane edit another's files directly.** File a handoff item. Reach-across edits break the `[LANE-ID]` tracking — `/handoff-sync` won't know whose item it was.
- **Inventing new tag prefixes per session.** Stick to the project's existing convention. Without consistent tags, the state files drift.
- **Forgetting `run_in_background: true`** — without it, the first `Agent` call blocks the main session and you lose parallelism even with multiple `Agent` blocks in the message.
- **Running a sweep without preconditions check.** If there's no `Legal/` folder, there's no Legal lane to sweep — fall back to the lanes that exist.

## What this isn't

- **Not a replacement for human review.** Subagents ship the boring 70%. The post-review pass + a human eye on the diff before merging to a release branch is the other 30%.
- **Not safe on hot critical paths.** Parallel sweeps are great for handoff-backlog grinding, mediocre for "the system is on fire right now" debugging. Use single-lane mode + a real human in the loop for incident response.
- **Not a substitute for a project plan.** The `HANDOFF_*.md` files have to be populated by someone — usually a planning session that's NOT a sweep. The sweep is the executor, not the planner.

## Lessons

1. **The hard problem is the loop back to state, not the parallel execution.** Anthropic's Agent Teams, wshobson/agents, awesome-claude-code-subagents — all give you good fan-out. Almost none of them give you "and here's how the subagent's commits update the file that listed the work." That's where the wall-clock win actually lives.
2. **A one-paragraph convention beats a framework.** The `[LANE-ID]` commit-tag rule is three sentences in each lane prompt. No tool, no plugin, no SDK. Just a discipline `/handoff-sync` can read.
3. **Tiered model assignment is free money.** Mechanical lanes don't need the top tier. The cost difference adds up faster than you'd think on regular sweeps.
4. **The post-review pass is non-optional.** Subagents can't see each other; the main session is the only place cross-lane synthesis happens. Skip it and your `RISKS_REGISTER.md` rots.

## Cross-reference

- The repo this doc lives in covers a related pattern: separating Claude Code's config + memory into two contexts on the same Windows machine, so personal and work projects don't bleed into each other's skills / MCPs / session history. See the main [README](../README.md).
- The infra-inventory doc in this repo covers another piece of the cross-session puzzle: how multiple Claude Code sessions running in parallel coordinate on infra creation (PATs, MCP servers, env vars) without stepping on each other.
