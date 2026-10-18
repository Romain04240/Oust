#!/bin/bash
#
# Échoue quand un texte visible est codé en dur dans une vue SwiftUI.
#
# Repris de Markio. Dans un paquet, SwiftUI cherche une clé nue dans
# `Bundle.main` — l'application — alors que le catalogue vit dans
# `OustLocalization` : `Text("overview.title")` compilerait et afficherait la clé
# elle-même. Toute chaîne doit donc nommer son bundle (`bundle: .oust`), ou dire
# explicitement qu'elle n'est pas traduisible (`verbatim:`).

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sources=("$root/Packages/OustKit/Sources" "$root/App")

pattern='(^|[^A-Za-z0-9_])(Text|Button|Label|navigationTitle|alert|Toggle|Section|Picker|LabeledContent)\(\s*"[^"]+"'
allowed='bundle:|String\(localized:|verbatim:'

found=0
while IFS= read -r line; do
    content="${line#*:}"
    content="${content#*:}"
    if grep -Eq '^[[:space:]]*(///|//|\*)' <<< "$content"; then
        continue
    fi
    if grep -Eq "$allowed" <<< "$line"; then
        continue
    fi
    echo "$line"
    found=1
done < <(grep -rEn "$pattern" "${sources[@]}" --include="*.swift" 2>/dev/null)

if grep -rEn 'LocalizationValue\("[^"]*\\\(' "${sources[@]}" --include="*.swift" 2>/dev/null; then
    echo
    echo "Une clé interpolée dans LocalizationValue construit un format, pas une clé."
    found=1
fi

if [ "$found" -eq 1 ]; then
    echo
    echo "Chaînes visibles codées en dur : les déplacer dans le catalogue de OustLocalization."
    exit 1
fi
echo "Aucune chaîne visible codée en dur."
