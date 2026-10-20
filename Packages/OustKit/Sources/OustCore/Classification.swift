import Foundation

/// Ce qu'on peut faire d'un élément sans y réfléchir.
///
/// L'ordre compte : il sert au tri (le plus sûr d'abord) et à la règle « en cas
/// de doute, protégé » — combiner deux classes garde toujours la plus prudente.
public enum SafetyClass: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Régénéré sans qu'on s'en aperçoive (cache de téléchargement, journal).
    case safe
    /// Revient, mais coûte une reconstruction (`npm install`, une compilation).
    case rebuilds
    /// Contenu personnel ou coûteux à retrouver : l'utilisateur décide.
    case review
    /// Ne peut pas être sélectionné ; la raison est affichée.
    case protected
    /// macOS en refuse la lecture (TCC) : on le montre au lieu de le taire.
    case inaccessible

    public static func < (lhs: SafetyClass, rhs: SafetyClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// La plus prudente des deux.
    public func combined(with other: SafetyClass) -> SafetyClass { max(self, other) }

    public var localizationKey: String {
        switch self {
        case .safe: "safety.safe"
        case .rebuilds: "safety.rebuilds"
        case .review: "safety.review"
        case .protected: "safety.protected"
        case .inaccessible: "safety.inaccessible"
        }
    }
}

/// D'où vient l'élément. Une catégorie appartient à une section de l'interface.
public enum ItemCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case projectArtifacts
    case packageCaches
    case xcode
    case simulators
    case aiAgents
    case aiModels
    /// Anciennes versions d'outils : Xcode, Node, Python, JDK, NDK, Rust, Homebrew.
    case toolVersions
    /// Docker et OrbStack, par leur CLI.
    case containers
    /// Projets endormis, à compresser sur place.
    case compressibleProjects
    case downloads
    case trash
    case iosBackups
    /// Caches des applications, une par une.
    case appCaches
    /// Installeurs de macOS et mises à jour iOS téléchargées.
    case systemDownloads
    /// Pièces jointes de Mail et de Messages.
    case attachments
    /// Vieilles captures d'écran du Bureau.
    case screenshots
    /// Copies locales de fichiers qui restent dans le nuage.
    case cloudFiles
    /// Rendus, proxys et caches des logiciels de montage, de 3D et de musique.
    case creative
    /// Caches des lanceurs de jeux (Steam, Epic, GOG) et jeux désinstallés à moitié.
    case games
    case virtualMachines
    case snapshots
    case browsers
    case duplicates
    case explorer
    /// Une application et ses restes (désinstalleur).
    case applications
    /// Ce qu'ont laissé des applications qui ne sont plus installées.
    case appLeftovers
    /// Un projet archivé sur un disque externe.
    case archives
    /// Un gros fichier ancien, choisi dans la vue « Gros et vieux fichiers ».
    case largeFiles
    /// Les plus grosses vidéos de la photothèque (PhotoKit, jamais le paquet).
    case photoVideos
    /// Captures et enregistrements d'écran anciens de la photothèque.
    case photoScreenshots
    /// Doublons exacts de la photothèque : mêmes ressources, octet pour octet.
    case photoDuplicates
    /// Photos qui se ressemblent (Vision) : jamais cochées d'office.
    case photoSimilar
    /// Photos prises pour garder une information (codes, documents, écrans).
    case photoUtilities
    /// Sur un autre disque que celui de démarrage : les fichiers `._*` et
    /// `.DS_Store` que macOS sème sur les systèmes de fichiers qui ne sont pas
    /// les siens (exFAT, FAT, NTFS).
    case diskTraces
    /// Sur un autre disque : ce qu'Oust! montre sans jamais le proposer
    /// (sauvegardes Time Machine, photothèques), avec la raison.
    case protectedOnDisk
    /// Un fichier d'iCloud Drive ou d'un File Provider, vu par son fantôme :
    /// le supprimer le retire aussi du nuage et des autres appareils.
    case cloudItems
    /// Images qui se ressemblent dans les dossiers ordinaires, hors photothèque
    /// (Vision) : jamais cochées d'office.
    case similarImages

    public var section: AppSection {
        switch self {
        case .projectArtifacts, .packageCaches, .xcode, .simulators, .aiAgents, .aiModels,
             .toolVersions, .containers, .compressibleProjects:
            .developer
        case .downloads, .trash, .iosBackups, .virtualMachines,
             .appCaches, .systemDownloads, .attachments, .screenshots, .cloudFiles, .creative, .games,
             .diskTraces, .protectedOnDisk:
            .system
        case .browsers: .browsers
        case .snapshots: .timeMachine
        case .duplicates, .similarImages: .duplicates
        case .explorer: .explorer
        case .applications, .appLeftovers: .applications
        case .archives: .archive
        case .largeFiles: .largeFiles
        case .photoVideos, .photoScreenshots, .photoDuplicates, .photoSimilar, .photoUtilities: .photos
        case .cloudItems: .clouds
        }
    }

    public var localizationKey: String { "category.\(rawValue)" }

    /// Symbole SF de la catégorie.
    public var symbol: String {
        switch self {
        case .projectArtifacts: "shippingbox"
        case .packageCaches: "archivebox"
        case .xcode: "hammer"
        case .simulators: "iphone.gen3"
        case .aiAgents: "sparkles"
        case .aiModels: "brain"
        case .toolVersions: "square.stack.3d.up"
        case .containers: "shippingbox.circle"
        case .compressibleProjects: "arrow.down.right.and.arrow.up.left"
        case .downloads: "arrow.down.circle"
        case .trash: "trash.square"
        case .iosBackups: "externaldrive.badge.timemachine"
        case .appCaches: "app.badge"
        case .systemDownloads: "arrow.down.app"
        case .attachments: "paperclip"
        case .screenshots: "camera.viewfinder"
        case .cloudFiles: "icloud.and.arrow.down"
        case .creative: "film.stack"
        case .games: "gamecontroller"
        case .virtualMachines: "macwindow.on.rectangle"
        case .snapshots: "clock.arrow.circlepath"
        case .browsers: "safari"
        case .duplicates: "doc.on.doc"
        case .explorer: "folder"
        case .applications: "app"
        case .appLeftovers: "app.dashed"
        case .archives: "tray.and.arrow.down"
        case .photoVideos: "video"
        case .photoScreenshots: "camera.viewfinder"
        case .photoDuplicates: "photo.on.rectangle"
        case .photoSimilar: "square.stack"
        case .photoUtilities: "doc.text.viewfinder"
        case .cloudItems: "cloud"
        case .similarImages: "square.stack.3d.down.right"
        case .largeFiles: "scalemass"
        case .diskTraces: "eye.slash"
        case .protectedOnDisk: "lock.shield"
        }
    }
}

/// Les sections de la barre latérale.
public enum AppSection: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case overview
    case advice
    case timeMachine
    case transfer
    case developer
    /// Archiver les projets inactifs sur un disque externe (phase 2).
    case archive
    case explorer
    /// Gros et vieux fichiers, tirés de l'arborescence de l'Explorateur (phase 2).
    case largeFiles
    case duplicates
    /// La photothèque, par PhotoKit : vidéos, captures, doublons, similaires.
    case photos
    /// Les nuages (iCloud Drive, Google Drive…) d'après les fichiers fantômes
    /// laissés sur ce Mac, sans jamais se connecter à un compte.
    case clouds
    /// Le désinstalleur, restes compris (phase 2).
    case applications
    case browsers
    case system
    case history
    case cart

    public var id: String { rawValue }
    public var localizationKey: String { "section.\(rawValue)" }

    public var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .advice: "lightbulb"
        case .timeMachine: "clock.arrow.circlepath"
        case .transfer: "externaldrive.badge.plus"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .archive: "tray.and.arrow.down"
        case .explorer: "list.bullet.indent"
        case .largeFiles: "scalemass"
        case .duplicates: "doc.on.doc"
        case .applications: "square.grid.2x2"
        case .photos: "photo.on.rectangle.angled"
        case .clouds: "cloud"
        case .browsers: "globe"
        case .system: "internaldrive"
        case .history: "clock"
        // La corbeille d'Oust! : on y jette ce qui doit partir (remarque de Romain,
        // 18/10/2026 : « c'est une corbeille, pas un panier »). Celle du Mac
        // garde un symbole à elle, `trash.square`, pour qu'on ne les confonde pas.
        case .cart: "trash"
        }
    }
}

/// Pourquoi un élément ne peut pas être sélectionné.
public enum ProtectionReason: Sendable, Hashable, Codable {
    /// Un processus a son dossier courant dedans (agent, compilation, éditeur).
    case activeProcess(name: String)
    /// Des modifications git non commitées seraient perdues.
    case uncommittedChanges(count: Int)
    /// Un verrou git (`git worktree lock`, `index.lock`).
    case gitLocked
    /// Des fichiers ignorés par git qui n'existent nulle part ailleurs (`.env`, clés).
    case uniqueIgnoredFiles([String])
    /// L'application propriétaire est ouverte (navigateur).
    case appRunning(name: String)
    /// Utilisé dans les dernières 24 heures (session d'agent en cours).
    case inUse
    /// La version la plus récente est gardée (DeviceSupport, sauvegarde iOS).
    case newestKept
    /// Simulateur démarré.
    case booted
    /// Lisible seulement avec l'Accès complet au disque.
    case needsFullDiskAccess
    /// Emplacement que la garde de chemins refuse.
    case systemPath
    /// Un démon de l'outil tourne (Gradle).
    case daemonRunning(name: String)
    /// L'état n'a pas pu être établi : dans le doute, on protège.
    case unknownState
    /// Une autre application installée s'en sert aussi (second exemplaire, suite
    /// qui partage un groupe) : ce n'est pas un reste.
    case usedByAnotherApp(name: String)
    /// Fait partie d'un paquet (application, bibliothèque Photos, projet) : le
    /// retirer seul abîmerait le paquet.
    case insidePackage(name: String)
    /// La version active ou par défaut de l'outil (`xcode-select -p`,
    /// `nvm alias default`, `pyenv global`, `rustup default`) : toujours gardée.
    case activeVersion
    /// Le reste d'une application disparue, alors qu'une application proche est
    /// installée (même éditeur, même équipe, son nom dans l'identifiant) : elle
    /// s'en sert peut-être (une suite, un identifiant changé d'une version à l'autre).
    case relatedAppInstalled(name: String)
    /// Le reste d'une application disparue a été modifié il y a moins de N
    /// jours : une application disparue n'écrit plus, quelque chose s'en sert.
    case recentlyWritten(days: Int)
    /// Un favori de Photos : choisi par l'utilisateur, jamais proposé.
    case photoFavorite
    /// Dans un album partagé ou la photothèque partagée d'iCloud : le supprimer
    /// le retirerait aussi chez les autres participants.
    case photoShared
    /// Masqué dans Photos : on ne propose pas ce qu'on n'a pas montré.
    case photoHidden
    /// Une sauvegarde Time Machine : seul Time Machine la gère.
    case timeMachine
    /// Une photothèque qui n'est pas celle du système : PhotoKit ne la voit pas,
    /// seule l'app Photos, en l'ouvrant, saurait la trier.
    case photoLibrary
    /// Une machine virtuelle rangée sur un autre disque : elle y est à sa place.
    case virtualMachine
    /// Le disque est en lecture seule (NTFS, image verrouillée) : rien ne peut en partir.
    case readOnlyVolume
    /// L'app du service de cloud est fermée : macOS a déconnecté le compte, et
    /// rien n'y est supprimé sans elle (essai du 18/10/2026).
    case cloudAppClosed(name: String)
    /// Le compte de cloud n'est plus relié à son service : macOS refuse d'en
    /// identifier les fichiers, et le Finder de les mettre à la corbeille.
    case cloudDisconnected

    public var localizationKey: String {
        switch self {
        case .activeProcess: "protection.activeProcess"
        case .uncommittedChanges: "protection.uncommittedChanges"
        case .gitLocked: "protection.gitLocked"
        case .uniqueIgnoredFiles: "protection.uniqueIgnoredFiles"
        case .appRunning: "protection.appRunning"
        case .inUse: "protection.inUse"
        case .newestKept: "protection.newestKept"
        case .booted: "protection.booted"
        case .needsFullDiskAccess: "protection.needsFullDiskAccess"
        case .systemPath: "protection.systemPath"
        case .daemonRunning: "protection.daemonRunning"
        case .unknownState: "protection.unknownState"
        case .usedByAnotherApp: "protection.usedByAnotherApp"
        case .insidePackage: "protection.insidePackage"
        case .activeVersion: "protection.activeVersion"
        case .relatedAppInstalled: "protection.relatedAppInstalled"
        case .recentlyWritten: "protection.recentlyWritten"
        case .photoFavorite: "protection.photoFavorite"
        case .photoShared: "protection.photoShared"
        case .photoHidden: "protection.photoHidden"
        case .timeMachine: "protection.timeMachine"
        case .photoLibrary: "protection.photoLibrary"
        case .virtualMachine: "protection.virtualMachine"
        case .readOnlyVolume: "protection.readOnlyVolume"
        case .cloudAppClosed: "protection.cloudAppClosed"
        case .cloudDisconnected: "protection.cloudDisconnected"
        }
    }

    /// L'argument à insérer dans le message (`%@`), s'il y en a un.
    public var argument: String? {
        switch self {
        case .activeProcess(let name), .appRunning(let name), .daemonRunning(let name),
             .usedByAnotherApp(let name), .insidePackage(let name), .relatedAppInstalled(let name),
             .cloudAppClosed(let name): name
        case .uncommittedChanges(let count), .recentlyWritten(let count): String(count)
        case .uniqueIgnoredFiles(let names): names.prefix(3).joined(separator: ", ")
        default: nil
        }
    }
}

/// Une information utile qui n'empêche pas la sélection.
public enum ItemNote: Sendable, Hashable, Codable {
    /// La branche du worktree n'est pas fusionnée (elle est conservée par `git worktree remove`).
    case notMerged
    /// Modifié il y a moins de N jours : affiché mais pas présélectionné.
    case recentlyModified(days: Int)
    /// Le projet d'origine n'existe plus.
    case orphan
    /// Une partie des blocs est partagée avec un clone ou un snapshot.
    case partlyShared
    /// Déjà un clone : supprimer cette copie ne libère rien.
    case alreadyClone
    /// Exclu du total affiché en titre (VM, image Docker).
    case managedSeparately
    /// Un projet demande cette version (`.nvmrc`, `.python-version`,
    /// `rust-toolchain`) : affichée, jamais présélectionnée.
    case usedByProject(name: String)
    /// La version porte des environnements virtuels (pyenv-virtualenv).
    case hasEnvironments(count: Int)
    /// Gain estimé sur un échantillon ; le chiffre réel est mesuré à la fin.
    case estimated
    /// Photos iCloud a évincé l'original de ce Mac (« Optimiser le stockage ») :
    /// le supprimer libère surtout de l'espace iCloud, presque rien ici.
    case photoInCloud
    /// Fichier d'un nuage dont le contenu n'est pas sur ce Mac : le supprimer
    /// libère de la place dans le nuage, rien ici.
    case cloudOnly

    public var localizationKey: String {
        switch self {
        case .notMerged: "note.notMerged"
        case .recentlyModified: "note.recentlyModified"
        case .orphan: "note.orphan"
        case .partlyShared: "note.partlyShared"
        case .alreadyClone: "note.alreadyClone"
        case .managedSeparately: "note.managedSeparately"
        case .usedByProject: "note.usedByProject"
        case .hasEnvironments: "note.hasEnvironments"
        case .estimated: "note.estimated"
        case .photoInCloud: "note.photoInCloud"
        case .cloudOnly: "note.cloudOnly"
        }
    }

    public var argument: String? {
        switch self {
        case .recentlyModified(let days): String(days)
        case .usedByProject(let name): name
        case .hasEnvironments(let count): String(count)
        default: nil
        }
    }
}

/// Ce que coûte le retour de l'élément après suppression.
public enum RebuildCost: Sendable, Hashable, Codable {
    /// Rien à reconstruire (journaux, fichiers temporaires).
    case nothing
    /// L'outil le recrée de lui-même au prochain usage.
    case automatic
    /// Une commande à relancer, avec une durée indicative.
    case command(String, minutes: Int?)
    /// Un nouveau téléchargement (modèle, runtime de simulateur).
    case download
    /// Ne reviendra pas : seule la corbeille permet de revenir en arrière.
    case irreversible
    /// Récupérable dans « Supprimés récemment » de Photos pendant 30 jours,
    /// puis plus jamais.
    case photosRecentlyDeleted
    /// Récupérable depuis la corbeille du Mac, puis selon le service (la
    /// corbeille d'iCloud Drive ou de Google Drive en ligne).
    case cloudTrash
}
