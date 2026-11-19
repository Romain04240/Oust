import Darwin
import Foundation

/// Une vue partielle du registre déclaré, sans preuve d'existence ni objet de nettoyage.
public enum LoginSessionInventory: Equatable, Sendable {
    case unavailable
    case partial([Entry])

    public enum Kind: Equatable, Sendable {
        case application
        case component
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let kind: Kind
        public let isEnabled: Bool?
        public let isAllowed: Bool?

        public init(id: UUID, name: String, kind: Kind, isEnabled: Bool?, isAllowed: Bool?) {
            self.id = id
            self.name = name
            self.kind = kind
            self.isEnabled = isEnabled
            self.isAllowed = isAllowed
        }
    }

    static func parse(_ output: String, uid: uid_t) -> Self {
        var targetSections = 0
        var inTarget = false
        var invalidHeader = false
        var record: Record?
        var records: [Record] = []
        func finishRecord() {
            if let record { records.append(record) }
            record = nil
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = (raw.hasSuffix("\r") ? raw.dropLast() : raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                finishRecord()
                inTarget = false
                guard line.hasPrefix("Records for UID ") else { continue }
                let parts = line.dropFirst("Records for UID ".count)
                    .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                inTarget = parts.first?.trimmingCharacters(in: .whitespaces) == String(uid)
                if inTarget {
                    targetSections += 1
                    if parts.count != 2 || UUID(uuidString: parts[1].trimmingCharacters(in: .whitespaces)) == nil {
                        invalidHeader = true
                    }
                }
                continue
            }
            guard inTarget else { continue }
            if line.hasPrefix("#") {
                finishRecord()
                if line.hasSuffix(":"), let number = Int(line.dropFirst().dropLast()), number >= 0 {
                    record = Record()
                }
            } else if record != nil, let separator = line.firstIndex(of: ":") {
                let key = String(line[..<separator])
                guard Record.keys.contains(key) else { continue }
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                if key == "UUID", let id = UUID(uuidString: value) { record?.ids.insert(id) }
                if record?.fields[key] != nil { record?.ambiguous = true }
                record?.fields[key] = value
            }
        }
        finishRecord()
        guard targetSections == 1, !invalidHeader else { return .unavailable }

        // Une deuxième inscription incompatible ne choisit jamais arbitrairement
        // la première : toutes les représentations de cette identité sont écartées.
        var entries: [UUID: Entry] = [:]
        var identities: [UUID: [String: String]] = [:]
        var rejected = Set<UUID>()
        for record in records {
            guard !record.ambiguous, let entry = record.entry else {
                rejected.formUnion(record.ids)
                continue
            }
            if let previous = identities[entry.id], previous != record.fields { rejected.insert(entry.id) }
            else { entries[entry.id] = entry; identities[entry.id] = record.fields }
        }
        return .partial(entries.values.filter { !rejected.contains($0.id) }.sorted {
            if $0.name == $1.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    private struct Record {
        static let keys: Set<String> = ["UUID", "Name", "Type", "Disposition", "URL", "Identifier"]
        var fields: [String: String] = [:]
        var ids = Set<UUID>()
        var ambiguous = false

        var entry: Entry? {
            let kind: Kind
            switch fields["Type"] {
            case "user item (0x1)": kind = .application
            case "login item (0x4)": kind = .component
            default: return nil
            }
            guard let id = fields["UUID"].flatMap(UUID.init(uuidString:)),
                  let name = fields["Name"], !name.isEmpty, name != "(null)", validText(name),
                  !name.contains("/"), !name.contains("\\"), !name.contains(":"),
                  let target = fields["URL"].flatMap({ localApplicationPath($0, allowRelative: kind == .component) }) else { return nil }
            if kind == .application, let identifier = fields["Identifier"] {
                guard identifier.hasPrefix("file:"), localApplicationPath(identifier) == target else { return nil }
            }
            let states = disposition(fields["Disposition"])
            return Entry(id: id, name: name, kind: kind, isEnabled: states.0, isAllowed: states.1)
        }
    }

    private static func validText(_ value: String) -> Bool {
        !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                || $0.properties.generalCategory == .format
        }
    }

    /// Les composants peuvent déclarer une cible relative : elle ne se résout
    /// jamais ici, pas même à partir du contenant enregistré dans BTM.
    private static func localApplicationPath(_ value: String, allowRelative: Bool = false) -> String? {
        guard validText(value), !value.contains("\\") else { return nil }
        let path: String
        if value.hasPrefix("/") || (allowRelative && !value.contains(":")) { path = value }
        else {
            guard let url = URLComponents(string: value), url.scheme == "file", (url.host ?? "").isEmpty,
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/") else { return nil }
            path = url.path
        }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        let components = normalized.hasPrefix("/") ? parts.dropFirst() : parts[...]
        guard normalized.hasPrefix("/") || allowRelative,
              normalized.lowercased().hasSuffix(".app"), validText(normalized),
              let leaf = components.last, leaf.count > 4,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return normalized
    }

    private static func disposition(_ value: String?) -> (Bool?, Bool?) {
        guard let value, value.hasPrefix("["), let closing = value.firstIndex(of: "]") else { return (nil, nil) }
        let suffix = value[value.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || (suffix.hasPrefix("(0x") && suffix.hasSuffix(")")
            && UInt64(suffix.dropFirst(3).dropLast(), radix: 16) != nil) else { return (nil, nil) }
        let tokens = value[value.index(after: value.startIndex)..<closing]
            .split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let recognized: Set<String> = ["enabled", "disabled", "allowed", "disallowed", "notified", "not notified", "visible", "not visible"]
        guard tokens.allSatisfy({ recognized.contains($0) }) else { return (nil, nil) }
        let flags = Set(tokens)
        func axis(_ yes: String, _ no: String) -> Bool? {
            guard flags.contains(yes) != flags.contains(no) else { return nil }
            return flags.contains(yes)
        }
        return (axis("enabled", "disabled"), axis("allowed", "disallowed"))
    }
}
