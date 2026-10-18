# SPEC — Oust!

- **Nom** : Oust! (technique : `Oust`)
- **Plateforme** : macOS 26
- **Langage** : Swift 6, SwiftUI
- **Distribution** : Developer ID, hors App Store, gratuite (open source envisagé)
- **Statut** : v0.1 en construction (octobre 2026)

---

## 1. Périmètre

### 1.1 Ce qu'Oust! fait

Montrer où est passé l'espace disque, expliquer chaque élément, laisser choisir,
puis faire le vide proprement, en direct et avec un historique.

### 1.2 Ce qu'Oust! ne fait pas

Ni antivirus, ni « optimisation », ni gestion des éléments de démarrage, ni
nettoyage de la RAM, ni désinstallation de mails. Toute demande dans ce sens est
à signaler (RULES.md, « Attentes de méthode »).

### 1.3 Positionnement

Le ménage manuel du 18/10/2026 a fait passer un Mac de 1 To de 65 à 351 Go
libres. Environ 217 Go étaient retenus par des snapshots Time Machine locaux, le
reste dormait dans les outils : simulateurs, worktrees d'agents, historiques
Claude et Codex, modèles IA, caches de build.

La concurrence est fournie (CleanMyMac 5.7 et sa catégorie « AI Clutter »,
DaisyDisk, Mole, SpaceGuard, CleanMyAgent…), mais aucune ne réunit :

1. la corbeille d'abord **et** un rapport honnête (maintenant / après la corbeille /
   après les snapshots) ;
2. des doublons conscients des clones APFS, avec « transformer en clone » ;
3. le graphe du travail des agents : worktree ↔ historique ↔ branche ↔ processus ;
4. le coût de reconstruction de chaque élément ;
5. une explication hors ligne pour chaque règle.

---

## 2. Distribution et permissions

- Hors App Store : le bac à sable interdirait le parcours complet, les snapshots
  et les caches des navigateurs.
- **Accès complet au disque** : demandé après une première analyse qui montre ce qui
  reste invisible. Pas d'API pour le détecter : on sonde
  (`~/Library/Safari`, `~/Library/Mail`) et on classe les erreurs (`EPERM` = TCC).
  Lien direct : `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
  Un relancement est nécessaire après l'octroi.
- **Administrateur** : en v0.1, une invite ponctuelle (`do shell script … with
  administrator privileges`), uniquement pour `tmutil deletelocalsnapshots` sur
  des dates validées. En phase 3 : démon `SMAppService` aux verbes XPC typés
  (modèle : `Tacho/Shared/HelperProtocol.swift`).
- **Finder (AppleEvents)** : pour mettre à la corbeille avec « Remettre ».

---

## 3. Analyse

### 3.1 Parcours

- `getattrlistbulk(2)` sur un pool de threads dédiés (4 à 12), file de dossiers,
  tampons de 128 Ko.
- Attributs : `NAME`, `DEVID`, `OBJTYPE`, `MODTIME`, `FLAGS`, `FILEID`,
  `DIR_MOUNTSTATUS`, `FILE_LINKCOUNT`, `FILE_ALLOCSIZE`, `CMNEXT_CLONEID`,
  `CMNEXT_EXT_FLAGS`. `CMNEXT_PRIVATESIZE` à la demande, pour les fichiers
  marqués `EF_MAY_SHARE_BLOCKS`.
- **Ne jamais quitter le volume** : `DIR_MNTSTATUS_MNTPOINT`, `SF_FIRMLINK`,
  table `getfsstat`. Le disque de démarrage s'analyse depuis `/System/Volumes/Data`.
- Dossiers `SF_DATALESS` non ouverts ; matérialisation iCloud coupée
  (`setiopolicy_np`).
- Refus TCC : listés « inaccessibles », jamais ignorés en silence.

### 3.2 Tailles

Trois tailles par élément : **allouée**, **libérable** (privée : ce que la
suppression rend vraiment), **retenue** (partagée avec un clone ou un snapshot).
Liens physiques comptés une fois par `(dev, ino)`, clones complets une fois par
`(dev, cloneID)`.

### 3.3 Arborescence façon TreeSize

L'Explorateur montre l'arborescence complète d'un volume, triée par taille :
dossiers dépliables, pourcentage du parent, barre proportionnelle, nombre de
fichiers. Les fichiers de plus de 1 Mo sont listés un à un ; les plus petits sont
regroupés en « petits éléments ». Exemple attendu :
`Applications — 233 Go` ▸ `Age of Empires II — 39 Go`, `Civilization VII — 19 Go`…

### 3.4 Volumes

Tous les volumes montés sont proposés : disque de démarrage, disques internes
secondaires, disques externes. Le branchement d'un disque déclenche une
proposition d'analyse (`NSWorkspace.didMountNotification`). Sur un disque
externe s'appliquent l'Explorateur, les doublons, les gros fichiers et les
artefacts de projets des dossiers choisis.

### 3.5 Capacité et part invisible

- Capacité réelle (`volumeAvailableCapacity`), importante (`…ForImportantUsage`,
  celle du Finder), purgeable = différence.
- Snapshots listés sur `/System/Volumes/Data` ; `com.apple.os.update-*` jamais touchés.
- « Non attribué » = utilisé − analysé : part protégée, snapshots, système.

---

## 4. Règles

Une règle : motif, propriétaire, catégorie, classe de sécurité, méthode, coût de
reconstruction, clé d'explication (`rule.<id>.what`, `.why`, `.back`).

| Catégorie | Contenu | Classe par défaut |
|---|---|---|
| Artefacts de projets | marqueur → artefacts (kondo, npkill, Mole) | Se reconstruit |
| Caches de paquets | npm, pnpm, yarn, pip, uv, Gradle, CocoaPods, Cargo, Homebrew, Go | Sûr |
| Xcode | DerivedData (projet disparu = obsolète), ModuleCache, DeviceSupport (sauf le plus récent par OS), Archives | Sûr / Se reconstruit / À examiner |
| Simulateurs | appareils indisponibles, runtimes inutilisés | Sûr / À examiner |
| Agents IA | worktrees, historiques Claude et Codex, dossiers de travail | À examiner, protégé si état unique |
| Modèles IA | HuggingFace, Ollama, LM Studio, dossiers `models` d'apps | À examiner |
| Utilisateur | installeurs, gros fichiers anciens des Téléchargements, corbeille, sauvegardes iOS | À examiner |
| À gérer à part | VM, `Docker.raw` | À examiner, hors total en titre |

Garde de récence : un élément touché depuis moins de 7 jours n'est pas présélectionné.
Noms ambigus (`build`, `dist`, `vendor`, `bin`) : marqueur + non suivi par git.

---

## 5. Sécurité

- Classes : **Sûr**, **Se reconstruit**, **À examiner**, **Protégé** (non
  sélectionnable, raison affichée), **Inaccessible**.
- Protection automatique : processus actif (dossier courant via `proc_pidinfo`),
  modifications non commitées, commits non fusionnés ou non poussés, verrou git,
  fichiers ignorés uniques (`.env`, clés), application ouverte (navigateurs).
- `PathGuard` : chemin absolu, sans `..`, liens résolus ; refus de `/`, `/System`,
  `/Library`, `/Applications` (racine), `~`, `~/Library` et ses racines, trousseaux,
  `Mobile Documents`, bibliothèques Photos et Musique.

---

## 6. Nettoyage

### 6.1 Méthodes

| Type | Méthode |
|---|---|
| Régénérable | `removefile(REMOVEFILE_RECURSIVE)`, sans traverser de montage |
| Personnel | corbeille par le Finder (« Remettre » conservé), repli `trashItem` |
| Worktree | `git worktree remove` puis `git worktree prune` |
| Simulateur | `xcrun simctl delete` / `simctl runtime delete` |
| Snapshot | `tmutil deletelocalsnapshots <date>` en administrateur |
| Firefox | SQL `DELETE` + `VACUUM` (l'historique partage le fichier des favoris) |

### 6.2 Vocabulaire

- **La corbeille** (sans complément) : celle d'Oust!, où l'on jette ce qu'on veut voir
  partir. Rien n'y est encore supprimé. Symbole `trash`.
- **La corbeille du Mac** : celle de macOS, où part le contenu personnel au moment du
  vide, et d'où il se restaure. Toujours nommée ainsi, symbole `trash.square`.
- En anglais : *Bin* pour la première, *the Mac's Trash* pour la seconde.

Le mot « panier » n'est pas employé : c'est une corbeille, pas un achat (Romain,
18/10/2026). Les identifiants du code (`cart`, `FeatureCart`) restent en anglais.

### 6.3 Déroulé

1. Une corbeille unique, toutes catégories confondues : on y jette ce qui doit partir.
2. Revue : taille libérable, méthode, badges ; désélection ; révéler dans le Finder.
3. Confirmation renforcée au-delà de 5 Go ou pour un élément « À examiner ».
4. **Nettoyage en direct** : une pulsation (et non une barre de progression), chaque
   élément quitte la liste au moment où il est traité, le compteur d'espace
   libéré monte en temps réel. Annulable à tout moment entre deux éléments.
5. **Rapport honnête** : libéré maintenant, en attente de la corbeille, retenu par
   les snapshots ; puis suivi de la reprise d'espace par APFS pendant 3 minutes.

### 6.4 Historique local

Chaque nettoyage est journalisé (`~/Library/Application Support/Oust/history.jsonl`) :
date, élément, chemins, méthode, résultat, octets, emplacement dans la corbeille.
La section **Historique** montre ce qui a été viré, quand, comment, où c'est parti,
et propose « Restaurer » pour ce qui est encore à la corbeille.

---

## 7. Doublons

- Fichiers > 1 Mo, groupés par `(volume, taille)`, liens physiques et clones complets
  écartés (ils ne libèrent rien), empreinte tête + queue de 16 Ko, puis SHA-256.
- Économie annoncée = taille privée des copies retirées.
- Sélection intelligente : dossiers de référence (jamais), dossiers « toujours
  proposer » (Téléchargements, Bureau), suffixes de copie localisés, garder le plus
  ancien. **Égalité = aucune sélection ; jamais toutes les copies d'un groupe.**
- Actions : corbeille, ou **transformer en clone** (`clonefile`, métadonnées
  conservées, revérification avant remplacement).

---

## 8. Navigateurs

Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera, Firefox ; tous les profils.
Cache (coché par défaut), historique, cookies (décochés). Navigateur fermé exigé.
Jamais : mots de passe (`Login Data`), cartes (`Web Data`), favoris.

---

## 9. Interface

### 9.1 Esprit

Percutant, magnifique, coloré, à la manière de CleanMyMac : un dégradé vif par
section, de grands chiffres, des matières en verre, des animations franches mais
brèves. La confiance passe par la clarté : chaque élément dit ce qu'il est,
pourquoi on peut l'enlever et comment il reviendrait.

### 9.2 Sections

Vue d'ensemble · Développement & IA · Explorateur · Doublons · Navigateurs ·
Système · Historique · Corbeille.

Les **Réglages** ont leur fenêtre, à la manière des apps d'Apple (Romain,
18/10/2026) : Oust! › Réglages… (⌘,) ou le panneau de la barre des menus, quatre
onglets — Général, Analyse, Veille, Avancé.

### 9.3 Mouvement

- Analyse : un orbe qui pulse et des catégories qui se remplissent au fil de l'eau.
- Nettoyage : la pulsation bat à chaque élément traité ; l'élément se fond et
  quitte la liste ; le compteur monte.
- `accessibilityReduceMotion` : fondus simples, pas de pulsation.

---

## 10. Phases

- **v0.1** : tout ce qui précède.
- **Phase 2** : désinstalleur avec restes, archivage de projets vers un disque
  externe, gros et vieux fichiers, vue soleil / treemap.
- **Phase 3** : démon privilégié, barre de menus et alerte disque bas, politiques
  de rétention, explications détaillées en option, CLI/MCP pour les agents,
  publication notarisée.
