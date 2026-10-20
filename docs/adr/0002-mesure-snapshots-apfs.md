# Mesurer les snapshots APFS sans compter leurs blocs plusieurs fois

Décision du 20/10/2026, suite aux essais demandés par Romain.

`tmutil listlocalsnapshots` et `diskutil apfs listSnapshots -plist` ne donnent
pas de tailles. Un parcours de dossier ne mesure pas les blocs uniquement
retenus par un snapshot : APFS partage les données entre vues du système.

La lecture native `fs_snapshot_list` fournit `ATTR_CMNEXT_PRIVATESIZE`, comme
l'utilise Utilitaire de disque. `OustAPFS` ne fait que demander ces attributs,
et Swift vérifie chaque longueur, déplacement, attribut retourné et taille.
Une mesure absente reste `nil`, distincte de zéro. Aucun snapshot n'est monté
ni modifié. Le petit pont C évite de déclarer une fonction système Swift avec
une convention d'appel devinée.

La somme des tailles privées est un minimum : des blocs restent partagés entre
plusieurs snapshots. Pour le total retenu, Utilitaire de disque utilise
`fsctl` avec la requête `0xc0184a13` et trois entiers 64 bits : premier XID,
dernier XID, octets retournés. Cette lecture a été vérifiée localement sur
macOS 27 en comparant une plage d'un seul XID à sa taille privée native.

Cette seconde interface n'est pas documentée par Apple. Elle est donc isolée,
limitée à macOS 26/27, au volume de données fixe, à des XID réellement listés,
et à un résultat positif inférieur à la capacité du volume. Chaque snapshot
non-Time-Machine interrompt une plage : le total ne doit pas inclure les
snapshots système ou d'autres applications. Une erreur rend le total
indisponible sans bloquer la suppression ni inventer une estimation. Au-delà
de macOS 27, les tailles privées restent disponibles, le total par plages est
désactivé jusqu'à validation. Aucun appel de mutation n'existe dans ce module.

Les mesures sont sérialisées hors du fil principal. Les listes légères avant
et après suppression continuent à passer par tmutil. Le bilan suit la
variation réelle du libre immédiat, indépendamment des prévisions.
