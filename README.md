# Splitting Claude Code into Two Contexts on One Windows Machine
## Junction Points, Win Store Sandbox, and a 14 GB Linux VM I Didn't Know I Was Running

**TL;DR**
- Moved 12 GB of Claude Code data off a 99%-full C: drive in one afternoon.
- Set up two independent Claude contexts on the same Windows machine: **Claude Desktop (Team account, day-job)** and **Claude CLI (Max account, personal projects)** — separate skills, MCPs, memory graphs, session history.
- Discovered three things the docs don't tell you:
  1. **Win Store apps follow NTFS junctions** even inside their sandboxed user data folder.
  2. **`CLAUDE_CONFIG_DIR` also scopes `.claude.json`** (the MCP config) — it lives *inside* the config dir, not at `$HOME`.
  3. **The "sandboxed bash" you use in Claude Code is a real Linux VM** with a 9.4 GB `rootfs.vhdx`, plus a 2.3 GB compressed mirror.
- Total Claude Desktop downtime: ~15 minutes (during the VM bundle move). Everything else live.

---

## Why this turned into a thing

Two pressures stacked at once:

1. **Disk space crisis.** C: drive at 2.0 GB free. Windows update margin is ~5 GB. One bad apt-equivalent operation away from a wedged system.
2. **Context bleed between work and personal.** My day-job uses a Team-tier Anthropic account; my side projects (a few web platforms — CheckMate marketplace, Moodee, LottoChecker) run on a personal Max-tier account. Same Windows user → same `~/.claude/` → my work sessions kept seeing side-project skills, side-project memory entries, side-project MCPs. Mixing them was a billing-and-context smell.

The architectural goal:
- Free space on C:
- Two scoped Claude environments, each with its own credential, skills folder, MCP config, memory graph, and session history.
- One Windows user, one machine, simultaneous use OK.

The non-negotiable: zero data loss. Full backup before any move.

---

## Phase 0–1: Backup + working copies

```
D:\ClaudeData\
├── .claude.bak-2026-05-15\    ← full backup of ~/.claude\ (23,349 files)
├── .claude-desktop\           ← copy 1: will become Desktop's home
└── .claude-personal\          ← copy 2: will become CLI's home
```

`robocopy /MIR /MT:8` did this in about 6 minutes. 838 MB per copy.

## Phase 2: Move `~/.claude/` to D: via Junction Point

The plan:
```
~/.claude/  →  junction  →  D:\ClaudeData\.claude-desktop\
```

The catch: Claude Desktop session was *running* during the migration. When I `mv ~/.claude ~/.claude.OLDREMOVE`, the daemon immediately recreated `~/.claude/projects/` to write its session log. The folder kept reappearing.

Solution: do it atomically.
1. `robocopy` any freshly-written files from the recreated `~/.claude` into `.claude-desktop\` first
2. `Remove-Item ~/.claude` immediately
3. `New-Item -ItemType Junction -Path ~/.claude -Target D:\ClaudeData\.claude-desktop`

Race window: a few hundred milliseconds. Worked.

```powershell
# Verify
PS> (Get-Item ~\.claude -Force).LinkType
Junction
PS> (Get-Item ~\.claude -Force).Target
D:\ClaudeData\.claude-desktop
```

Claude Desktop kept running through the swap, didn't notice. Junction is at NTFS layer, transparent to the app.

**Insight 1: Win Store apps follow junctions on user data.** The Claude package lives in `C:\Users\<u>\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\` — a sandboxed user data folder. I expected Win Store integrity checks to detect a junction inside this folder and freak out. They don't. The sandbox is at the filesystem permission layer (per-app data isolation), not at a folder-structure-verification layer. Junctions are followed transparently.

Disk savings: 486 MB on C: (the original `~/.claude\` content size).

## Phase 3: The CLI wrapper for the personal context

Created `D:\ClaudeData\claude-personal.cmd`:

```cmd
@echo off
set "CLAUDE_CONFIG_DIR=D:\ClaudeData\.claude-personal"
set "MEMORY_FILE_PATH=D:\ClaudeData\.claude-personal\memory-graph.json"
claude %*
```

Added `D:\ClaudeData` to user PATH. Now from any folder:
```
PS> claude-personal
[claude-personal] CLAUDE_CONFIG_DIR=D:\ClaudeData\.claude-personal
[claude-personal] MEMORY_FILE_PATH=D:\ClaudeData\.claude-personal\memory-graph.json
```

First run failed with:
```
Claude configuration file not found at: D:\ClaudeData\.claude-personal\.claude.json
```

**Insight 2: `CLAUDE_CONFIG_DIR` scopes `.claude.json` too.** Claude Code looks for `.claude.json` (the user-scope MCP config) at `$CLAUDE_CONFIG_DIR/.claude.json`, NOT at `$HOME/.claude.json`. The Anthropic docs I could find describe `CLAUDE_CONFIG_DIR` as redirecting "the config directory" but don't spell out that the MCP config file rides along.

This is good news for separation — copy `~/.claude.json` into `.claude-personal\.claude.json` and the two contexts have fully independent MCP rosters.

(Aside: PowerShell profile auto-load via `$PROFILE` is broken on this machine because my Documents folder is locale-named in a non-ASCII script and PowerShell mangles the path. Side-stepped by going through cmd via PATH instead.)

## Phase 4: The actual 14 GB

`du -sh` on the Claude Win Store package:

```
14G  Roaming/Claude/
├── vm_bundles/        12 GB   ← the big one
│   └── claudevm.bundle/
│       ├── rootfs.vhdx      9.4 GB
│       ├── rootfs.vhdx.zst  2.3 GB
│       ├── initrd          177 MB
│       ├── initrd.zst      174 MB
│       └── vmlinuz...
├── Claude Extensions/  830 MB
├── Cache/              631 MB
├── claude-code/        217 MB
└── ...
```

**Insight 3: Your "sandboxed bash" in Claude Code is a real Linux VM.** Hyper-V or WSL2, depending on your machine. `rootfs.vhdx` is a 9.4 GB Linux root filesystem. The `.zst` companion is the compressed download source kept for fast-recovery if the extracted VHDX corrupts. Plus an initrd, a kernel, a small session-data disk.

When Claude Code's tool runs `Bash`, it mounts this VHDX as a virtual disk and shells in. Every command in every Claude session runs inside this Linux VM — that's why `df -h /c` returns Linux-style output and shows your Windows drives mounted at `/c`, `/d`. The sandbox is fully separate from your Windows process tree.

The migration plan: move the entire `vm_bundles/` to D: via junction. Same trick as `~/.claude/`. But this one needs Claude Desktop *off* — Hyper-V keeps `rootfs.vhdx` locked while a sandboxed command is running.

Full script with `-Rollback` flag: [`scripts/move-vm-bundles.ps1`](scripts/move-vm-bundles.ps1). The meaningful bits:

```powershell
$src = "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\vm_bundles"
$dst = "D:\ClaudeData\vm_bundles"

# Pre-flight: Claude.exe must not be in Task Manager
# Pre-flight: VHDX files must not be locked (release after Hyper-V/WSL unmount)
foreach ($file in Get-ChildItem -Path $src -Filter "*.vhdx") {
    try {
        $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
        $stream.Close()
    } catch {
        throw "Still locked: $($file.FullName)"
    }
}

Move-Item -Path $src -Destination $dst -Force         # ~12 minutes for 12 GB
New-Item -ItemType Junction -Path $src -Target $dst
```

The script also has a `-Rollback` flag that does the inverse. Wrote it in case something exploded; happily, didn't need it.

After reopening Claude Desktop: sandboxed bash worked instantly. The first tool call mounted `rootfs.vhdx` from D: instead of C: — invisible to the app.

**Disk savings: 11.4 GB on C:.** From 2.8 GB free to 14.1 GB free.

## Phase 5: Context separation via pruning

Now the personal/work split. Both `.claude-desktop\` and `.claude-personal\` were identical copies — same skills, same MCPs, same memory. Time to diverge.

Goal: Desktop session (= day-job) should load *only* work-relevant context. Personal CLI keeps everything.

Pruned from `.claude-desktop\`:
- **Skills:** 42 → 19. Removed side-project-specific skills (cohort metrics for one of my marketplaces, brand-vocab linter, multi-lane workflow orchestrators, ...), web platform builders (`web-platform-builder`, `nextjs-shadcn-v4`, `supabase-migration`, ...), and other tools tied to my personal stacks.
- **MCPs:** 15 → 9. Removed `github` (personal repos), `gmail` (personal email), `google-calendar`, `sentry` (personal projects), `stripe` (personal marketplace), `connect-apps` (Composio for social profile setup).
- **Memory graph:** Emptied. All 14 entities were side-project-related. Personal CLI's copy retains the full audit trail.
- **Session histories:** Removed 7 personal project session folders.

What `.claude-desktop\` now sees:

```
Skills (19):   work-domain skills (domain analysis · data lookup · etc.)
               data-insights-analyst · excel-combine
               html-design · frontend-design · professional-pptx
               netlify-deploy · netlify-tracker
               claude-ai-design-briefing · claude-ai-design-implement
               session-close (work-tailored variant)
               batch-task · claude-api · algorithmic-art
               skill-checkup · skill-update
               (plus a handful of domain-specific skills not listed)

MCPs (9):      a11y · browserbase · chrome-devtools · cloudflare-docs
               memory · ms365 · sequential-thinking · shadcn · time
```

Personal CLI keeps the full 42 skills + 15 MCPs.

## Phase 6: Identity blocks in CLAUDE.md

Final touch — context awareness for each side. Added a section at the top of each `CLAUDE.md`:

```markdown
## Identity / Context Scope (read first)

**You are running inside Desktop (day-job · Team account)**

- Config dir: ~/.claude/ → junction → D:\ClaudeData\.claude-desktop\
- Account: Anthropic Team
- In-scope: work-domain tasks (domain analysis · reports · presentations · ...)
- Out-of-scope: side-projects (CheckMate · Moodee · LottoChecker) → use CLI Personal
- To switch: open new terminal → claude-personal
```

The Personal `CLAUDE.md` has the mirrored block — "you are in CLI Personal · for day-job tasks open Claude Desktop".

This is the guardrail against context confusion. If I open Claude Desktop and ask it to "set up Stripe for [my marketplace]", it now reads its identity block and says "that's out-of-scope; use CLI Personal".

## What else I'd do differently next time

- **Test `CLAUDE_CONFIG_DIR` before depending on it.** I assumed `.claude.json` was at `$HOME` based on default behavior. First `claude-personal` run failed with a clear error — fine, fast feedback — but a `--dry-run` mode that prints all resolved paths would have caught it before I built the wrapper.
- **The `.zst` files.** I kept them. They're 2.5 GB of compressed source that mirrors the extracted VHDXes. If Claude Desktop ever corrupts the extracted disks, the `.zst` files are the recovery path before re-download. Deletable for another 2.5 GB win if you accept "VM corruption = re-download from network."
- **PowerShell profile injection.** Tried first, abandoned because `$PROFILE` path corruption with non-ASCII folder names. Going through cmd via PATH was the right answer from the start.

## Anti-patterns to skip

A few things I considered and decided *against*:

- **Auto-detecting context from `pwd`** — "if cwd contains 'CheckMate', use personal config." Fragile. A folder rename or path typo silently switches you to the wrong account. Explicit command names (`claude` vs `claude-personal`) make every invocation auditable.
- **Overriding `claude` to be smart** — same problem, plus `PATH` order sensitivity. Other tools (Node-based scripts, CI hooks) that resolve `claude` via `which` could bypass the wrapper.
- **Symlinking `.claude.json` separately** — `CLAUDE_CONFIG_DIR` scoping handles this for free; no need to fight it.

## Lessons

1. **Junctions are the right tool when an app has a hardcoded path that points to a wrong volume.** Don't bother editing registry, moving installs, or symlinking individual files. Junction the whole folder.
2. **Multi-context separation = config-dir-scoped + env-var-overridden, not auto-detected.** Explicit beats clever for stateful operations.
3. **A heavy Win Store app is sometimes 95% runtime cache.** Investigate before assuming you need to uninstall.
4. **The Claude Code sandboxed bash is not a clever VM-less trick.** It's a Hyper-V/WSL Linux VM. Knowing this changes how you reason about command latency, file system access, and storage requirements.
5. **An identity-block at the top of CLAUDE.md is the cheapest, most effective guardrail against context confusion.** Cheaper than auto-detection, more robust than memory.

---

## Disclaimer

- Use at your own risk. I had a full backup before every step.
- Win Store integrity behavior is not formally documented. Junctions worked for me on Claude Desktop 1.7196 / Windows 11. Future versions may add tamper detection.
- The `vm_bundles` move requires Claude Desktop to be fully closed and Hyper-V to release VHDX locks. Race conditions = `Move-Item` failures, not data loss.

## Scripts in this repo

- [`scripts/move-vm-bundles.ps1`](scripts/move-vm-bundles.ps1) — the 12 GB junction script (with `-Rollback` flag)
- [`scripts/claude-personal.cmd`](scripts/claude-personal.cmd) — the CLI wrapper for the second context

---

*If you've done a similar migration and hit something I missed — especially around Win Store integrity verification or `CLAUDE_CONFIG_DIR` edge cases — open an issue or a PR. Happy to learn.*
