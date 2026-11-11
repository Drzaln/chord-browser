# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Build & Test

```bash
# The full local gate: SDK check, packages (warnings are errors), every test
# target serially, then the app build. Must be green before a push or release.
./scripts/prepush.sh

# Packages only
swift build --package-path Packages -Xswiftc -warnings-as-errors

# One test target (serial; a whole-suite run can stall, so go target by target)
swift test --package-path Packages --no-parallel --filter '^ChordStoreTests\.'

# The app
xcodebuild -project Chord.xcodeproj -scheme Chord -configuration Debug \
  -destination 'platform=macOS' build
```

Opt-in gates: `CHORD_REAL_EXTENSIONS=1` (real Chrome extension matrix) and
`CHORD_PERF=1` (startup budget, needs a Release build). Releases go through
`./scripts/release.sh <version> [build]`; the procedure is in
[AGENTS.md](AGENTS.md) under "Push to GitHub / release".

## Architecture Overview

Chord is a macOS browser (15.4+) on `WKWebView`. All logic lives in one Swift
package, `Packages/` (Swift 6 language mode); `ChordApp/` is the thin app target.

| Target | Role |
| --- | --- |
| `ChordCore` | Value types, ranking, converters. Foundation only. |
| `ChordLogging` | The one logging sink (`os.Logger` plus a rotating file). |
| `ChordPersistence` | GRDB/SQLite repositories and migrations. |
| `ChordEngine` | The WebKit boundary: web views, pooling, navigation, content blocking. |
| `ChordExtensions` | `WKWebExtension` host and the Chrome compatibility shim. |
| `ChordCrypto` | Chrome extension ids and signature verification. |
| `ChordSecrets` | Keychain and LocalAuthentication for the password vault. |
| `ChordMCP` | Local MCP server: JSON-RPC over a user-only Unix socket (ADR 027). |
| `ChordUpdater` | GitHub-release self-updater. |
| `ChordStore` | App state (`TabStore` and its extensions); wires everything in `AppEnvironment.live()`. |
| `ChordUI` | SwiftUI views. |
| `ChordTestSupport` | Fakes shared by the test targets. |

Read first: [BROWSER_SPEC.md](BROWSER_SPEC.md) (the contract),
[CHECKPOINT.md](CHECKPOINT.md) (current position), [docs/adr/](docs/adr)
(decisions). The project skills in `.claude/skills/` (`chord-browser-architecture`,
`-extensions`, `-maintenance`, `-youtube-ads`) carry the detail.

## Conventions & Patterns

- **WebKit stays in the engine layer.** Only `ChordEngine` and `ChordExtensions`
  import WebKit; no `WK*` type reaches `ChordStore` or `ChordUI`. One target per
  OS-framework boundary (ADR 011).
- **Never invent WebKit API.** Check the SDK headers. The release runner builds
  against the macOS 26 SDK, so `scripts/check-sdk-availability.py` must pass.
- **Docs move with the code.** A user-facing change updates `CHECKPOINT.md`,
  `README.md`, `docs/USER_GUIDE.md`, `SMOKE.md` and the matching skill in the
  same commit; a design decision gets an ADR.
- **Watch a regression test fail** against the bug before trusting it.
- **Verify UI work by driving the real app**, not by reasoning about it.
- **Stay in scope.** Non-spec features need the user's say first (BROWSER_SPEC §11).
- `AGENTS.md` is the fuller agent guide (beads workflow, release procedure).
  Keep the two in step.
