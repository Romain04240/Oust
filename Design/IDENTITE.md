# IDENTITE — Oust!

Ce fichier fait foi pour le nom, les couleurs, l'icône et la jauge (voir `RULES.md`,
« Identité — valeurs de référence »). Les valeurs viennent de `outils/palette.py`, qui
vérifie aussi les contrastes : on modifie le script d'abord, ce fichier ensuite.

---

## Identité — valeurs de référence

- Nom affiché : `Oust!`, O majuscule, le reste en bas de casse, point d'exclamation
  **collé** (sans l'espace fine que la typographie française mettrait devant).
  Nom technique (produit, cible, modules, identifiants, dossiers) : `Oust`, sans ponctuation
- Accent : `#CA006D` en apparence claire · `#E0157F` pour les commandes en apparence
  sombre · `#FF6FB8` pour le texte en apparence sombre — sélection, commandes, liens
- Éclat : `#FFE45C → #FFA51A → #FF5A1F`, texte posé dessus `#1B0E52` — **réservé à
  l'action de faire le vide** (bouton principal, corbeille, pulsation, espace libéré)
- Fond d'icône : `#1B0E52` (radial `#3A1C94 → #1B0E52 → #0A0622`) · Anneau :
  `#FF3D8B → #B23BFF → #4F5BFF → #1FD1FF` · Segment chassé : l'Éclat
- Logo : un O en jauge de disque à six segments, dont un est chassé vers le haut à
  droite. L'icône est **fixe**. Ce sont les jauges de l'app qui s'animent
- Fond d'application : **jamais blanc**. Du verre (Liquid Glass) posé sur le dégradé vif
  de la section en apparence claire, sur son fond profond en apparence sombre ; texte blanc
- Un dégradé par section, cinq couleurs de sécurité : tableaux ci-dessous

---

## 1. Le nom

| Contexte | Graphie | Exemples |
|---|---|---|
| Texte visible, marketing, fenêtre « À propos » | `Oust!` | « Oust! a libéré 79,6 Go. » |
| Fin de phrase | `Oust!` sans point ajouté | « Merci d'utiliser Oust! » |
| Produit, cible, module, bundle, dossier | `Oust` | `Oust.app`, `OustKit`, `fr.meaillais.oust`, `~/Library/Application Support/Oust` |

Jamais `OUST!`, `oust!`, `Oust !` ni `Oust!!`. Le « ! » fait partie du nom, pas de la phrase.

---

## 2. Le logo et son sens

« Oust! », c'est le geste qui chasse ce qui encombre. Le logo le montre sans balai :

- **Le O est une jauge de disque.** Six segments de verre, séparés par des joints
  réguliers, comme les catégories qu'Oust! mesure.
- **Un segment est chassé.** Le sixième, jaune-orangé, quitte l'anneau vers le haut à
  droite (45°), pivote de 18° et laisse trois traînées. La place vide qu'il laisse,
  c'est l'espace libéré.
- **Les couleurs disent le rôle.** L'anneau garde le dégradé froid de la marque
  (magenta, violet, bleu, cyan). Le segment chassé prend la couleur complémentaire,
  l'Éclat, qui attire l'œil sur l'action. Dans l'app, l'Éclat garde ce sens : c'est la
  couleur du vide qu'on fait.
- **La sortie se fait toujours vers le haut à droite.** Vers l'avant, jamais vers le bas.
- **Rien n'est détruit à l'image** : ni explosion, ni éclats, ni corbeille dessinée. Le
  segment s'en va entier, comme un fichier qui part à la corbeille du Mac avec son chemin
  d'origine.

### Fichiers

| Fichier | Usage |
|---|---|
| `oust-icon.svg` | Maître de l'icône, de 64 à 1024 px |
| `oust-icon-petit.svg` | 16 et 32 px : joints élargis, segment plus écarté, sans traînées ni reflets fins |
| `Oust.icon/` | Icône Icon Composer de macOS 26 : couleur, sombre, teintée et transparente. Quatre couches SVG à plat (fond, anneau, segment chassé, traînées), le système pose le verre. Validé par `actool` (macOS 26), sans avertissement |
| `planche-icone-variantes.png` | Les six rendus de `Oust.icon` par Icon Composer : couleur, teintée et transparente, en apparence claire et sombre |
| `AppIcon.appiconset/` | 16, 32, 128, 256, 512 en @1x et @2x (le 512@2x fait 1024). Validé par `actool` (macOS 26), sans avertissement |
| `oust-icon-1024.png` | Icône seule pour le README, le site, la notarisation |
| `AccentColor.colorset/` | Accent clair et sombre, prêt à remplacer celui de l'app |
| `oust-monogramme.svg` | Marque à plat, noire, pour une image modèle (barre latérale, « À propos », barre de menus en phase 3) |
| `oust-monogramme-couleur.svg` | Marque à plat en couleurs, sans filtre ni masque : Xcode la rend telle quelle |
| `maquette-app.png` | Vue d'ensemble en apparence claire et sombre : fonds, verre, jauge, pastilles |
| `planche-palette.png` | Palette complète en situation |
| `directions/` | Les trois directions proposées le 18/10/2026 (A retenue) |
| `outils/` | Générateurs : rien n'est dessiné à la main |

Régénérer :

```bash
python3 Design/outils/icone_finale.py        # SVG maîtres, monogrammes et Oust.icon
Design/outils/generer-appiconset.sh
python3 Design/outils/apercu_icone.py        # planche des variantes (ictool, Xcode 26+)
python3 Design/outils/palette.py --check
```

Intégration :

- `project.yml` prend `Design/Oust.icon` en place, dans les ressources de la cible, et
  le nomme par `ASSETCATALOG_COMPILER_APPICON_NAME: Oust` (le nom du fichier sans son
  extension). Une retouche de l'icône n'a donc rien à recopier : il suffit de régénérer.
  Vérifié avec XcodeGen 2.46 et Xcode 27.1 sur un projet d'essai monté de la même
  façon : build sans avertissement, et l'app embarque les trois piles d'icône
  (claire, sombre, teintable).
- `AppIcon.appiconset` et `AccentColor.colorset` sont copiés dans
  `App/Oust/Resources/Assets.xcassets/`. L'appiconset y reste comme repli : avec un
  `.icon`, `actool` ne s'en sert pas pour l'icône de l'app.

### `Oust.icon` (macOS 26)

Un appiconset s'affiche dans le masque du système sans variantes. `Oust.icon` les donne,
avec le verre, les reflets et les ombres d'Icon Composer :

- **Toile.** Dans Icon Composer, les 1024 px sont la forme entière de l'icône (le
  squircle classique n'en occupe que 824) : la marque est agrandie de 1024 / 824 et
  garde sa place.
- **Groupes**, du premier plan au fond : *Segment* (le segment chassé en verre, ses
  traînées sans verre pour qu'elles restent des filets de lumière Éclat), *Anneau* (les
  cinq segments en verre), *Fond* (dégradé radial, halos et voile du haut, sans verre).
- **Ombre colorée** (`layer-color`) : 0,8 sous le segment, 0,7 sous l'anneau. Elle
  remplace le halo flou de l'icône classique.
- **Sombre** : le fond passe à 35 % sur `#0A0622`. L'anneau et l'Éclat ne changent pas.
- **Teintée et transparente** : le fond est masqué et le système pose sa teinte.
  L'anneau passe à 70 % pour que l'Éclat reste la partie la plus claire.
- **Couleurs** : les SVG sont lus en sRGB, comme la palette.
- Le verre est celui du système : l'anneau paraît plus saturé et moins laiteux que dans
  l'icône classique, qui l'imitait.

Les réglages vivent dans `ICON_JSON` (`outils/icone_finale.py`), qui réécrit
`icon.json` à chaque génération. Une retouche faite dans Icon Composer se reporte donc
dans le script, sinon la génération suivante l'efface.

---

## 3. Dégradés de section

Le dégradé va du coin haut-gauche (départ) au coin bas-droit (arrivée). Le texte blanc
tient 4,5:1 sur **toute** sa longueur, quel que soit l'espace d'interpolation (sRGB par
défaut dans SwiftUI, linéaire, OKLab). La **lueur** sert au décor et aux segments de
jauge, jamais sous du texte. Le **profond** est le fond de la section en apparence sombre.

| Section | Clé | Départ | Arrivée | Lueur | Profond |
|---|---|---|---|---|---|
| Vue d'ensemble | `overview` | `#E0157F` | `#6E3BF5` | `#FF6FB8` | `#1B0E52` |
| Développement & IA | `developmentAI` | `#8E3CF7` | `#2F5BF5` | `#9E8CFF` | `#0A1652` |
| Explorateur | `explorer` | `#0A6BE0` | `#007D8F` | `#4FC3FF` | `#002142` |
| Doublons | `duplicates` | `#00806C` | `#14853A` | `#3EE0A8` | `#002917` |
| Navigateurs | `browsers` | `#CC4A06` | `#D3145E` | `#FF8A4C` | `#420018` |
| Système | `system` | `#5148D6` | `#334D73` | `#8FA2FF` | `#121E39` |
| Historique | `history` | `#A35F00` | `#B03F0B` | `#FFB547` | `#391100` |

La Corbeille et les Réglages n'ont pas de dégradé propre. La Corbeille prend l'Éclat
pour son pictogramme (`trash`) et son badge, et le fond de la Vue d'ensemble. Les Réglages suivent
le système.

---

## 4. Fonds de l'application : pas de blanc, du verre

La fenêtre principale ne montre jamais de fond blanc ni gris système. Elle pose du
verre sur un fond coloré qui change avec la section active :

| Apparence du système | Fond de la fenêtre |
|---|---|
| Claire | Dégradé vif de la section (départ → arrivée, en diagonale), plus un halo de sa lueur en haut à gauche (mode écran, 35 %, flou large) |
| Sombre | Profond de la section, plus deux halos en mode écran à 45 % et flou large : le départ en bas à gauche, l'arrivée en haut à droite |

Règles :

1. **Le verre partout ailleurs.** La barre latérale, les cartes, la barre d'outils et la
   barre d'action sont en Liquid Glass (`glassEffect`). Le contraste est calculé avec un
   verre modélisé ainsi : 14 % de noir, puis 6 % de blanc. Si le verre seul éclaircit
   davantage, le teinter de noir à 14 %.
2. **Ce qui est posé sur le fond est rendu en schéma sombre**, dans les deux apparences
   (texte blanc, commandes sombres, variantes « vif » des couleurs). Seul le fond suit
   l'apparence du système.
3. **Texte en blanc pur uniquement** sur ces fonds. Pas de `.secondary` ni de
   `.tertiary` : le blanc translucide repasse sous 4,5:1 sur les dégradés vifs. La
   hiérarchie passe par la taille et la graisse.
4. **Changement de section** : le fond passe d'une section à l'autre en fondu de 250 ms
   (fondu simple aussi avec `accessibilityReduceMotion`).
5. **Les fenêtres qui suivent le système** (Réglages, alertes, feuilles) gardent les
   fonds de macOS et les pastilles teintées (§ 6).

---

## 5. La jauge

Les jauges de l'app reprennent l'anneau de l'icône, mais elles sont **dynamiques** :
elles mesurent, se remplissent et chassent. L'algorithme de référence est la fonction
`gauge` de `outils/maquette.py`.

### Géométrie (rayon extérieur R)

| Mesure | Valeur | Origine |
|---|---|---|
| Épaisseur | 0,46 R (rayon intérieur 0,54 R) | icône : 126 / 276 |
| Joint entre segments | 0,065 R, **largeur constante** (pas un angle) | icône : 18 / 276 |
| Rayon des coins | 0,094 R, réduit sur les petits segments pour que les coins intérieurs tiennent | icône : 26 / 276 |
| Segment minimal | ≈ 9,6° pour R = 168 pt, 12° pour R = 80 pt (formule `min_span`) ; en dessous, il rejoint « Autres » | — |
| Détachement de la corbeille | 0,08 R vers l'extérieur, sur sa bissectrice | — |
| Éjection | 0,38 R vers l'extérieur et 18° de rotation | icône : 104 / 276 |

### Ordre et couleurs

- Départ à midi, sens horaire : les catégories de la plus grande à la plus petite, puis
  « Autres », puis la **corbeille**, puis l'espace libre. La corbeille touche ainsi
  l'espace libre, qui s'agrandit d'un bloc quand son segment est chassé.
- Segment de catégorie : dégradé de la **lueur** vers le départ de la section, arrêté à
  15 % (`#9E8CFF → #9C82FE` pour Développement & IA), avec un halo de la lueur dessous
  (flou, 55 %, mode écran).
- « Autres » : `#D9D4EC`. Corbeille : l'Éclat. Espace libre : la piste seule.
- Piste : anneau complet en verre fumé, 35 % de noir sur le fond.
- Liseré : 1,5 pt de blanc à 35 % autour de chaque segment.

### Mouvement

| Moment | Ce que fait la jauge | Durée |
|---|---|---|
| Analyse | Les segments naissent et s'allongent au fil des catégories mesurées | angle animé à chaque mise à jour, ressort 250 ms |
| Corbeille modifiée | Le segment Éclat grandit ou rétrécit, toujours détaché de 0,08 R | ressort 200 ms |
| Nettoyage | Le segment de la corbeille bat à chaque élément traité (échelle 1 → 1,04 → 1) | 160 ms par battement |
| Fin du nettoyage | Le segment de la corbeille est chassé : 0,38 R vers l'extérieur, 18° de rotation, fondu, trois traînées Éclat. L'espace libre et le chiffre central montent | 280 ms, décélération |

Avec `accessibilityReduceMotion` : pas de battement ni d'éjection, seulement des fondus.

La jauge porte un libellé d'accessibilité (« 351 Go libres sur 1 To, 79,6 Go dans la
corbeille »). La légende redonne chaque valeur en texte : la couleur n'est jamais le seul
porteur d'information.

---

## 6. Classes de sécurité

| Classe | Clé | Foncé | Vif | Symbole conseillé |
|---|---|---|---|---|
| Sûr | `safe` | `#006725` | `#3DD68C` | `checkmark.circle.fill` |
| Se reconstruit | `rebuilds` | `#0057B3` | `#5CB4FF` | `arrow.triangle.2.circlepath` |
| À examiner | `review` | `#963D00` | `#FFB547` | `eye.fill` |
| Protégé | `protected` | `#563ECF` | `#B3A3FF` | `lock.fill` |
| Inaccessible | `inaccessible` | `#595961` | `#AAAAB3` | `eye.slash.fill` |

- **Fenêtre principale : pastille pleine.** Fond « foncé », texte et symbole blancs,
  liseré blanc à 25 %. C'est la seule forme lisible sur tous les fonds de section.
- **Fenêtres système : pastille teintée.** La couleur à 14 % sur le fond, le texte de la
  même couleur : « foncé » en apparence claire, « vif » en apparence sombre.
- **« Vif » seul**, sans texte : seulement en pictogramme sur le verre des fonds profonds.
- La classe se lit toujours par son mot et son symbole, pas par sa seule couleur.
- Le rouge n'est pas une classe. Il reste réservé aux erreurs réelles.
- L'Éclat et « À examiner » sont deux orangés proches. L'Éclat ne sert jamais à une
  pastille, et « À examiner » jamais à une action.

---

## 7. Contrastes vérifiés (WCAG 2.2 AA)

Seuils : 4,5:1 pour le texte, 3:1 pour les éléments graphiques. Rapport produit par
`python3 Design/outils/palette.py`. Les pires points sont mesurés sur toute la longueur
des dégradés et au cœur des halos.

#### Texte blanc sur les fonds de section

Verre : voile noir 14 %, reflet blanc 6 %. Halos du fond profond : départ et arrivée en mode écran à 45 %.

| Section | Dégradé vif (pire point) | Verre sur dégradé vif | Fond profond et halos | Verre sur fond profond | AA texte |
|---|---:|---:|---:|---:|:---:|
| Vue d'ensemble | 4,58 | 5,43 | 9,74 | 9,86 | ✅ |
| Développement & IA | 5,07 | 5,70 | 9,69 | 9,58 | ✅ |
| Explorateur | 4,83 | 5,37 | 8,57 | 8,61 | ✅ |
| Doublons | 4,71 | 5,31 | 8,24 | 8,34 | ✅ |
| Navigateurs | 4,62 | 5,29 | 9,35 | 9,55 | ✅ |
| Système | 6,47 | 6,87 | 9,98 | 9,67 | ✅ |
| Historique | 5,01 | 5,56 | 9,13 | 9,13 | ✅ |

#### Segments de jauge sur leur piste (éléments graphiques, seuil 3:1)

Segment : dégradé de la lueur vers le départ de la section, arrêté à 15 %. Piste : 35 % de noir posé sur le verre, au pire point de chaque fond de l'app (dégradés vifs et fonds profonds avec leurs halos).

| Section | Segment | Pire contraste avec une piste | AA graphique |
|---|---|---:|:---:|
| Vue d'ensemble | `#FF6FB8` → `#FB65AF` | 3,44 | ✅ |
| Développement & IA | `#9E8CFF` → `#9C82FE` | 3,20 | ✅ |
| Explorateur | `#4FC3FF` → `#44B6FB` | 4,24 | ✅ |
| Doublons | `#3EE0A8` → `#36D19F` | 4,89 | ✅ |
| Navigateurs | `#FF8A4C` → `#F78144` | 3,71 | ✅ |
| Système | `#8FA2FF` → `#8595F9` | 3,48 | ✅ |
| Historique | `#FFB547` → `#F1A83E` | 4,73 | ✅ |

#### Classes de sécurité

Fenêtre principale : pastille pleine (fond « foncé », texte et pictogramme blancs), lisible sur tous les fonds de section. Fenêtres qui suivent le système : pastille teintée (la couleur à 14 % sur le fond, texte de la même couleur), « foncé » en clair, « vif » en sombre. Le « vif » sert aussi de pictogramme seul sur le verre des fonds profonds (seuil graphique 3:1).

| Classe | Foncé | Vif | Blanc sur pastille pleine | Foncé, fonds clairs et pastille | Vif, fonds sombres et pastille | Vif en pictogramme sur verre profond | Verdict |
|---|---|---|---:|---:|---:|---:|:---:|
| Sûr | `#006725` | `#3DD68C` | 7,08 | 4,72 | 5,57 | 4,45 | ✅ |
| Se reconstruit | `#0057B3` | `#5CB4FF` | 6,97 | 4,65 | 4,81 | 3,75 | ✅ |
| À examiner | `#963D00` | `#FFB547` | 7,08 | 4,71 | 5,83 | 4,75 | ✅ |
| Protégé | `#563ECF` | `#B3A3FF` | 7,03 | 4,69 | 4,83 | 3,81 | ✅ |
| Inaccessible | `#595961` | `#AAAAB3` | 6,94 | 4,70 | 4,62 | 3,62 | ✅ |

#### Accent et Éclat

| Usage | Couleurs | Rapport | Seuil | Verdict |
|---|---|---:|---:|:---:|
| Libellé blanc sur commande, apparence claire | `#FFFFFF` sur `#CA006D` | 5,63 | 4,5 | ✅ |
| Libellé blanc sur commande, apparence sombre | `#FFFFFF` sur `#E0157F` | 4,58 | 4,5 | ✅ |
| Accent en texte, fond clair « blanc » | `#CA006D` sur `#FFFFFF` | 5,63 | 4,5 | ✅ |
| Accent en texte, fond clair « fenêtre » | `#CA006D` sur `#F5F5F7` | 5,17 | 4,5 | ✅ |
| Accent en texte, fond clair « latéral » | `#CA006D` sur `#E8E8ED` | 4,61 | 4,5 | ✅ |
| Commande accent sur fond sombre « noir » | `#E0157F` sur `#000000` | 4,58 | 3 | ✅ |
| Commande accent sur fond sombre « fenêtre » | `#E0157F` sur `#1E1E20` | 3,63 | 3 | ✅ |
| Commande accent sur fond sombre « latéral » | `#E0157F` sur `#2C2C30` | 3,04 | 3 | ✅ |
| Accent en texte, fond sombre « noir » | `#FF6FB8` sur `#000000` | 8,22 | 4,5 | ✅ |
| Accent en texte, fond sombre « fenêtre » | `#FF6FB8` sur `#1E1E20` | 6,51 | 4,5 | ✅ |
| Accent en texte, fond sombre « latéral » | `#FF6FB8` sur `#2C2C30` | 5,44 | 4,5 | ✅ |
| Texte sur le bouton Éclat (pire point du dégradé) | `#1B0E52` sur Éclat | 5,47 | 4,5 | ✅ |

Bilan : tous les seuils AA sont tenus.

À confirmer dans l'app avec l'Inspecteur d'accessibilité. Liquid Glass s'adapte à ce
qu'il recouvre, et le modèle du verre utilisé ici (14 % de noir, puis 6 % de blanc)
n'en est qu'une approximation.
