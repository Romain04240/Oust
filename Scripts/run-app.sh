#!/bin/bash
#
# Construit et lance Oust! : toujours la même copie, toujours signée.
#
# L'Accès complet au disque est accordé à une signature, pas à un nom. Chaque
# copie construite avec CODE_SIGNING_ALLOWED=NO est signée « ad hoc », avec une
# signature à elle, et en lancer une faisait perdre l'accès aux autres. Le
# 18/10/2026, sept copies de fr.meaillais.oust étaient inscrites auprès de
# LaunchServices, six ad hoc, et Romain devait réactiver l'accès sans cesse.
#
#   Scripts/run-app.sh            dans l'apparence du système
#   Scripts/run-app.sh --light    en apparence claire forcée (captures)

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

bundle_id="fr.meaillais.oust"
derived="$root/build/DerivedData"
app="$derived/Build/Products/Debug/Oust.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

launch_args=()
case "${1:-}" in
    "") ;;
    --light) launch_args=(--args -NSRequiresAquaSystemAppearance YES) ;;
    *) echo "usage : Scripts/run-app.sh [--light]" >&2; exit 2 ;;
esac

xcodegen generate --quiet
if ! build=$(xcodebuild build -project Oust.xcodeproj -scheme Oust -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$derived" 2>&1); then
    grep -E "error:" <<< "$build" | sort -u | head -20
    echo "** APPLICATION EN ÉCHEC **"
    exit 1
fi

# Une copie signée par un certificat garde son exigence d'une compilation à
# l'autre (identifiant + certificat) ; une copie ad hoc, non.
if ! codesign -d -r- "$app" 2>&1 | grep -q "certificate leaf"; then
    echo "** Copie signée ad hoc : l'Accès complet au disque ne tiendrait pas. **"
    exit 1
fi

# Les autres copies sont désinscrites, sans être effacées : le Dock, Spotlight
# et `open -b` ne retombent plus sur l'une d'elles.
"$lsregister" -dump 2>/dev/null \
    | awk -v id="$bundle_id" '
        /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
        /^identifier:/ && $2 == id && path != "" { print path; path = "" }' \
    | sort -u \
    | while IFS= read -r copy; do
        [[ "$copy" == "$app" ]] || "$lsregister" -u "$copy" 2>/dev/null || true
    done
"$lsregister" -f "$app"

# Une seule instance à la fois : l'ancienne compilation est quittée.
if pgrep -f "/Oust.app/Contents/MacOS/Oust" > /dev/null; then
    pkill -f "/Oust.app/Contents/MacOS/Oust" || true
    sleep 1
fi
open -n "$app" ${launch_args[@]+"${launch_args[@]}"}
echo "Oust! lancé : $app"
