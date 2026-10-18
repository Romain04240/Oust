#!/bin/bash
#
# Échoue quand le code cite une clé absente du catalogue, ou quand une clé du
# catalogue n'a pas de traduction française.
#
# Une clé manquante ne casse rien à la compilation : l'écran affiche
# « cart.review.title » en toutes lettres, et personne ne le voit avant d'avoir
# ouvert la bonne fenêtre dans la bonne langue.

set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, pathlib, re, sys

catalog_path = pathlib.Path("Packages/OustKit/Sources/OustLocalization/Resources/Localizable.xcstrings")
catalog = json.loads(catalog_path.read_text(encoding="utf-8"))["strings"]

used = set()
patterns = [
    re.compile(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"\s*,\s*bundle:\s*\.oust'),
    re.compile(r'localized:\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"'),
    re.compile(r'L10n\.(?:text|string)\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"'),
]
for root in ("Packages/OustKit/Sources", "App"):
    for path in pathlib.Path(root).rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for pattern in patterns:
            for key in pattern.findall(text):
                used.add((key, str(path)))

missing = sorted({(k, p) for k, p in used if k not in catalog})
untranslated = sorted(
    k for k, v in catalog.items()
    if v.get("localizations", {}).get("fr", {}).get("stringUnit", {}).get("state") != "translated"
)

failed = False
if missing:
    failed = True
    print("Clés citées dans le code mais absentes du catalogue :")
    for key, path in missing:
        print(f"  {key}  ({path})")
if untranslated:
    failed = True
    print("Clés sans traduction française :")
    for key in untranslated:
        print(f"  {key}")
if failed:
    sys.exit(1)
print(f"{len(catalog)} clés, toutes présentes et traduites.")
PY
