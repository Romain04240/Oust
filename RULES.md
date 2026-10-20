# Règles du projet Oust!

**Oust!** fait le vide sur le disque d'un Mac, en toute sécurité. L'application
**supprime des fichiers** : la sûreté passe avant tout le reste, y compris la
vitesse et l'élégance. Le code cite ces règles par leur numéro
(« RULES.md, règle 4 »).

## Règles non négociables

### Sûreté des données

1. **Rien n'est supprimé sans passer par `OustClean`.** Aucun `removeItem`,
   `removefile`, `trashItem` ni commande destructive ailleurs dans le code.
2. **Toute suppression est revalidée juste avant d'agir** : l'élément existe encore,
   n'a pas changé depuis l'analyse, aucun processus n'y travaille, le chemin passe
   la garde (`PathGuard`).
3. **En cas de doute, l'élément est protégé.** Un état git illisible, un processus
   inconnu, une erreur de lecture : on ne propose pas, on explique pourquoi.
4. **Jamais de présélection pour ce qui n'est pas régénérable.** Modèles IA,
   historiques, téléchargements, doublons « similaires » : l'utilisateur coche.
5. **Le contenu personnel va à la corbeille** et entre au journal avec son chemin
   d'origine. Seul le régénérable est supprimé immédiatement (SPEC §6).
   Une seule exception, voulue par Romain (18/10/2026) : formater un disque
   externe, par `DiskEraser`, jamais un disque interne ni celui de démarrage,
   nom du disque tapé, rien d'ouvert dessus.
6. **Une commande d'outil plutôt qu'un `rm`** quand l'outil existe : `git worktree
   remove`, `xcrun simctl`, `tmutil`.
7. **Aucun verbe « exécuter cette commande » en root.** L'élévation se limite à des
   commandes fixes aux arguments validés (snapshots), puis au démon de la phase 3.
8. **Les tests n'écrivent que dans leurs propres dossiers temporaires.**
   `Scripts/lint-tests.sh` le vérifie.

### Vérité des chiffres

9. **On n'annonce que ce qui sera vraiment libéré** : taille allouée et non
   logique, liens physiques et clones comptés une fois, part retenue par les
   snapshots signalée. Un chiffre flatteur et faux est pire que pas de chiffre.
10. **Le parcours ne quitte jamais le volume analysé** : points de montage, firmlinks
    et table `getfsstat`. DeviceFS a déjà fait croire à 142 Go qui n'existaient pas.

### Confidentialité

11. **Analyse et conseils hors ligne, aucune télémétrie, aucun analytics.**
    Exception demandée par Romain le 20/10/2026 : recherche manuelle des versions
    et téléchargement de l'installation depuis `Romain04240/Oust` sur GitHub.
    Aucun appel automatique au lancement ; aucun inventaire de fichiers envoyé.
    Les installations téléchargées sont vérifiées (Developer ID de l'équipe)
    avant ouverture, puis remplacées par l'utilisateur dans le Finder.
12. **Aucune dépendance tierce** sans validation explicite préalable.

### Interface

13. **Aucune chaîne codée en dur.** Toute chaîne visible passe par le catalogue de
    `OustLocalization` : `Text("clé", bundle: .oust)` ou
    `String(localized: "clé", bundle: .oust)`.
14. **`accessibilityReduceMotion` respecté** sur chaque animation, y compris la
    pulsation de nettoyage.
15. **Chiffres tabulaires** partout où une taille s'affiche dans une colonne.

## Conventions de code

- Swift 6, concurrence stricte, `@MainActor` sur l'interface, SwiftUI uniquement
  (AppKit seulement là où SwiftUI ne sait pas faire).
- **Identifiants en anglais, commentaires et prose en français.** Un commentaire
  dit *pourquoi*, pas *quoi* ; s'il naît d'un incident, il le raconte.
- Tests en Swift Testing (`import Testing`), jamais XCTest. Lancer
  `Scripts/run-tests.sh` : depuis Xcode 27, un `swift test` nu ne lance que la
  première cible de test.
- Avant tout commit : `Scripts/verify.sh` doit finir sur « Tout est vert ».
- **Lancer l'app : `Scripts/run-app.sh`** (`--light` pour l'apparence claire),
  jamais une copie construite avec `CODE_SIGNING_ALLOWED=NO`. L'Accès complet au
  disque tient à la signature : chaque copie « ad hoc » de `fr.meaillais.oust`
  lancée le fait perdre, et Romain doit le réactiver (18/10/2026).
  Depuis le 20/10/2026, Debug et Release lancés utilisent tous deux Developer ID :
  Apple Development possède une autre exigence désignée et ne doit plus être
  alterné avec la distribution sous le même bundle ID. `Scripts/check-signing.sh`
  vérifie l'identité et la compatibilité avec l'app installée avant lancement.
