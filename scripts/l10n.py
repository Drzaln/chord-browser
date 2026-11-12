#!/usr/bin/env python3
"""gn0.7: Chord's string catalog, kept honest.

    scripts/l10n.py check     fail if a UI string has no catalog entry, an
                              entry has no Indonesian text, or an entry is stale
    scripts/l10n.py list      print every key found in the sources
    scripts/l10n.py sync      add missing keys (untranslated) and drop stale ones

Why a script: the catalog lives in the app bundle (ChordApp/Localizable.xcstrings)
because SwiftUI resolves `Text("…")`, `Button("…")` and `String(localized:)` in
Bundle.main, including from the ChordUI package. Xcode only extracts strings
from the target's own sources, so nothing would notice a new string in the
package. This does.

What counts as a UI string: a string literal passed where SwiftUI takes a
LocalizedStringKey (the CALLS and MODIFIERS below), either literal of a
`cond ? "a" : "b"` inside one, and `String(localized: "…")`. An interpolation
`\\(x)` becomes a placeholder; the catalog key must use %@ or %lld there.
"""
import glob, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "ChordApp", "Localizable.xcstrings")
SOURCES = ["Packages/Sources/ChordUI/**/*.swift", "Packages/Sources/ChordStore/**/*.swift",
           "Packages/Sources/ChordCore/ChromiumPasswordImport.swift",
           "Packages/Sources/ChordEngine/ErrorPage.swift",
           "ChordApp/*.swift"]
LANG = "id"

CALLS = ("Text|Button|Toggle|Label|TextField|SecureField|Picker|Section|Menu|Link|"
         "LabeledContent|DisclosureGroup|GroupBox|Stepper|DatePicker|ColorPicker|ProgressView")
MODIFIERS = ("help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle|"
             "alert|confirmationDialog")
# Literals that are not prose: placeholders showing a format, version tags.
IGNORE = {".sidebar", "v\\(version)", "example.com", "https://example.com",
          "https://example.com/", "https://…", "⌘F", "⌘O"}
# Interpolations that are integers, so SwiftUI formats them as %lld. Everything
# else is %@. Matched against the expression inside \( … ).
INT_EXPR = re.compile(
    r"(?:\.count|Count|Added|Created|Stripped|Depth|\.imported|\.failed|UsernameOnly"
    r"|^count|^position|^minutes|\.count - \d+)$")

OPENER = re.compile(
    r"(?:\b(?:%s)\(\s*|\.(?:%s)\(\s*|\.accessibilityAction\(named:\s*|String\(localized:\s*)"
    % (CALLS, MODIFIERS))

def read_literal(src, i):
    """Parse the Swift string literal starting at src[i] == '"'.

    Returns (parts, end) where parts alternates text and interpolation
    expressions: [text, expr, text, expr, text]. Handles \\( … ) with nested
    parentheses and nested string literals, and triple-quoted literals with
    backslash line continuations.
    """
    multi = src.startswith('"""', i)
    j = i + (3 if multi else 1)
    if multi:
        j = src.index("\n", j) + 1
    text, parts = "", []
    while j < len(src):
        if multi and src.startswith('"""', j):
            j += 3; break
        c = src[j]
        if not multi and c == '"':
            j += 1; break
        if not multi and c == "\n":
            return None, j
        if c == "\\":
            n = src[j + 1]
            if n == "(":
                depth, k = 1, j + 2
                while depth:
                    ch = src[k]
                    if ch == '"':
                        _, k = read_literal(src, k)
                        continue
                    depth += ch == "("
                    depth -= ch == ")"
                    k += 1
                parts += [text, src[j + 2:k - 1]]; text = ""; j = k
                continue
            if multi and n == "\n":
                j += 2
                while src[j] in " \t":
                    j += 1
                continue
            text += {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, n)
            j += 2
            continue
        text += c; j += 1
    parts.append(text)
    if multi:
        # strip the common indentation and the trailing newline
        joined = "\x00".join(parts[0::2])
        lines = joined.split("\n")
        if lines and not lines[-1].strip("\x00 \t"):
            lines = lines[:-1]
        indent = min((len(l) - len(l.lstrip(" ")) for l in lines if l.strip()), default=0)
        texts = "\n".join(l[indent:] for l in lines).split("\x00")
        parts[0::2] = texts
    return parts, j

def key_for(parts):
    key = parts[0]
    for expr, text in zip(parts[1::2], parts[2::2]):
        key += ("%lld" if INT_EXPR.search(expr.strip()) else "%@") + text
    return key

def source_form(parts):
    out = parts[0]
    for expr, text in zip(parts[1::2], parts[2::2]):
        out += "\\(" + expr + ")" + text
    return out

def is_prose(parts):
    return bool(re.search(r"[A-Za-z]", "".join(parts[0::2])))

def literals_after(src, i):
    """The literal at i, or both arms of `cond ? "a" : "b"` starting near i."""
    out = []
    if src[i] == '"':
        parts, _ = read_literal(src, i)
        if parts: out.append(parts)
        return out
    # a ternary: scan to the matching ')' of the call, at depth 0, for `? "…" : "…"`
    depth, j, limit = 0, i, min(len(src), i + 400)
    while j < limit:
        c = src[j]
        if c == '"':
            parts, end = read_literal(src, j)
            before = src[i:j].rstrip()
            if parts and depth == 0 and before.endswith(("?", ":")):
                out.append(parts)
            j = end
            continue
        if c in "([{": depth += 1
        if c in ")]}":
            if depth == 0: break
            depth -= 1
        if c == "," and depth == 0: break
        j += 1
    return out if len(out) == 2 else []

def scan():
    found = {}  # key -> (where, source form)
    def add(parts, where):
        if not is_prose(parts) or source_form(parts) in IGNORE: return
        found.setdefault(key_for(parts), (where, source_form(parts)))
    for pattern in SOURCES:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern), recursive=True)):
            src = open(path).read()
            rel = os.path.relpath(path, ROOT)
            for m in OPENER.finditer(src):
                for parts in literals_after(src, m.end()):
                    add(parts, rel)
            # Helper views that take a LocalizedStringKey by label
            # (WelcomeSheet.step, .tip): `title: "…"`, `detail: … "…"`.
            if rel.endswith("WelcomeSheet.swift"):
                for m in re.finditer(r'\b(?:title|detail): |tip\("[^"]*", ', src):
                    for parts in literals_after(src, m.end()):
                        add(parts, rel)
            # Settings rows and section names are data, localized where they
            # are built (SettingsCatalog.swift).
            if rel.endswith("SettingsCatalog.swift"):
                for m in re.finditer(r'\b(?:title|blurb): (?=")', src):
                    parts, _ = read_literal(src, m.end())
                    add(parts, rel)
                block = src[src.index("var englishTitle"):src.index("var systemImage")]
                for m in re.finditer(r'case \.\w+: (?=")', block):
                    parts, _ = read_literal(block, m.end())
                    add(parts, rel)
    return found

def load():
    if not os.path.exists(CATALOG):
        return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    return json.load(open(CATALOG))

def save(cat):
    with open(CATALOG, "w") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")

def translation(entry):
    try:
        return entry["localizations"][LANG]["stringUnit"]["value"]
    except (KeyError, TypeError):
        return None

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    found = scan()
    cat = load()
    strings = cat["strings"]
    missing = [k for k in found if k not in strings]
    stale = [k for k in strings if k not in found]
    untranslated = [k for k in found if k in strings and not translation(strings[k])]
    if cmd == "list":
        for key, (where, _) in sorted(found.items()):
            print(f"{where}\t{key}")
        return 0
    if cmd == "sync":
        for k in missing:
            strings[k] = {}
        for k in stale:
            del strings[k]
        save(cat)
        print(f"added {len(missing)}, removed {len(stale)}, total {len(strings)}")
        return 0
    ok = True
    for k in missing:
        ok = False; print(f"not in the catalog: {found[k][0]}: {k!r}")
    for k in untranslated:
        ok = False; print(f"no {LANG} translation: {k!r} ({found[k][0]})")
    for k in stale:
        ok = False; print(f"stale catalog entry (no longer in the sources): {k!r}")
    if not ok:
        print("\nl10n check failed: add the strings to ChordApp/Localizable.xcstrings "
              "(scripts/l10n.py sync, then translate).", file=sys.stderr)
        return 1
    print(f"l10n OK: {len(found)} strings, all with {LANG}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
