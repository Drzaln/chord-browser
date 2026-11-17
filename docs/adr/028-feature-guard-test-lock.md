# 028 — The feature guard: a lock file of tests that may not quietly disappear

**Status:** accepted (2026-11-17)

## Context

Most changes to Chord are made by coding agents. The test gate catches a change
that breaks an old behaviour while its test is still there. It does not catch
the other way an old feature gets lost: the agent building the new feature
deletes, empties or disables the test that was in its way, the suite stays
green, and the behaviour is gone without anyone having decided that.

An instruction not to do this (in `AGENTS.md`) is advice. It needs a gate.

## Decision

- `scripts/feature-guard.lock.json` lists every `@Test` function under
  `Packages/Tests` as `Target/File.swift::function`, with the number of
  assertions in its body (`#expect`, `#require`, `Issue.record`).
- `scripts/feature-guard.py check` fails when a listed test is missing, has
  fewer assertions than listed, or gained `.disabled(...)`. It also fails when
  a test exists that the lock does not list, so the lock cannot fall behind and
  a new feature's tests are guarded from the commit that adds them.
- `update` records additions, moves between files and added assertions, and
  refuses while anything is removed or weakened.
- `retire <test-id> --reason "..."` is the only way to accept a removal or a
  weakening. It writes the test, the date and the reason into the lock's
  `retired` list, so the commit's diff shows the decision to the reviewer.
- `check` is the first step of `scripts/prepush.sh` and a step in
  `.github/workflows/ci.yml`. It parses source text only: no build, about half
  a second.

## Consequences

- Removing a behaviour is still possible, but it is a visible, reasoned line in
  a diff, not a side effect.
- The count is of assertion call sites in the test's own body. A test can be
  weakened without lowering it (an `#expect` rewritten to something trivially
  true), and assertions inside helper functions are not counted. The guard
  narrows the gap; review of the diff still matters.
- A feature with no test is not guarded. The rule that a new feature ships with
  a test (`AGENTS.md`, "Feature guard") is what brings it under the lock.
- Renaming a test function reads as a removal plus an addition, and needs
  `retire`. That friction is accepted: a rename is rare and the reason is one
  line.
- Behaviour only checked by hand (`SMOKE.md`) is outside the guard.

## Alternatives considered

- **A hand-written feature list mapped to tests.** More readable, but it has to
  be kept current by the same agents it is meant to check, and it starts out
  incomplete. The lock is generated and complete from day one.
- **A drop in the total test count.** Deleting one test and adding another
  passes.
- **Coverage thresholds.** Slow, needs a build, and coverage of a line says
  nothing about whether its behaviour is asserted.
