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
built_app="$derived/Build/Products/Debug/Oust.app"
app="/Applications/Oust.app"
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

# Un certificat seul ne suffit pas : Apple Development et Developer ID ont
# des exigences désignées différentes. Ne plus lancer une copie qui invalide
# l'identité déjà autorisée sous le même bundle ID.
Scripts/check-signing.sh "$built_app" "$app"

# Un service SMAppService doit retrouver son programme dans le même paquet,
# même quand Xcode recrée DerivedData. La copie lancée reste donc Applications.
# L'ancienne installation est déplacée dans build/ : elle reste récupérable.
if [[ ! -w /Applications || -L "$app" ]]; then
    echo "Impossible de remplacer la copie stable /Applications/Oust.app sans changer ses permissions." >&2
    exit 1
fi
staging=$(mktemp -d "$root/build/LocalInstall.XXXXXX")
if [[ "$(stat -f '%d' "$staging")" != "$(stat -f '%d' /Applications)" ]] \
        || [[ -e "$app" && "$(stat -f '%d' "$app")" != "$(stat -f '%d' /Applications)" ]]; then
    echo "Le dossier de construction et Applications doivent être sur le même volume pour un remplacement atomique." >&2
    exit 1
fi
ditto "$built_app" "$staging/Oust.app"
Scripts/check-signing.sh "$staging/Oust.app" "$app"

# Rien n'a encore été remplacé tant que la nouvelle copie n'est pas vérifiée.
if pgrep -f "/Oust.app/Contents/MacOS/Oust" > /dev/null; then
    pkill -f "/Oust.app/Contents/MacOS/Oust" || true
    sleep 1
fi
previous=""
if [[ -e "$app" ]]; then
    previous=$(mktemp -d "$root/build/PreviousInstalledApp.XXXXXX")
    mv "$app" "$previous/Oust.app"
fi
if ! mv "$staging/Oust.app" "$app"; then
    if [[ -n "$previous" ]]; then mv "$previous/Oust.app" "$app"; fi
    echo "Installation interrompue ; la copie précédente a été conservée." >&2
    exit 1
fi

# Les anciennes copies d'identité incompatible sont désinscrites, sans être
# effacées. Les installations Developer ID gardent leur enregistrement.
"$lsregister" -dump 2>/dev/null \
    | awk -v id="$bundle_id" '
        /^path:/ { sub(/^path: +/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
        /^identifier:/ && $2 == id && path != "" { print path; path = "" }' \
    | sort -u \
    | while IFS= read -r copy; do
        if [[ "$copy" != "$app" ]] && ! codesign --verify -R '=anchor apple generic and certificate leaf[subject.OU] = "H3W3XYM2NZ" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$copy" >/dev/null 2>&1; then
            "$lsregister" -u "$copy" 2>/dev/null || true
        fi
    done
"$lsregister" -f "$app"
"$lsregister" -u "$built_app" 2>/dev/null || true

open -n "$app" ${launch_args[@]+"${launch_args[@]}"}
echo "Oust! lancé : $app"
