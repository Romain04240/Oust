import Foundation

/// Les sauvegardes Time Machine d'un disque de destination, telles que
/// l'application les montre et que le démon les admet (Romain, 18/10/2026 :
/// « dégager les plus anciennes et garder les deux ou trois dernières »).
///
/// Ici, et non dans OustVolume, parce que l'application et le démon doivent
/// lire les sorties de `tmutil` de la même façon : un horodatage que l'une
/// propose et que l'autre ne reconnaîtrait pas serait refusé, et l'inverse
/// serait pire. Ne dépend que de Foundation, comme le reste du contrat.
public enum TimeMachineBackups {

    /// Au-delà, la demande est refusée en bloc. Time Machine garde des horaires
    /// sur 24 heures, des quotidiennes sur un mois, puis des hebdomadaires tant
    /// qu'il y a de la place : quelques années tiennent en deux cents.
    /// L'application découpe au-delà.
    public static let maximumPerRequest = 256

    /// `AAAA-MM-JJ-HHMMSS`, exactement comme une date de snapshot local.
    ///
    /// L'horodatage devient un argument de `tmutil delete -t`, lancé en root :
    /// la même validation octet par octet que `SnapshotDates`, sans rien de
    /// plus permissif.
    public static func isValidTimestamp(_ value: String) -> Bool {
        SnapshotDates.isValid(value)
    }

    /// `/Volumes/<nom>`, et rien d'autre.
    ///
    /// Le point de montage devient l'argument de `tmutil delete -d`. Il n'est
    /// admis que s'il figure aussi parmi les destinations que `tmutil
    /// destinationinfo` donne à l'instant ; cette forme-ci écarte d'avance ce
    /// qui ne pourrait pas en être une : `/`, un chemin relatif, `..`, un nom
    /// qui commence par un tiret, un caractère de contrôle, et les guillemets
    /// et barres obliques inverses qu'il faudrait échapper pour l'invite
    /// administrateur. En cas de doute, on refuse plutôt qu'on échappe.
    public static func isPlausibleMountPoint(_ path: String) -> Bool {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return false }
        let name = path.dropFirst(prefix.count)
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != "..",
              !name.hasPrefix("-"), !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar != "/" && scalar != "\"" && scalar != "\\" && scalar != "`"
                && !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
        }
    }

    // MARK: Destinations

    /// Une destination configurée dans Time Machine.
    public struct Destination: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// « Local » pour un disque branché, « Network » pour un partage.
        public var kind: String
        /// Nil quand le disque n'est pas monté.
        public var mountPoint: String?

        public init(id: String, name: String, kind: String, mountPoint: String?) {
            self.id = id
            self.name = name
            self.kind = kind
            self.mountPoint = mountPoint
        }

        /// Un disque branché sur ce Mac, monté, à un point de montage admissible.
        ///
        /// Les destinations réseau sont écartées : une image disque sur un
        /// partage endormi peut faire attendre `statfs` et `tmutil` sans fin,
        /// et Romain n'en a pas. À reprendre si quelqu'un le demande.
        public var isEligible: Bool {
            guard kind == "Local", let mountPoint else { return false }
            return TimeMachineBackups.isPlausibleMountPoint(mountPoint)
        }
    }

    /// Les destinations dans une sortie de `tmutil destinationinfo -X` ; nil si
    /// elle est illisible. Un plist sans destination en rend une liste vide.
    public static func destinations(inDestinationInfo plist: Data) -> [Destination]? {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        else { return nil }
        guard let entries = object["Destinations"] as? [[String: Any]] else {
            return object["Destinations"] == nil ? [] : nil
        }
        return entries.compactMap { entry in
            guard let id = entry["ID"] as? String else { return nil }
            let mount = (entry["MountPoint"] as? String).map(normalized)
            return Destination(id: id, name: entry["Name"] as? String ?? "", kind: entry["Kind"] as? String ?? "",
                               mountPoint: mount)
        }
    }

    /// Les points de montage où l'on peut supprimer des sauvegardes ; nil si
    /// la sortie est illisible.
    public static func eligibleMountPoints(inDestinationInfo plist: Data) -> Set<String>? {
        destinations(inDestinationInfo: plist).map { Set($0.filter(\.isEligible).compactMap(\.mountPoint)) }
    }

    // MARK: Sauvegarde en cours

    /// `Running` dans une sortie de `tmutil status -X` ; nil si illisible.
    ///
    /// Nil se lit comme « en cours » chez tous les appelants : en cas de doute,
    /// on ne supprime pas pendant que Time Machine écrit peut-être sur le disque.
    public static func isRunning(statusPlist: Data) -> Bool? {
        guard let object = try? PropertyListSerialization.propertyList(from: plist(statusPlist), format: nil)
                as? [String: Any],
              let running = object["Running"] else { return nil }
        // Un booléen dans le plist XML ; un nombre ou une chaîne dans d'anciennes versions.
        if let flag = running as? Bool { return flag }
        if let number = running as? NSNumber { return number.intValue != 0 }
        if let text = running as? String, let number = Int(text) { return number != 0 }
        return nil
    }

    /// `tmutil status -X` commence parfois par une ligne d'en-tête : on lit
    /// à partir du plist lui-même.
    private static func plist(_ data: Data) -> Data {
        guard let start = data.firstRange(of: Data("<?xml".utf8)) else { return data }
        return data[start.lowerBound...]
    }

    // MARK: Liste des sauvegardes

    /// Les horodatages des sauvegardes terminées dans une sortie de `tmutil
    /// listbackups`, du plus ancien au plus récent, sans doublon.
    ///
    /// Selon la destination et les options, une ligne est un nom
    /// (`2026-10-18-093012.backup`), un chemin monté (`/Volumes/.timemachine/
    /// <UUID>/2026-10-18-093012.backup/2026-10-18-093012.backup`), un dossier
    /// HFS+ (`/Volumes/Time Machine/Backups.backupdb/Mac/2026-10-18-093012`) ou
    /// l'horodatage seul. Seul le dernier élément compte, et seulement s'il est
    /// exactement un horodatage, suivi au plus de `.backup` : une sauvegarde
    /// interrompue (`.inProgress`, `.interrupted`) ou une ligne d'erreur n'en
    /// est pas une.
    public static func timestamps(inListing output: String) -> [String] {
        var found = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.split(separator: "/").last else { continue }
            var name = String(last)
            if name.hasSuffix(".backup") { name = String(name.dropLast(".backup".count)) }
            if isValidTimestamp(name) { found.insert(name) }
        }
        // L'ordre des chiffres est celui du temps : la forme est fixe.
        return found.sorted()
    }

    /// La plus récente : jamais proposée, jamais supprimée.
    public static func latest(of timestamps: [String]) -> String? {
        timestamps.filter(isValidTimestamp).max()
    }

    /// La date d'un horodatage, à l'heure du Mac, comme Time Machine l'écrit.
    public static func date(of timestamp: String, timeZone: TimeZone = .current) -> Date? {
        guard isValidTimestamp(timestamp) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: timestamp)
    }

    public static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Ce que le démon a fait d'un horodatage demandé.
public enum BackupOutcome: String, Sendable, CaseIterable {
    /// `tmutil` a confirmé, et la sauvegarde n'est plus listée.
    case deleted
    /// Pas exactement au format `AAAA-MM-JJ-HHMMSS` : jamais transmis à `tmutil`.
    case malformed
    /// Aucune sauvegarde terminée de cet horodatage sur cette destination.
    case notListed = "not_listed"
    /// La plus récente de la destination : jamais supprimée.
    case latest
    /// Time Machine a commencé une sauvegarde entre-temps : laissée.
    case backupRunning = "backup_running"
    /// `tmutil` a échoué, ou la sauvegarde est encore là après coup.
    case failed
}

/// Ce que le démon a fait d'une demande de suppression de sauvegardes.
public struct BackupDeletionResponse: Sendable, Equatable {

    public struct Result: Sendable, Equatable {
        public var timestamp: String
        public var outcome: BackupOutcome
        public var message: String?

        public init(timestamp: String, outcome: BackupOutcome, message: String? = nil) {
            self.timestamp = timestamp
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

    public static func refused(_ reason: RequestRefusal) -> BackupDeletionResponse {
        BackupDeletionResponse(refusal: reason)
    }

    public var deleted: Set<String> {
        Set(results.filter { $0.outcome == .deleted }.map(\.timestamp))
    }

    public var dictionary: NSDictionary {
        var payload: [String: Any] = [HelperContract.Key.contractVersion: HelperContract.version]
        if let refusal { payload[HelperContract.Key.refusal] = refusal.rawValue }
        payload[HelperContract.Key.results] = results.map { result -> [String: Any] in
            var entry: [String: Any] = [HelperContract.Key.date: result.timestamp,
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
            guard let timestamp = entry[HelperContract.Key.date] as? String,
                  let raw = entry[HelperContract.Key.outcome] as? String,
                  let outcome = BackupOutcome(rawValue: raw) else { return nil }
            decoded.append(Result(timestamp: timestamp, outcome: outcome,
                                  message: entry[HelperContract.Key.message] as? String))
        }
        results = decoded
    }
}
