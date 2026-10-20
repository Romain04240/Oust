#!/bin/bash
#
# Tout ce qui doit tenir avant un commit, au même endroit.
#
# Repris de Markio, écrit là-bas après qu'un commit est passé avec un lint en
# échec : les vérifications étaient enchaînées à la main, et un `&&` mal placé
# en a laissé filer une. Un script n'oublie pas.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "▸ Chaînes"
Scripts/lint-strings.sh

echo "▸ Clés"
Scripts/lint-keys.sh

echo "▸ Bancs"
Scripts/lint-tests.sh

# En release aussi : l'ordre de compilation des modules y diffère, et un import
# non déclaré n'est attrapé que là.
echo "▸ Paquet (release)"
if ! release=$(swift build --package-path Packages/OustKit -c release 2>&1); then
    grep -E "error:" <<< "$release" | sort -u | head -20
    echo "** PAQUET EN ÉCHEC (release) **"
    exit 1
fi
echo "Le paquet se construit en release."

echo "▸ Tests"
Scripts/run-tests.sh

echo "▸ Application"
xcodegen generate --quiet
# Signée, comme celle de Scripts/run-app.sh : une copie ad hoc de
# fr.meaillais.oust, si on la lance, fait perdre l'Accès complet au disque
# (18/10/2026). OUST_UNSIGNED=1 pour qui n'a pas le certificat de l'équipe.
signing=()
if [[ "${OUST_UNSIGNED:-}" == 1 ]]; then signing=(CODE_SIGNING_ALLOWED=NO); fi
if ! app=$(xcodebuild build -project Oust.xcodeproj -scheme Oust -destination 'platform=macOS' \
        ${signing[@]+"${signing[@]}"} 2>&1); then
    grep -E "error:" <<< "$app" | sort -u | head -20
    echo "** APPLICATION EN ÉCHEC **"
    exit 1
fi
echo "L'application se construit."
if [[ "${OUST_UNSIGNED:-}" != 1 ]]; then
    signed_app=$(xcodebuild -showBuildSettings -project Oust.xcodeproj -scheme Oust -destination 'platform=macOS' 2>/dev/null \
        | awk '/Build settings for action build and target Oust:/ { app=1; next } /Build settings for action build and target / { app=0 } app && / TARGET_BUILD_DIR = / { sub(/^.* = /, ""); path=$0 } END { if (path != "") print path "/Oust.app" }')
    Scripts/check-signing.sh "$signed_app"
fi

echo
echo "▸ Tout est vert"
