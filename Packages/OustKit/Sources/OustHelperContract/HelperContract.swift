import Foundation

/// Le contrat entre Oust! et son démon privilégié (docs/adr/0001).
///
/// Volontairement minuscule, comme celui de Tacho : deux verbes qui agissent
/// (snapshots locaux, sauvegardes d'un disque Time Machine), un verbe qui
/// renseigne. Le démon n'a ni état, ni réglages, ni base, ni réseau. On
/// demande à quelqu'un d'installer un composant qui tourne en root : il doit
/// pouvoir le lire en entier en dix minutes.
///
/// Ce module ne dépend que de Foundation : le démon le lie seul, sans emporter
/// le reste d'OustKit.
public enum HelperContract {

    /// L'application, seule cliente admise.
    public static let appIdentifier = "fr.meaillais.oust"

    /// Le démon : étiquette launchd, identifiant de signature et service Mach.
    public static let daemonIdentifier = "fr.meaillais.oust.helper"
    public static let machServiceName = daemonIdentifier

    /// Le plist que `SMAppService` cherche dans `Contents/Library/LaunchDaemons`.
    public static let daemonPlistName = "fr.meaillais.oust.helper.plist"

    /// L'équipe qui signe l'un et l'autre, en développement comme en Developer ID.
    ///
    /// Écrite en dur, et non lue dans la signature du processus comme le fait
    /// Tacho : un démon re-signé par quelqu'un d'autre lirait sa propre équipe
    /// et ferait confiance à la mauvaise.
    public static let teamIdentifier = "H3W3XYM2NZ"

    /// La version du contrat. L'application l'envoie avec chaque demande, et un
    /// démon d'une autre version refuse sans rien faire : l'application reprend
    /// alors l'invite administrateur. Le cas arrive pour de vrai quand l'app est
    /// remplacée pendant que l'ancien démon tourne encore.
    ///
    /// 2 : le verbe des sauvegardes Time Machine (18/10/2026). Un démon de la
    /// version 1 ne le connaît pas : l'application lit sa version avant de le
    /// lui demander, ne lui envoie rien s'il n'est pas à jour, et l'invite
    /// administrateur prend le relais jusqu'à ce qu'on le réinstalle.
    public static let version = 2

    /// Au-delà, la demande est refusée en bloc. Time Machine garde une
    /// vingtaine de snapshots horaires : soixante-quatre laisse de la marge sans
    /// laisser un appelant faire tourner `tmutil` sans fin.
    public static let maximumSnapshotsPerRequest = 64

    /// Ce que le démon exige de qui l'appelle : Oust!, signé par son équipe.
    public static let clientRequirement = requirement(identifier: appIdentifier)

    /// Ce que l'application exige du démon, en retour : qu'on ne lui ait pas
    /// substitué un autre programme sous le même nom de service.
    public static let daemonRequirement = requirement(identifier: daemonIdentifier)

    /// `anchor apple generic` : une chaîne qui remonte à l'autorité d'Apple.
    /// `certificate leaf[subject.OU]` : un certificat de l'équipe, qu'il soit
    /// « Apple Development » (Debug) ou « Developer ID Application » (Release).
    /// Une copie signée ad hoc, ou par quelqu'un d'autre, n'y satisfait pas.
    static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Les clés des dictionnaires échangés : des types property-list, et rien
    /// d'autre, pour ne pas avoir à faire coïncider deux définitions de classe
    /// de part et d'autre d'une frontière de processus.
    public enum Key {
        public static let contractVersion = "contract_version"
        public static let helperVersion = "helper_version"
        public static let refusal = "refusal"
        public static let results = "results"
        public static let date = "date"
        public static let outcome = "outcome"
        public static let message = "message"
    }
}

/// Ce que le démon a fait d'une date demandée.
public enum SnapshotOutcome: String, Sendable, CaseIterable {
    /// `tmutil` a confirmé, et le snapshot n'est plus listé.
    case deleted
    /// Pas exactement au format `AAAA-MM-JJ-HHMMSS` : jamais transmis à `tmutil`.
    case malformed
    /// Aucun snapshot `com.apple.TimeMachine.<date>.local` sur le volume de données.
    case notListed = "not_listed"
    /// `tmutil` a échoué, ou le snapshot est encore là après coup.
    case failed
}

/// Pourquoi le démon refuse une demande entière, sans rien avoir fait.
public enum RequestRefusal: String, Sendable, CaseIterable {
    case contractMismatch = "contract_mismatch"
    case empty
    case tooMany = "too_many"
    /// La liste des snapshots n'a pas pu être lue : rien n'est comparable.
    case listingFailed = "listing_failed"
    /// Ce point de montage n'est pas, à l'instant, celui d'une destination
    /// Time Machine branchée sur ce Mac.
    case unknownDestination = "unknown_destination"
    /// Time Machine sauvegarde en ce moment, ou son état est illisible : on
    /// ne supprime rien pendant qu'il écrit peut-être sur le disque.
    case backupRunning = "backup_running"
}
