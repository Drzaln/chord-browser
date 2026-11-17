#!/usr/bin/env python3
"""The feature guard: tests that exist may not quietly stop existing (ADR 028).

Every behaviour Chord has is pinned by a test. A change that adds a feature can
break an old one in two ways: the old test fails (the test gate catches that),
or the old test is deleted, emptied or switched off along with the behaviour
(nothing caught that). This script closes the second way.

`scripts/feature-guard.lock.json` lists every test in `Packages/Tests` with the
number of assertions in it. `check` compares the tree to that list and fails on:

  removed    a locked test is gone (deleted, renamed, commented out)
  weakened   a locked test has fewer assertions than it was locked with
  disabled   a locked test gained `.disabled(...)`
  unlocked   a test exists that the lock does not list yet

    scripts/feature-guard.py check
    scripts/feature-guard.py update
    scripts/feature-guard.py retire <test-id> --reason "<why>"
    scripts/feature-guard.py list [substring]

`update` records what is safe to record on its own: new tests, tests that
gained assertions, tests that moved to another file. It refuses to touch a
removed, weakened or disabled test. Those need `retire`, which takes the reason
and writes it into the lock, where the commit's diff shows it to whoever
reviews the change. A feature the user asked to remove is retired; a feature
that got in the way of a new one is not.

A test id is `Target/File.swift::function`.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "Packages" / "Tests"
LOCK = ROOT / "scripts" / "feature-guard.lock.json"

ASSERTION = re.compile(r"#expect\b|#require\b|\bIssue\.record\b|\bXCTAssert\w*|\bXCTFail\b|\bXCTUnwrap\b")
FUNC = re.compile(r"\bfunc\s+(`[^`]+`|\w+)")


def blank_noncode(source: str) -> str:
    """The source with comments and string contents replaced by spaces.

    Same length and same line breaks as the input, so offsets still line up.
    Without this a brace inside a string, or a commented-out `@Test`, would be
    read as code.
    """
    out = list(source)
    i, n = 0, len(source)

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        two = source[i:i + 2]
        if two == "//":
            end = source.find("\n", i)
            end = n if end == -1 else end
            blank(i, end)
            i = end
        elif two == "/*":
            depth, j = 1, i + 2
            while j < n and depth:
                if source[j:j + 2] == "/*":
                    depth, j = depth + 1, j + 2
                elif source[j:j + 2] == "*/":
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif source[i] == '"' or (source[i] == "#" and re.match(r'#+"', source[i:])):
            hashes = len(source[i:]) - len(source[i:].lstrip("#"))
            start = i + hashes
            quote = '"""' if source[start:start + 3] == '"""' else '"'
            closer = quote + "#" * hashes
            j = start + len(quote)
            while j < n:
                if not hashes and source[j] == "\\":
                    j += 2
                elif source.startswith(closer, j):
                    break
                elif quote == '"' and source[j] == "\n":
                    break  # unterminated; do not swallow the rest of the file
                else:
                    j += 1
            blank(start + len(quote), j)
            i = j + len(closer)
        else:
            i += 1
    return "".join(out)


def balanced(code: str, start: int, open_ch: str, close_ch: str) -> int:
    """Index just past the bracket that closes the one at `start`."""
    depth = 0
    for i in range(start, len(code)):
        if code[i] == open_ch:
            depth += 1
        elif code[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
    return len(code)


def scan_file(path: Path) -> dict[str, dict]:
    """Every `@Test` function in one file: assertion count and disabled flag."""
    code = blank_noncode(path.read_text(encoding="utf-8"))
    relative = path.relative_to(TESTS).as_posix()

    # A disabled suite disables everything in the file's suites.
    suite_disabled = False
    for match in re.finditer(r"@Suite\b\s*\(", code):
        end = balanced(code, match.end() - 1, "(", ")")
        if ".disabled(" in code[match.start():end]:
            suite_disabled = True

    found: dict[str, dict] = {}
    for match in re.finditer(r"@Test\b", code):
        cursor = match.end()
        attribute = ""
        rest = code[cursor:]
        if rest.lstrip().startswith("("):
            open_at = cursor + (len(rest) - len(rest.lstrip()))
            cursor = balanced(code, open_at, "(", ")")
            attribute = code[open_at:cursor]
        func = FUNC.search(code, cursor)
        if not func:
            continue
        name = func.group(1).strip("`")
        # The body opens at the first `{` after the parameter list.
        params = code.find("(", func.end())
        after_params = balanced(code, params, "(", ")") if params != -1 else func.end()
        body_open = code.find("{", after_params)
        if body_open == -1:
            continue
        body = code[body_open:balanced(code, body_open, "{", "}")]

        test_id = f"{relative}::{name}"
        serial = 2
        while test_id in found:  # same name twice in one file (two suites)
            test_id = f"{relative}::{name}#{serial}"
            serial += 1
        found[test_id] = {
            "assertions": len(ASSERTION.findall(body)),
            "disabled": suite_disabled or ".disabled(" in attribute,
        }
    return found


def scan_tree() -> dict[str, dict]:
    tests: dict[str, dict] = {}
    for path in sorted(TESTS.rglob("*.swift")):
        tests.update(scan_file(path))
    return tests


def load_lock() -> dict:
    if not LOCK.exists():
        return {"version": 1, "tests": {}, "disabled": [], "retired": []}
    return json.loads(LOCK.read_text(encoding="utf-8"))


def save_lock(lock: dict) -> None:
    lock["tests"] = dict(sorted(lock["tests"].items()))
    lock["disabled"] = sorted(set(lock["disabled"]))
    # One test per line, so a change to the lock reads as a change to tests.
    lines = ["{", '  "version": 1,', '  "tests": {']
    items = list(lock["tests"].items())
    for index, (test_id, count) in enumerate(items):
        comma = "," if index < len(items) - 1 else ""
        lines.append(f"    {json.dumps(test_id)}: {count}{comma}")
    lines.append("  },")
    lines.append('  "disabled": ' + json.dumps(lock["disabled"], indent=4).replace("\n", "\n  ") + ",")
    lines.append('  "retired": ' + json.dumps(lock["retired"], indent=4, ensure_ascii=False).replace("\n", "\n  "))
    lines.append("}")
    LOCK.write_text("\n".join(lines) + "\n", encoding="utf-8")


def function_of(test_id: str) -> str:
    return test_id.split("::", 1)[1]


def target_of(test_id: str) -> str:
    return test_id.split("/", 1)[0]


class Diff:
    """What changed between the lock and the tree."""

    def __init__(self, lock: dict, tree: dict[str, dict]) -> None:
        locked = lock["tests"]
        locked_disabled = set(lock["disabled"])
        missing = [t for t in locked if t not in tree]
        extra = [t for t in tree if t not in locked]

        # A locked test that vanished while an unlocked one with the same
        # function name appeared in the same target was moved, not removed.
        self.moved: list[tuple[str, str]] = []
        for old in list(missing):
            candidates = [
                new for new in extra
                if function_of(new).split("#")[0] == function_of(old).split("#")[0]
                and target_of(new) == target_of(old)
            ]
            if len(candidates) == 1:
                self.moved.append((old, candidates[0]))
                missing.remove(old)
                extra.remove(candidates[0])

        self.removed = sorted(missing)
        self.unlocked = sorted(extra)
        self.weakened: list[tuple[str, int, int]] = []
        self.strengthened: list[tuple[str, int, int]] = []
        self.disabled: list[str] = []
        self.reenabled: list[str] = []

        pairs = [(t, t) for t in locked if t in tree] + self.moved
        for old, new in pairs:
            was, now = locked[old], tree[new]["assertions"]
            if now < was:
                self.weakened.append((new, was, now))
            elif now > was and old == new:
                self.strengthened.append((new, was, now))
            if tree[new]["disabled"] and old not in locked_disabled:
                self.disabled.append(new)
            if not tree[new]["disabled"] and old in locked_disabled:
                self.reenabled.append(new)

    @property
    def violations(self) -> bool:
        return bool(self.removed or self.weakened or self.disabled)

    @property
    def stale(self) -> bool:
        return bool(self.unlocked or self.moved or self.strengthened or self.reenabled)


def report_violations(diff: Diff) -> None:
    for test_id in diff.removed:
        print(f"  removed   {test_id}")
    for test_id, was, now in diff.weakened:
        print(f"  weakened  {test_id}  ({was} -> {now} assertions)")
    for test_id in diff.disabled:
        print(f"  disabled  {test_id}")
    print(
        "\nThese tests pin behaviour that already shipped. If the change was not meant\n"
        "to remove that behaviour, restore the test and make it pass. If the user\n"
        "asked for the behaviour to go, retire each one with the reason:\n"
        '    scripts/feature-guard.py retire "<test-id>" --reason "<why>"'
    )


def cmd_check(_: argparse.Namespace) -> int:
    lock, tree = load_lock(), scan_tree()
    diff = Diff(lock, tree)
    if diff.violations:
        print("feature guard: existing tests were removed or weakened\n")
        report_violations(diff)
        return 1
    if diff.stale:
        count = len(diff.unlocked) + len(diff.moved) + len(diff.strengthened) + len(diff.reenabled)
        print(f"feature guard: the lock is behind the tests ({count} to record)\n")
        for test_id in diff.unlocked[:20]:
            print(f"  unlocked  {test_id}")
        if len(diff.unlocked) > 20:
            print(f"  ... and {len(diff.unlocked) - 20} more")
        for old, new in diff.moved:
            print(f"  moved     {old} -> {new}")
        for test_id, was, now in diff.strengthened:
            print(f"  grew      {test_id}  ({was} -> {now} assertions)")
        print("\nRecord them, and commit the lock with the change:\n    scripts/feature-guard.py update")
        return 1
    print(f"feature guard: {len(tree)} tests, all accounted for")
    return 0


def cmd_update(_: argparse.Namespace) -> int:
    lock, tree = load_lock(), scan_tree()
    diff = Diff(lock, tree)
    if diff.violations:
        print("feature guard: not updating while existing tests are removed or weakened\n")
        report_violations(diff)
        return 1
    disabled = set(lock["disabled"])
    for old, new in diff.moved:
        del lock["tests"][old]
        if old in disabled:
            disabled.discard(old)
            disabled.add(new)
    for test_id, info in tree.items():
        lock["tests"][test_id] = max(info["assertions"], 0)
        if test_id in diff.unlocked and info["disabled"]:
            disabled.add(test_id)  # arrived disabled; that is its baseline
    for test_id in diff.reenabled:
        disabled.discard(test_id)
    lock["disabled"] = sorted(disabled & set(lock["tests"]))
    save_lock(lock)
    print(
        f"feature guard: locked {len(lock['tests'])} tests "
        f"(+{len(diff.unlocked)} new, {len(diff.moved)} moved, {len(diff.strengthened)} grew)"
    )
    return 0


def cmd_retire(args: argparse.Namespace) -> int:
    reason = args.reason.strip()
    if len(reason) < 12:
        print("feature guard: give a real reason (what went, and who asked)")
        return 1
    lock, tree = load_lock(), scan_tree()
    diff = Diff(lock, tree)
    test_id = args.test_id
    entry = {"test": test_id, "date": datetime.date.today().isoformat(), "reason": reason}

    if test_id in diff.removed:
        entry["change"] = "removed"
        del lock["tests"][test_id]
        lock["disabled"] = [t for t in lock["disabled"] if t != test_id]
    elif any(test_id == t for t, _, _ in diff.weakened) or test_id in diff.disabled:
        changes = []
        for t, was, now in diff.weakened:
            if t == test_id:
                changes.append(f"assertions {was} -> {now}")
        if test_id in diff.disabled:
            changes.append("disabled")
            lock["disabled"].append(test_id)
        entry["change"] = ", ".join(changes)
        # A weakened test that also moved is still locked under its old id.
        for old, new in diff.moved:
            if new == test_id:
                del lock["tests"][old]
        lock["tests"][test_id] = tree[test_id]["assertions"]
    else:
        print(f"feature guard: {test_id} is not removed, weakened or disabled; nothing to retire")
        return 1

    lock["retired"].append(entry)
    save_lock(lock)
    print(f"feature guard: retired {test_id} ({entry['change']})")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    for test_id, info in sorted(scan_tree().items()):
        if args.substring.lower() in test_id.lower():
            flag = "  [disabled]" if info["disabled"] else ""
            print(f"{info['assertions']:3}  {test_id}{flag}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="fail if a locked test is gone, weaker or disabled").set_defaults(run=cmd_check)
    sub.add_parser("update", help="record new, moved and strengthened tests").set_defaults(run=cmd_update)
    retire = sub.add_parser("retire", help="accept one removed or weakened test, with a reason")
    retire.add_argument("test_id")
    retire.add_argument("--reason", required=True)
    retire.set_defaults(run=cmd_retire)
    listing = sub.add_parser("list", help="print test ids, to find the tests around a feature")
    listing.add_argument("substring", nargs="?", default="")
    listing.set_defaults(run=cmd_list)
    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main())
