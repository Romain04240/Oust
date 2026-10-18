import Foundation

/// Les gestionnaires de versions dont Oust! appelle la commande de
/// désinstallation (RULES.md, règle 6 : une commande d'outil plutôt qu'un `rm`).
///
/// nvm n'y figure pas : c'est une fonction du shell, pas un exécutable, et
/// l'appeler voudrait dire faire interpréter une ligne de commande. Sa
/// désinstallation se résume d'ailleurs à retirer le dossier de la version.
public enum VersionTool: String, Sendable, Hashable, Codable, CaseIterable {
    case pyenv
    case rustup

    /// Le nom attendu de l'exécutable, revérifié juste avant de le lancer.
    public var executableName: String { rawValue }

    /// La variable d'environnement qui désigne son dossier.
    public var rootVariable: String {
        switch self {
        case .pyenv: "PYENV_ROOT"
        case .rustup: "RUSTUP_HOME"
        }
    }
}

/// Ce que Docker ou OrbStack retire à la demande d'Oust!.
///
/// Les volumes n'y sont pas, à dessein : ils portent les données des bases et
/// des services, et rien dans `docker system df` ne dit lesquels sont jetables.
public enum PruneScope: String, Sendable, Hashable, Codable, CaseIterable {
    /// `docker builder prune -f` : le cache de construction.
    case buildCache
    /// `docker image rm <références>` : les images qu'aucun conteneur n'utilisait
    /// à l'analyse. Sans `-f` : Docker refuse celles qui servent entre-temps.
    case unusedImages
    /// `docker container rm <identifiants>` : les conteneurs arrêtés à l'analyse.
    /// Sans `-f` : Docker refuse ceux qui ont redémarré. Un `prune` emporterait
    /// aussi ceux qu'on a arrêtés depuis, avec ce qu'on y a écrit.
    case stoppedContainers

    /// Les arguments de la CLI. Seuls des identifiants relevés à l'analyse et
    /// revalidés (`isPlainReference`) s'y ajoutent.
    public func arguments(ids: [String]) -> [String] {
        switch self {
        case .buildCache: ["builder", "prune", "-f"]
        case .unusedImages: ["image", "rm"] + ids
        case .stoppedContainers: ["container", "rm"] + ids
        }
    }

    /// Un identifiant ou une référence d'image (`alpine:3.20`, `ghcr.io/x/y:1`,
    /// `sha256:…`) : jamais une option, jamais un espace.
    public static func isPlainReference(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first.isNumber, text.count <= 256 else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:/@-".contains($0)) }
    }
}

/// Les grandes familles de méthodes, pour filtrer une liste sans entrer dans le
/// détail de chaque outil.
public enum MethodFamily: String, Sendable, Hashable, Codable, CaseIterable {
    /// Supprimé tout de suite : le régénérable.
    case immediate
    /// Mis dans la corbeille du Mac, restaurable.
    case macTrash
    /// Confié à l'outil qui sait faire (git, simctl, tmutil, pyenv, brew, docker…).
    case tool
    /// Libère de la place sans rien supprimer : clone, éviction, compression.
    case keepsFiles
    /// Montré pour information ; à faire soi-même.
    case manual

    public var localizationKey: String { "family.\(rawValue)" }
}

extension CleanupMethod {
    public var family: MethodFamily {
        switch self {
        case .removeNow: .immediate
        // L'archivage copie sur un disque externe, puis met l'original dans la corbeille du Mac.
        case .trash, .archive: .macTrash
        // Un fichier d'un nuage passe lui aussi par la corbeille du Mac.
        case .trashFromCloud: .macTrash
        case .gitWorktreeRemove, .simulatorDevice, .simulatorRuntime, .localSnapshot, .firefoxHistory,
             .uninstallVersion, .brewCleanup, .containerPrune, .timeMachineBackup: .tool
        // Photos supprime lui-même, après sa propre confirmation.
        case .photoAsset: .tool
        case .cloneOf, .evictLocalCopy, .compressInPlace: .keepsFiles
        case .manual: .manual
        }
    }
}
