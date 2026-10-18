# 1. Démon privilégié pour les snapshots Time Machine

**Date :** 2026-10-18
**Statut :** accepté

## Le problème

Supprimer un snapshot Time Machine local demande les droits d'administrateur.
Depuis la v0.1, Oust! passe par une invite ponctuelle (`do shell script … with
administrator privileges`) qui ne lance que `tmutil deletelocalsnapshots` sur
des dates validées. Ça marche, mais le mot de passe revient à chaque nettoyage.
Le SPEC (§2, phase 3) prévoit un démon `SMAppService` aux verbes typés, sur le
modèle de Tacho.

## La décision

Un démon `oust-helper`, embarqué dans l'app, **installé seulement si
l'utilisateur le demande** dans les Réglages, après avoir lu ce qu'il peut faire
et ce qu'il ne peut pas faire.

| | |
| --- | --- |
| Emplacement | `Contents/MacOS/oust-helper`, plist dans `Contents/Library/LaunchDaemons` |
| Lancement | à la demande, par launchd, au premier message sur `fr.meaillais.oust.helper` ; il quitte après une minute sans demande |
| Verbes | `deleteLocalSnapshots(dates, contractVersion)`, `deleteBackups(timestamps, destination, contractVersion)` (depuis la version 2 du contrat, voir plus bas) et `readStatus` ; aucun autre |
| Appelant admis | `anchor apple generic and identifier "fr.meaillais.oust" and certificate leaf[subject.OU] = "H3W3XYM2NZ"` |
| Démon admis par l'app | la même exigence, sous `fr.meaillais.oust.helper` |

**Aucun verbe « exécuter cette commande »** (RULES.md, règle 7). Le démon ne
reçoit que des dates. Chacune doit avoir la forme exacte `AAAA-MM-JJ-HHMMSS`
(dix-sept octets ASCII, mois, jour et heure plausibles) **et** désigner un
snapshot `com.apple.TimeMachine.<date>.local` présent dans `tmutil
listlocalsnapshots /System/Volumes/Data`. Ce n'est qu'alors qu'elle part, seule
et sans shell, à `/usr/bin/tmutil deletelocalsnapshots`. Les snapshots
`com.apple.os.update-…` ne sont jamais lisibles comme des dates, donc jamais
visés. Un point de montage, que `tmutil` accepterait à la place d'une date et
qui viderait le volume, n'a pas la forme d'une date.

**La signature est vérifiée des deux côtés**, par le système, sur le jeton
d'audit et non sur un PID : `setConnectionCodeSigningRequirement` sur l'écouteur
et `setCodeSigningRequirement` sur chaque connexion côté démon,
`setCodeSigningRequirement` côté application. L'équipe est écrite en dur, et non
lue dans la signature du démon : un démon re-signé par d'autres ferait sinon
confiance à leur équipe. La même exigence accepte un certificat « Apple
Development » (Debug) et « Developer ID Application » (Release).

**Le démon est optionnel de bout en bout.** `VolumeService.deleteSnapshots`, seul
appelant, lui-même appelé par `CleanupEngine`, essaie le démon s'il est
enregistré et approuvé. S'il ne l'est pas, s'il est injoignable, si l'une des
deux signatures est refusée ou s'il refuse la demande entière (autre version de
contrat, liste illisible), rien n'a été fait et l'invite administrateur d'avant
prend le relais, inchangée. Quand il répond, il dit ce qu'il a fait date par
date, et un snapshot encore listé après coup n'est pas annoncé supprimé. Sans
réponse à temps, l'opération est un échec : le démon travaille peut-être encore,
on ne redemande pas par un autre chemin. `CleanupEngine` n'a pas changé : même
revalidation, même journal.

## Les sauvegardes d'un disque Time Machine (version 2, 18/10/2026)

Romain : « j'ai un disque dur où il y a une Time Machine… le disque me dit qu'il
n'y a presque plus d'espace, mais c'est parce qu'il y a plusieurs versions.
Est-ce qu'on ne pourrait pas dégager les plus anciennes et garder par exemple
les deux ou trois dernières ? » `tmutil delete -d <point de montage> -t
<horodatage>` demande root (et l'Accès complet au disque) : un troisième verbe,
sur le modèle du premier.

Le démon ne reçoit que des horodatages et un point de montage, et relit tout
lui-même avant d'agir, dans cet ordre :

1. contrat, demande non vide, au plus `TimeMachineBackups.maximumPerRequest` ;
2. point de montage de la forme exacte `/Volumes/<nom>` (ni `/`, ni `..`, ni
   tiret en tête, ni guillemet, barre oblique inverse ou caractère de contrôle)
   **et** présent à l'instant parmi les destinations **locales** montées de
   `tmutil destinationinfo -X` ; sinon `unknown_destination` ;
3. `tmutil status -X` : une sauvegarde en cours, ou un état illisible, refuse
   tout (`backup_running`) ;
4. `tmutil listbackups -d <point de montage>` : illisible, refus
   (`listing_failed`) ;
5. chaque horodatage : forme exacte `AAAA-MM-JJ-HHMMSS` (la validation des
   dates de snapshots), listé, et **jamais le plus récent** ; l'état est relu
   avant chaque suppression, et une sauvegarde qui démarre laisse le reste ;
6. après coup, la liste relue : une sauvegarde encore listée n'est pas annoncée
   supprimée.

L'application lit la version du démon avant de lui demander quoi que ce soit :
un démon de la version 1 ne connaît pas ce verbe, et le lui envoyer ne ferait
qu'attendre le délai. Démon absent, d'une autre version, ou qui n'a pas pu lire
la liste (il lui faut l'Accès complet au disque, que l'invite tient d'Oust!) :
l'invite administrateur prend le relais, avec le point de montage passé en
argument d'`osascript` (`item 1 of argv`, `quoted form of`) et jamais écrit
dans le texte du script. Sauvegarde en cours ou destination inconnue :
on s'arrête, sans invite. Ce qui a vraiment disparu se lit dans la liste relue
par `BackupPruner` (OustClean), qui journalise chaque sauvegarde.

## Le découpage

- `OustHelperContract` : le protocole XPC, les noms, les exigences, la validation
  des dates. Ne dépend que de Foundation.
- `OustHelperDaemon` : le service (acceptation des connexions, décision,
  `tmutil`). Seul le démon le lie ; l'application ne contient pas le code qui
  tourne en root.
- `OustVolume/PrivilegedHelper` : le client, et l'installation par `SMAppService`.
- `App/OustHelper/main.swift` : branche le service sur son service Mach.

La décision du démon (`HelperService.handle`) est une fonction pure, testée avec
un faux `tmutil`. Les tests XPC tournent sans root : un écouteur anonyme porte le
vrai service dans le processus de test, qui n'est pas Oust! et joue donc
l'appelant étranger. Chaque refus a son témoin, le même échange avec une exigence
que ce processus satisfait, pour prouver que c'est la signature qui refuse et
non XPC qui est en panne.

## Ce qui reste ouvert

- **Copies de développement.** L'en-tête de `SMAppService` exige d'une app qui
  embarque un démon qu'elle soit notarisée, et Tacho a vu une copie signée Apple
  Development refusée (« Codesigning failure loading plist »). Les Réglages le
  disent sans interdire l'essai, qui ne demande rien. Le chemin complet
  (installation, approbation, suppression sans invite) ne se vérifie donc que
  sur une copie Developer ID notarisée.
- **Mises à jour.** Apple recommande de réenregistrer le démon quand son
  exécutable change. Tant que ce n'est pas fait, il peut ne plus répondre :
  l'invite reprend la main, et les Réglages proposent « Réinstaller ».
- **Accès complet au disque du démon.** `tmutil delete` et `listbackups`
  l'exigent. Un démon lancé par launchd n'hérite pas de celui d'Oust! : s'il
  ne l'a pas, sa lecture de la liste échoue, il refuse en bloc, et l'invite
  reprend la main. À vérifier sur une copie notarisée.
- **Résultat par snapshot.** `CleanupEngine` attend un seul booléen pour tout le
  lot ; le démon en sait plus (date par date), que le journal ne garde pas
  encore.
