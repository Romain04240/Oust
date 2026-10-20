#!/bin/bash
# Vérifie l'identité TCC avant tout lancement : la même équipe et la même
# famille de certificat que l'installation distribuée, jamais une signature ad hoc.
set -euo pipefail
app="$1"
reference="${2:-}"
developer_id='anchor apple generic and certificate leaf[subject.OU] = "H3W3XYM2NZ" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
binaries=("$app" "$app/Contents/MacOS/oust-helper" "$app/Contents/MacOS/oust-cli")
# La CLI n'intègre pas d'Info.plist : codesign utilise son nom de fichier,
# même si PRODUCT_BUNDLE_IDENTIFIER est renseigné dans le projet Xcode.
identifiers=("fr.meaillais.oust" "fr.meaillais.oust.helper" "oust-cli")
for index in "${!binaries[@]}"; do
    binary="${binaries[$index]}"
    codesign --verify --deep --strict -R "=$developer_id and identifier \"${identifiers[$index]}\"" "$binary"
    # Xcode a conservé une ancienne copie embarquée du démon alors que le
    # produit source était corrigé : vérifier le paquet réellement lancé.
    entitlements=$(codesign -d --entitlements - --xml "$binary" 2>/dev/null)
    if [[ -n "$entitlements" ]]; then
        plutil -lint -s - <<< "$entitlements"
        if [[ "$entitlements" == *'get-task-allow'* ]]; then
            echo "** Autorisation de débogage inattendue : $binary. Reconstruisez dans un dossier DerivedData neuf. **" >&2
            exit 1
        fi
    fi
done
if [[ -n "$reference" && -d "$reference" ]]; then
    previous=$(codesign -d -r- "$reference" 2>&1 | sed -n 's/^designated => //p')
    if [[ -z "$previous" ]] || ! codesign --verify -R "=$previous" "$app"; then
        echo "** Identité incompatible avec $reference : lancement refusé pour préserver les autorisations. **"
        exit 1
    fi
fi
echo "Identité Developer ID vérifiée ; compatible avec la copie distribuée."
