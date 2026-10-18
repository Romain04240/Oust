#!/bin/zsh
# Génère Design/AppIcon.appiconset depuis le SVG maître, puis vérifie le résultat.
#
# - oust-icon.svg        : maître, utilisé de 64 à 1024 px
# - oust-icon-petit.svg  : version simplifiée pour 16 et 32 px (si elle existe)
#
# Outils : swiftc (rendu WebKit, voir rendu-svg.swift), sips et python3 du système.
# Usage : Design/outils/generer-appiconset.sh

set -euo pipefail

OUTILS=${0:A:h}
DESIGN=${OUTILS:h}
SET="$DESIGN/AppIcon.appiconset"
MAITRE="$DESIGN/oust-icon.svg"
PETIT="$DESIGN/oust-icon-petit.svg"
[[ -f $PETIT ]] || PETIT=$MAITRE

BUILD=$(mktemp -d "${TMPDIR:-/tmp}/oust-icone.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT

echo "→ Compilation du moteur de rendu"
swiftc -O "$OUTILS/rendu-svg.swift" -o "$BUILD/rendu-svg" 2>/dev/null

# taille en points, échelle, pixels, source
typeset -a ENTREES=(
  "16 1 16 $PETIT"    "16 2 32 $PETIT"
  "32 1 32 $PETIT"    "32 2 64 $MAITRE"
  "128 1 128 $MAITRE" "128 2 256 $MAITRE"
  "256 1 256 $MAITRE" "256 2 512 $MAITRE"
  "512 1 512 $MAITRE" "512 2 1024 $MAITRE"
)

mkdir -p "$SET"
rm -f "$SET"/*.png(N)
typeset -a JOBS=()
for e in $ENTREES; do
  read -r pts scale px src <<< "$e"
  nom="icon_${pts}x${pts}"; [[ $scale == 2 ]] && nom="${nom}@2x"
  JOBS+=("$src" "$SET/$nom.png" "$px")
done
echo "→ Rendu des ${#ENTREES} tailles"
"$BUILD/rendu-svg" "${JOBS[@]}" > /dev/null
"$BUILD/rendu-svg" "$MAITRE" "$DESIGN/oust-icon-1024.png" 1024 > /dev/null

echo "→ Contents.json"
python3 - "$SET" <<'PY'
import json, sys
from pathlib import Path
entries = []
for pts in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{pts}x{pts}{'@2x' if scale == 2 else ''}.png"
        entries.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pts}x{pts}"})
doc = {"images": entries, "info": {"author": "xcode", "version": 1}}
Path(sys.argv[1], "Contents.json").write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY

echo "→ Vérification"
python3 - "$SET" <<'PY'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
doc = json.loads((root / "Contents.json").read_text())
listed = set()
errors = []
for img in doc["images"]:
    name = img["filename"]
    listed.add(name)
    pts = int(img["size"].split("x")[0])
    expected = pts * int(img["scale"][0])
    path = root / name
    if not path.exists():
        errors.append(f"manquant : {name}")
        continue
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", "-g", "space",
                          str(path)], capture_output=True, text=True, check=True).stdout
    props = dict(line.strip().split(": ", 1) for line in out.splitlines()[1:] if ": " in line)
    w, h = int(props["pixelWidth"]), int(props["pixelHeight"])
    if (w, h) != (expected, expected):
        errors.append(f"{name} : {w}×{h} au lieu de {expected}×{expected}")
    if props.get("space") != "RGB":
        errors.append(f"{name} : espace {props.get('space')}")
    print(f"  {name:<22} {w:>4}×{h:<4} {props.get('space')} alpha={props.get('hasAlpha')}")
extra = {p.name for p in root.iterdir() if p.suffix == ".png"} - listed
errors += [f"fichier non référencé : {n}" for n in sorted(extra)]
if errors:
    print("\n".join("✗ " + e for e in errors))
    sys.exit(1)
print(f"✓ {len(listed)} images, Contents.json cohérent")
PY
