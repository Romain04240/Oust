import Foundation
import OustCore

/// Une application installée, telle qu'Oust! la lit dans son paquet.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    /// Le nom que le Finder affiche (jamais traduit par Oust!).
    public let name: String
    public let bundleID: String?
    public let version: String?
    /// Les identifiants des paquets embarqués (extensions, assistants, XPC) :
    /// leurs conteneurs et préférences appartiennent aussi à l'application.
    public let embeddedIDs: [String]
    /// Les groupes d'applications déclarés dans sa signature
    /// (`com.apple.security.application-groups`).
    public let applicationGroups: [String]
    /// Les noms sous lesquels l'application range ses affaires, s'ils sont sûrs.
    public let names: [String]
    public let isAppStore: Bool
    public let fileID: UInt64
    public let modificationDate: Date?
    /// Dernière ouverture selon Spotlight (`kMDItemLastUsedDate`), quand il le sait.
    public let lastUsed: Date?
    public var sizes: Sizes
    /// Pourquoi Oust! refuse de la désinstaller, s'il y a une raison.
    public var exclusion: AppExclusion?

    public init(url: URL, name: String, bundleID: String?, version: String? = nil, embeddedIDs: [String] = [],
                applicationGroups: [String] = [], names: [String] = [], isAppStore: Bool = false,
                fileID: UInt64 = 0, modificationDate: Date? = nil, lastUsed: Date? = nil, sizes: Sizes = .zero,
                exclusion: AppExclusion? = nil) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.embeddedIDs = embeddedIDs
        self.applicationGroups = applicationGroups
        self.names = names
        self.isAppStore = isAppStore
        self.fileID = fileID
        self.modificationDate = modificationDate
        self.lastUsed = lastUsed
        self.sizes = sizes
        self.exclusion = exclusion
    }

    /// Désinstallable par Oust!.
    public var isUninstallable: Bool { exclusion == nil }

    /// Une date absente ne permet pas de conclure que l'application est inutilisée.
    public func wasLastOpened(before cutoff: Date) -> Bool {
        lastUsed.map { $0 < cutoff } ?? false
    }

    /// Tous les identifiants qui désignent cette application.
    public var allIDs: [String] {
        (bundleID.map { [$0] } ?? []) + embeddedIDs
    }
}

/// Ce qu'Oust! ne désinstalle jamais, et pourquoi.
///
/// Une application d'Apple fait partie du système ; un gestionnaire de mots de
/// passe ou un VPN laisse derrière lui des trousseaux, des extensions réseau et
/// des réglages de sécurité qu'aucune corbeille ne remet en place. Ceux-là se
/// désinstallent avec l'outil de leur éditeur.
public enum AppExclusion: String, Sendable, Hashable, Codable, CaseIterable {
    case apple
    case passwordManager
    case vpn
    /// Une extension système (sécurité, pilote) : son éditeur fournit un désinstalleur.
    case systemExtension
    /// Pas d'identifiant de bundle lisible : dans le doute, on ne touche pas.
    case unidentified

    public var localizationKey: String { "uninstall.exclusion.\(rawValue)" }
}
