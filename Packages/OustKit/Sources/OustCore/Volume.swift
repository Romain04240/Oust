import Foundation

/// La capacité d'un volume, telle que macOS la décrit de trois façons.
///
/// Le 18/10/2026, `df` annonçait 65 Go libres et le Finder 305 Go : la
/// différence, « purgeable », était surtout faite de snapshots Time Machine
/// locaux. Oust! montre les deux chiffres et dit d'où vient l'écart.
public struct Capacity: Sendable, Hashable, Codable {
    public var total: Int64
    /// Libre réel, comme `df` (`volumeAvailableCapacity`).
    public var available: Int64
    /// Libre en comptant ce que le système peut purger, comme le Finder.
    public var availableForImportantUsage: Int64

    public init(total: Int64, available: Int64, availableForImportantUsage: Int64) {
        self.total = max(0, total)
        self.available = min(self.total, max(0, available))
        self.availableForImportantUsage = min(self.total, max(self.available, availableForImportantUsage))
    }

    public var used: Int64 { max(0, total - available) }
    /// Occupé hors purgeable, pour que les parts affichées s'additionnent au total.
    public var occupied: Int64 { max(0, total - availableForImportantUsage) }
    public var occupiedFraction: Double { total > 0 ? Double(occupied) / Double(total) : 0 }
    public var purgeable: Int64 { max(0, availableForImportantUsage - available) }

    /// Part utilisée, de 0 à 1.
    public var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }
}

/// Un volume que l'utilisateur peut analyser.
public struct VolumeDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var id: String { mountURL.path }
    public var name: String
    public var mountURL: URL
    /// Où commence le parcours. Pour le disque de démarrage, c'est
    /// `/System/Volumes/Data` : partir de `/` ferait suivre les firmlinks et
    /// compter les données deux fois.
    public var scanRoot: URL
    public var isBoot: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var capacity: Capacity

    public init(name: String, mountURL: URL, scanRoot: URL, isBoot: Bool, isInternal: Bool,
                isRemovable: Bool, capacity: Capacity) {
        self.name = name
        self.mountURL = mountURL
        self.scanRoot = scanRoot
        self.isBoot = isBoot
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.capacity = capacity
    }

    public var symbol: String {
        if isBoot { return "internaldrive.fill" }
        return isInternal ? "internaldrive" : "externaldrive.fill"
    }
}

/// Un snapshot APFS local.
public struct LocalSnapshot: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    /// `AAAA-MM-JJ-HHMMSS` pour un snapshot Time Machine, sinon `nil`.
    public var date: String?
    public var transactionID: UInt64?
    /// Blocs propres à ce seul snapshot, lus auprès d'APFS.
    public var privateBytes: Int64?

    public init(name: String) {
        self.name = name
        self.date = LocalSnapshot.timeMachineDate(in: name)
    }

    /// Seuls les snapshots Time Machine sont supprimables. Ceux du système
    /// (`com.apple.os.update-…`) servent aux mises à jour et ne se touchent pas.
    public var isDeletable: Bool { date != nil }

    public var creationDate: Date? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: date)
    }

    /// Extrait et valide la date d'un nom `com.apple.TimeMachine.AAAA-MM-JJ-HHMMSS.local`.
    ///
    /// La validation est stricte parce que cette chaîne finit dans une commande
    /// exécutée en administrateur : rien d'autre que des chiffres et des tirets
    /// à leur place (RULES.md, règle 7).
    public static func timeMachineDate(in name: String) -> String? {
        let prefix = "com.apple.TimeMachine."
        guard name.hasPrefix(prefix) else { return nil }
        var rest = name.dropFirst(prefix.count)
        if rest.hasSuffix(".local") { rest = rest.dropLast(".local".count) }
        let candidate = String(rest)
        return isValidDate(candidate) ? candidate : nil
    }

    public static func isValidDate(_ value: String) -> Bool {
        let shape = Array("dddd-dd-dd-dddddd")
        let chars = Array(value)
        guard chars.count == shape.count else { return false }
        for (char, expected) in zip(chars, shape) {
            if expected == "d" {
                guard char.isASCII, char.isNumber else { return false }
            } else if char != expected {
                return false
            }
        }
        return true
    }
}
