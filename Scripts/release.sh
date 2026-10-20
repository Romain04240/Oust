#!/bin/zsh
# Construit Oust! en Release, signé Developer ID, prêt à empaqueter.
#
# La signature automatique choisit « Apple Development » : avec elle,
# SMAppService refuse d'enregistrer le démon privilégié, et Gatekeeper refuse
# l'app sur un autre Mac. Seul un certificat Developer ID Application convient à
# une app distribuée hors Mac App Store.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Daniel-Romain BLANC (H3W3XYM2NZ)"
DERIVED="release"
APP="$DERIVED/Build/Products/Release/Oust.app"

echo "▸ projet"
xcodegen generate --quiet

echo "▸ compilation Release, signature Developer ID"
rm -rf "$DERIVED"
xcodebuild -project Oust.xcodeproj -scheme Oust -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    DEVELOPMENT_TEAM=H3W3XYM2NZ \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build 2>&1 | tail -2

echo "▸ vérification"
# L'autorisation de débogage fait rejeter l'archive par le service de
# notarisation, et l'erreur n'arrive qu'après plusieurs minutes d'attente.
binaries=("$APP" "$APP/Contents/MacOS/oust-cli")
helper=$(find "$APP/Contents" -name oust-helper -type f | head -1)
[[ -n "$helper" ]] && binaries+=("$helper")
for binary in "${binaries[@]}"; do
    if codesign -d --entitlements - --xml "$binary" 2>/dev/null \
        | plutil -convert xml1 -o - - 2>/dev/null | grep -q "get-task-allow"; then
        echo "  ✘ $(basename "$binary") demande get-task-allow : la notarisation refusera."
        exit 1
    fi
    authority=$(codesign -dv --verbose=2 "$binary" 2>&1 | grep '^Authority=' | head -1)
    [[ "$authority" == "Authority=Developer ID Application"* ]] \
        || { echo "  ✘ $(basename "$binary") : $authority"; exit 1; }
done
codesign --verify --deep --strict "$APP"
echo "  ✔ signé Developer ID, aucune autorisation de débogage"
echo "  ✔ $APP"
