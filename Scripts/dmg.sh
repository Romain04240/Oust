#!/bin/zsh
# Fabrique l'image disque de distribution, signée Developer ID, puis la fait
# notariser si un profil de notarisation est enregistré dans le trousseau.
#
# Le raccourci vers /Applications compte : sans lui, une bonne moitié des gens
# lance l'app depuis l'image montée, et s'étonne ensuite qu'elle disparaisse.
#
#     Scripts/release.sh && Scripts/dmg.sh [profil-de-notarisation]
set -e
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Daniel-Romain BLANC (H3W3XYM2NZ)"
PROFILE="${1:-oust}"
APP="release/Build/Products/Release/Oust.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
DMG="dist/Oust-$VERSION.dmg"

test -d "$APP" || { echo "✘ pas de Release : lancez d'abord Scripts/release.sh"; exit 1; }

make_dmg() {
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE" dist
    ditto "$APP" "$STAGE/Oust.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "Oust!" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
}

echo "▸ image ($VERSION)"
make_dmg

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "▸ notarisation (profil « $PROFILE »)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    # Le billet est agrafé à l'app avant de refaire l'image : copiée hors de
    # l'image et lancée hors ligne, elle n'a pas à interroger Apple.
    xcrun stapler staple "$APP"
    make_dmg
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
else
    echo "▸ pas de profil de notarisation « $PROFILE » : image signée, non notarisée."
    echo "    xcrun notarytool store-credentials $PROFILE --apple-id VOTRE_IDENTIFIANT --team-id H3W3XYM2NZ"
    echo "    puis relancez Scripts/dmg.sh"
fi

rm -rf "$STAGE"
echo "  ✔ $DMG ($(du -h "$DMG" | cut -f1))"
