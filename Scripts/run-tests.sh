#!/bin/bash
# Exécute la totalité des tests, cible par cible.
#
# Depuis Xcode 27, `swift test` sans argument ne lance que la PREMIÈRE cible de
# test du paquet, sans le moindre avertissement (constaté sur Zesam : 61 tests au
# lieu de 409). Un banc d'essai qui rétrécit en silence est pire que pas de banc
# d'essai du tout, parce qu'on continue de lui faire confiance.
#
#     Scripts/run-tests.sh            toutes les cibles
#     Scripts/run-tests.sh OustScan   les cibles dont le nom contient « OustScan »
#
# Rend 0 si tout passe, 1 sinon, et nomme les cibles en échec.

set -uo pipefail
cd "$(dirname "$0")/../Packages/OustKit" || exit 1

CIBLES=$(swift package describe --type json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(t["name"] for t in d["targets"] if t["type"]=="test"))')

if [ -z "$CIBLES" ]; then
    echo "Aucune cible de test trouvée."
    exit 1
fi

if [ $# -gt 0 ]; then
    CIBLES=$(echo "$CIBLES" | grep -- "$1" || true)
fi

total=0
echecs=()

for cible in $CIBLES; do
    sortie=$(swift test --filter "^${cible}\." 2>&1)
    ligne=$(echo "$sortie" | grep -E 'Test run with' | tail -1)
    nombre=$(echo "$ligne" | grep -oE '[0-9]+ tests?' | head -1 | grep -oE '[0-9]+')
    if echo "$ligne" | grep -q 'passed'; then
        printf '  %-24s %s tests\n' "$cible" "${nombre:-0}"
        total=$((total + ${nombre:-0}))
    else
        printf '  %-24s ÉCHEC\n' "$cible"
        echo "$sortie" | grep -E '✘|error:' | head -15
        echecs+=("$cible")
    fi
done

# The private relay's transport and callback regressions exercise its C code
# directly with fake API responses, outside SwiftPM's Swift test targets.
if [ $# -eq 0 ] || [[ "OustDeviceRelayTests" == *"${1:-}"* ]]; then
    if ! ../../Scripts/test-device-relay.sh; then
        echecs+=("OustDeviceRelayTests")
    fi
fi

echo
if [ ${#echecs[@]} -eq 0 ]; then
    echo "$total tests, tous passés."
else
    echo "Cibles en échec : ${echecs[*]}"
    exit 1
fi
