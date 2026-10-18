import Foundation

/// Les verbes du démon, et eux seuls (RULES.md, règle 7).
///
/// Chaque verbe est typé : aucun ne reçoit une commande, un chemin ou un nom
/// d'outil. Un sélecteur absent de ce protocole n'est jamais exécuté : NSXPC
/// rejette le message avant qu'il n'atteigne le démon, et les tests vérifient
/// que ce protocole ne compte que ces trois verbes.
@objc public protocol OustHelperProtocol {

    /// Supprime les snapshots Time Machine locaux de ces dates, et rien d'autre.
    ///
    /// Le démon revalide chaque date (format exact, présence d'un snapshot
    /// `com.apple.TimeMachine.<date>.local` sur le volume de données) avant de
    /// la passer à `/usr/bin/tmutil deletelocalsnapshots`. La réponse est un
    /// `DeletionResponse` encodé : ce qui a été fait, date par date.
    func deleteLocalSnapshots(_ dates: [String], contractVersion: Int,
                              withReply reply: @escaping @Sendable (NSDictionary) -> Void)

    /// Supprime ces sauvegardes du disque Time Machine monté à `destination`,
    /// et rien d'autre (Romain, 18/10/2026).
    ///
    /// Le démon relit tout lui-même avant d'agir : `destination` doit avoir la
    /// forme `/Volumes/<nom>` **et** figurer à l'instant parmi les destinations
    /// locales de `tmutil destinationinfo` ; aucune sauvegarde ne doit être en
    /// cours ; chaque horodatage doit avoir la forme exacte, désigner une
    /// sauvegarde terminée de cette destination, et ne pas être la plus
    /// récente. Ce n'est qu'alors qu'il part, seul et sans shell, à
    /// `/usr/bin/tmutil delete -d <destination> -t <horodatage>`. La réponse
    /// est un `BackupDeletionResponse` encodé, horodatage par horodatage.
    func deleteBackups(_ timestamps: [String], destination: String, contractVersion: Int,
                       withReply reply: @escaping @Sendable (NSDictionary) -> Void)

    /// La version du contrat et celle du démon, pour les Réglages. Ne fait
    /// rien d'autre.
    func readStatus(withReply reply: @escaping @Sendable (NSDictionary) -> Void)
}

public enum HelperInterface {

    /// L'interface XPC, avec les seules classes admises à traverser la
    /// frontière : des tableaux de chaînes et une chaîne à l'aller, des
    /// dictionnaires de property-list au retour.
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: (any OustHelperProtocol).self)
        let delete = #selector((any OustHelperProtocol).deleteLocalSnapshots(_:contractVersion:withReply:))
        let backups = #selector((any OustHelperProtocol).deleteBackups(_:destination:contractVersion:withReply:))
        let status = #selector((any OustHelperProtocol).readStatus(withReply:))
        interface.setClasses(classes(NSArray.self, NSString.self), for: delete, argumentIndex: 0, ofReply: false)
        interface.setClasses(classes(NSArray.self, NSString.self), for: backups, argumentIndex: 0, ofReply: false)
        interface.setClasses(classes(NSString.self), for: backups, argumentIndex: 1, ofReply: false)
        let reply = classes(NSDictionary.self, NSArray.self, NSString.self, NSNumber.self)
        interface.setClasses(reply, for: delete, argumentIndex: 0, ofReply: true)
        interface.setClasses(reply, for: backups, argumentIndex: 0, ofReply: true)
        interface.setClasses(reply, for: status, argumentIndex: 0, ofReply: true)
        return interface
    }

    /// Un ensemble vide si le pont échouait : aucune classe admise, donc aucun
    /// message décodé. L'échec se fait du côté sûr.
    private static func classes(_ types: AnyClass...) -> Set<AnyHashable> {
        NSSet(array: types) as? Set<AnyHashable> ?? []
    }
}

/// Ce que le démon a fait d'une demande de suppression.
public struct DeletionResponse: Sendable, Equatable {

    public struct Result: Sendable, Equatable {
        public var date: String
        public var outcome: SnapshotOutcome
        public var message: String?

        public init(date: String, outcome: SnapshotOutcome, message: String? = nil) {
            self.date = date
            self.outcome = outcome
            self.message = message
        }
    }

    /// Non nil : la demande entière a été refusée, et rien n'a été fait.
    public var refusal: RequestRefusal?
    public var results: [Result]

    public init(refusal: RequestRefusal? = nil, results: [Result] = []) {
        self.refusal = refusal
        self.results = results
    }

    public static func refused(_ reason: RequestRefusal) -> DeletionResponse {
        DeletionResponse(refusal: reason)
    }

    /// Toutes ces dates ont été supprimées, sans exception.
    public func deletedAll(_ dates: [String]) -> Bool {
        guard refusal == nil, !dates.isEmpty else { return false }
        let deleted = Set(results.filter { $0.outcome == .deleted }.map(\.date))
        return dates.allSatisfy(deleted.contains)
    }

    public var dictionary: NSDictionary {
        var payload: [String: Any] = [HelperContract.Key.contractVersion: HelperContract.version]
        if let refusal { payload[HelperContract.Key.refusal] = refusal.rawValue }
        payload[HelperContract.Key.results] = results.map { result -> [String: Any] in
            var entry: [String: Any] = [HelperContract.Key.date: result.date,
                                        HelperContract.Key.outcome: result.outcome.rawValue]
            if let message = result.message { entry[HelperContract.Key.message] = message }
            return entry
        }
        return payload as NSDictionary
    }

    /// Relit une réponse ; nil si elle n'a pas la forme attendue, ou vient d'un
    /// contrat d'une autre version. Une réponse illisible n'est jamais lue
    /// comme un succès.
    public init?(dictionary: NSDictionary) {
        guard let payload = dictionary as? [String: Any],
              payload[HelperContract.Key.contractVersion] as? Int == HelperContract.version
        else { return nil }
        if let raw = payload[HelperContract.Key.refusal] {
            guard let text = raw as? String, let reason = RequestRefusal(rawValue: text) else { return nil }
            refusal = reason
        } else {
            refusal = nil
        }
        guard let entries = payload[HelperContract.Key.results] as? [[String: Any]] else { return nil }
        var decoded: [Result] = []
        for entry in entries {
            guard let date = entry[HelperContract.Key.date] as? String,
                  let raw = entry[HelperContract.Key.outcome] as? String,
                  let outcome = SnapshotOutcome(rawValue: raw) else { return nil }
            decoded.append(Result(date: date, outcome: outcome, message: entry[HelperContract.Key.message] as? String))
        }
        results = decoded
    }
}

/// L'état du démon, tel qu'il le décrit lui-même.
public struct HelperStatus: Sendable, Equatable {
    public var contractVersion: Int
    public var helperVersion: String

    public init(contractVersion: Int = HelperContract.version, helperVersion: String) {
        self.contractVersion = contractVersion
        self.helperVersion = helperVersion
    }

    public var dictionary: NSDictionary {
        [HelperContract.Key.contractVersion: contractVersion,
         HelperContract.Key.helperVersion: helperVersion] as NSDictionary
    }

    public init?(dictionary: NSDictionary) {
        guard let payload = dictionary as? [String: Any],
              let contract = payload[HelperContract.Key.contractVersion] as? Int,
              let version = payload[HelperContract.Key.helperVersion] as? String else { return nil }
        contractVersion = contract
        helperVersion = version
    }
}
