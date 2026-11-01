#!/usr/bin/env python3
"""Fails when Swift code names an API that only the macOS 27 SDK declares (4b6).

Release CI builds on a macos-26 runner against the macOS 26 SDK, while dev
Macs build with Xcode 27. `#available` only guards at run time: a 27-only name
behind `if #available(macOS 27, *)` builds here and breaks the release build.
Such an API has to be reached by name instead (KVC, NSClassFromString,
perform), as WebKitEngine.applyReferrer does — and a name inside a string
literal is exactly what this check leaves alone.

It reads the frameworks the sources import from the installed SDK, collects
every declaration marked API_AVAILABLE(macos(27...)) (ObjC headers) or
@available(macOS 27...) (Swift interfaces), and looks for those names in the
code with comments and string literals removed. A name that an older
declaration also uses (an overload) is not flagged: the compiler on the
macos-26 runner is the check for those (.github/workflows/ci.yml).

usage: check-sdk-availability.py [paths...]   (default: Packages/Sources ChordApp)
"""

import os
import re
import subprocess
import sys

NEW = re.compile(r"macos\(\s*27")
SWIFT_NEW = re.compile(r"@available\([^)]*macOS 27")

# Too generic to mean anything on their own: an older API almost always has
# the same base name.
GENERIC = {"init", "load", "get", "set", "add", "remove", "update", "reset",
           "start", "stop", "close", "open", "show", "hide", "run", "copy"}


def sdk_path():
    return subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()


def swift_base(name):
    """`getCookies(for:completionHandler:)` -> `getCookies`; `A.B` -> `B`."""
    name = name.split("(")[0].strip()
    return name.split(".")[-1]


def objc_names(line):
    """Swift-visible names a one-line ObjC declaration introduces."""
    names = set()
    for macro in ("NS_SWIFT_NAME", "WK_SWIFT_ASYNC_NAME"):
        for m in re.finditer(macro + r"\(([^)]*\)?)\)", line):
            names.add(swift_base(m.group(1)))
    prop = re.search(r"@property\s*(\([^)]*\))?[^;]*?\b(\w+)\s*(API_|NS_|WK_|;)", line)
    if prop:
        names.add(prop.group(2))
    method = re.match(r"\s*[-+]\s*\([^)]*\)\s*(\w+)", line)
    if method and not names:
        first = method.group(1)
        names.add(first)
        # Swift drops a trailing "With…"/"For…" clause: loadURL -> load,
        # removeBufferWithName -> removeBuffer.
        base = re.sub(r"(With|For|URL|Request)\w*$", "", first)
        if base and base != first:
            names.add(base)
    return names


def is_attribute_line(stripped):
    """`WK_EXTERN API_AVAILABLE(macos(27.0))`, `NS_SWIFT_SENDABLE`: macros only."""
    if not stripped or stripped.endswith(";") or stripped[0] in "@-+/*#":
        return False
    bare = re.sub(r"\([^()]*(\([^()]*\)[^()]*)*\)", "", stripped)
    return all(re.fullmatch(r"[A-Z][A-Z0-9_]*", token) for token in bare.split())


def scan_headers(headers_dir, new, old):
    for fname in sorted(os.listdir(headers_dir)):
        if not fname.endswith(".h"):
            continue
        with open(os.path.join(headers_dir, fname), errors="replace") as f:
            lines = f.read().splitlines()
        # Attribute lines (NS_SWIFT_NAME, API_AVAILABLE…) that stand above an
        # @interface or @protocol rather than ending in a declaration.
        attributes = []
        for line in lines:
            stripped = line.strip()
            cls = re.match(r"@(?:interface|protocol)\s+(\w+)\b(?!\s*\()", stripped)
            if cls:
                block = " ".join(attributes + [line])
                target = new if NEW.search(block) else old
                target.add(cls.group(1))
                for swift_name in re.findall(r"NS_SWIFT_NAME\(([\w.]+)\)", block):
                    target.add(swift_name)
                attributes = []
                continue
            if is_attribute_line(stripped):
                attributes.append(stripped)
                continue
            attributes = []
            (new if NEW.search(line) else old).update(objc_names(line))


def scan_swiftinterface(path, new, old):
    with open(path, errors="replace") as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        decl = re.search(r"\b(?:func|var|let|class|struct|enum|protocol|typealias|case|init)\s+(\w+)", line)
        if not decl:
            continue
        attrs = " ".join(lines[max(0, i - 3):i + 1])
        (new if SWIFT_NEW.search(attrs) else old).add(decl.group(1))


def strip_swift(source):
    """Removes comments and string literals, keeping line breaks."""
    out, i, n = [], 0, len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            i = n if j < 0 else j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * source.count("\n", i, j))
            i = j
        elif source.startswith('"""', i):
            j = source.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append('""' + "\n" * source.count("\n", i, j))
            i = j
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] not in '"\n':
                j += 2 if source[j] == "\\" else 1
            out.append('""')
            i = j + 1
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def main():
    roots = sys.argv[1:] or ["Packages/Sources", "ChordApp"]
    files = []
    for root in roots:
        if os.path.isfile(root):
            files.append(root)
            continue
        for dirpath, _, names in os.walk(root):
            files += [os.path.join(dirpath, n) for n in names if n.endswith(".swift")]

    imports = set()
    sources = {}
    for path in files:
        with open(path, errors="replace") as f:
            text = f.read()
        imports.update(re.findall(r"^\s*(?:@\w+\s+)*import\s+(\w+)", text, re.M))
        sources[path] = strip_swift(text)

    sdk = sdk_path()
    new, old = set(), set()
    for module in sorted(imports):
        framework = os.path.join(sdk, "System/Library/Frameworks", module + ".framework")
        headers = os.path.join(framework, "Headers")
        if os.path.isdir(headers):
            scan_headers(headers, new, old)
        modules = os.path.join(framework, "Modules", module + ".swiftmodule")
        if os.path.isdir(modules):
            for name in os.listdir(modules):
                if name.endswith(".swiftinterface") and "arm64" in name and "private" not in name:
                    scan_swiftinterface(os.path.join(modules, name), new, old)
                    break

    flagged = {n for n in new if len(n) > 3 and n not in GENERIC and n not in old}
    if not flagged:
        print("check-sdk-availability: found no macOS 27-only declarations to check")
        return 0
    pattern = re.compile(r"(?<![\w$])(" + "|".join(sorted(map(re.escape, flagged), key=len, reverse=True)) + r")(?![\w$])")
    problems = []
    for path, text in sorted(sources.items()):
        for number, line in enumerate(text.splitlines(), 1):
            for m in pattern.finditer(line):
                problems.append(f"{path}:{number}: '{m.group(1)}' is only in the macOS 27 SDK")
    if problems:
        print("\n".join(problems))
        print(
            "\nThe release runner builds against the macOS 26 SDK, where these names do not exist.\n"
            "Reach them by name instead (setValue(_:forKey:), NSClassFromString, perform), as\n"
            "WebKitEngine.applyReferrer does.",
            file=sys.stderr,
        )
        return 1
    print(f"check-sdk-availability: OK ({len(flagged)} macOS 27-only names, {len(sources)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
