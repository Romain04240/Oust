#!/bin/bash
#
# Échoue quand un test écrit là où vit la personne qui utilise l'application.
#
# Pour une application qui supprime des fichiers, la règle n'a rien de
# théorique : un test de nettoyage pointé par erreur sur un vrai dossier détruit
# de vraies données. Un test n'écrit et ne supprime que dans le dossier
# temporaire qu'il s'est créé.

set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib, re, sys

theirs = [
    (r"\.applicationSupportDirectory", "Application Support est à l'utilisateur"),
    (r"\.documentDirectory", "Documents est à l'utilisateur"),
    (r"\.downloadsDirectory", "Téléchargements est à l'utilisateur"),
    (r"\.desktopDirectory", "le Bureau est à l'utilisateur"),
    (r"\.picturesDirectory", "Images est à l'utilisateur"),
    (r"homeDirectoryForCurrentUser", "le dossier personnel est à l'utilisateur"),
    (r"NSHomeDirectory\(\)", "le dossier personnel est à l'utilisateur"),
    (r"\"~/", "un chemin en ~/ vise le dossier personnel"),
    (r"\"/Users/", "un chemin absolu dans /Users vise un vrai dossier"),
    (r"UserDefaults\.standard", "les préférences de l'utilisateur"),
    (r"UserDefaults\(suiteName", "une suite à soi laisse un fichier dans les préférences"),
]

faulty = []
for path in pathlib.Path("Packages/OustKit/Tests").rglob("*.swift"):
    text = path.read_text(encoding="utf-8")
    code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("//"))
    for pattern, why in theirs:
        if re.search(pattern, code):
            faulty.append(f"{path} — {why}")

if faulty:
    print("Un test touche un emplacement de l'utilisateur :")
    for one in sorted(set(faulty)):
        print(f"  {one}")
    print("\nLui donner un dossier temporaire à lui (TemporaryDirectory), et le retirer après.")
    sys.exit(1)
print("Aucun test ne sort de son dossier temporaire.")
PY
