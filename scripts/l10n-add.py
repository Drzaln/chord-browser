#!/usr/bin/env python3
"""Add Indonesian text to catalog keys: scripts/l10n-add.py translations.json

The JSON maps an English key to its Indonesian text. Run `scripts/l10n.py sync`
first so the keys exist; this refuses a key the catalog does not have.
"""
import json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "ChordApp", "Localizable.xcstrings")
cat = json.load(open(CATALOG))
new = json.load(open(sys.argv[1]))
for key, value in new.items():
    if key not in cat["strings"]:
        sys.exit(f"not in the catalog: {key!r}")
    cat["strings"][key] = {"localizations": {"id": {"stringUnit": {"state": "translated", "value": value}}}}
with open(CATALOG, "w") as f:
    json.dump(cat, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
print(f"translated {len(new)}")
