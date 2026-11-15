import Compression
import Foundation
import OustCore

/// La dernière arborescence de chaque volume, gardée sur disque pour l'afficher
/// dès l'ouverture et ne relire ensuite que ce qui a changé.
///
/// Un format binaire à soi plutôt que JSON ou un `Codable` : 750 000 dossiers
/// et un million de feuilles sur un disque de 1 To. Des entiers à longueur
/// variable (LEB128), puis une compression LZFSE, faite par le système :
/// 48 Mo ramenés à 17 Mo, en une demi-seconde par `compression_encode_buffer`
/// (2,6 s par `NSData.compressed`, qui travaille par petits morceaux).
public struct TreeStore: Sendable {
    public let directory: URL

    /// Changer ce numéro à chaque évolution du format : un ancien index est alors
    /// ignoré (et le disque reparcouru), jamais mal relu.
    // Les anciennes versions comptaient des fichiers protégés dans les gains.
    static let version: UInt64 = 6
    static let magic = Array("OUSTIDX".utf8)

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Oust/Index`.
    public static func standard() -> TreeStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TreeStore(directory: support.appendingPathComponent("Oust/Index", isDirectory: true))
    }

    /// Un fichier par racine analysée, nommé d'après une empreinte de son chemin.
    func url(for rootPath: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rootPath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "tree-%016llx.oustindex", hash))
    }

    public func save(_ index: ScanIndex) throws {
        guard let preferences = index.preferenceDirectory, index.hasCurrentPreferenceDirectory else { return }
        var writer = BinaryWriter()
        index.encode(into: &writer, preferences: preferences)
        let raw = writer.bytes
        var compressed = [UInt8](repeating: 0, count: raw.count + 4096)
        let length = compression_encode_buffer(&compressed, compressed.count, raw, raw.count, nil, COMPRESSION_LZFSE)
        guard length > 0 else { throw CocoaError(.fileWriteUnknown) }
        var file = Data(Self.magic)
        file.append(UInt8(Self.version))
        withUnsafeBytes(of: UInt64(raw.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(contentsOf: compressed.prefix(length))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Écrit à côté puis renommé : un arrêt brutal laisse l'ancien index, pas
        // un fichier tronqué.
        try file.write(to: url(for: index.rootPath), options: .atomic)
    }

    /// L'index de cette racine, s'il existe et se relit en entier.
    public func load(rootPath: String) -> ScanIndex? {
        let header = Self.magic.count + 1 + 8
        guard let file = try? Data(contentsOf: url(for: rootPath), options: .mappedIfSafe), file.count > header,
              Array(file.prefix(Self.magic.count)) == Self.magic,
              file[file.startIndex + Self.magic.count] == UInt8(Self.version)
        else { return nil }
        let rawLength = file.dropFirst(Self.magic.count + 1).prefix(8).enumerated()
            .reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        // Une longueur absurde trahit un fichier abîmé : on ne réserve pas 1 To.
        guard rawLength > 0, rawLength < 4_000_000_000 else { return nil }
        var raw = [UInt8](repeating: 0, count: Int(rawLength))
        let decoded = file.dropFirst(header).withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&raw, raw.count, base, source.count, nil, COMPRESSION_LZFSE)
        }
        guard decoded == raw.count else { return nil }
        var reader = BinaryReader(raw)
        guard let index = ScanIndex.decode(from: &reader), index.rootPath == rootPath, reader.isAtEnd,
              index.hasCurrentPreferenceDirectory else {
            return nil
        }
        return index
    }

    public func remove(rootPath: String) {
        try? FileManager.default.removeItem(at: url(for: rootPath))
    }
}

// MARK: - Encodage

extension ScanIndex {
    func encode(into writer: inout BinaryWriter, preferences: PreferenceDirectory) {
        writer.string(rootPath)
        writer.unsigned(UInt64(options.threads))
        writer.signed(options.leafThreshold)
        writer.bool(options.measurePrivateSizes)
        writer.strings(options.excludedPaths.sorted())
        writer.strings(options.notableNames.sorted())
        writer.string(options.readOnlyPreferencesDirectory ?? "")
        writer.string(preferences.resolvedPath ?? "")
        writer.bool(preferences.isUncertain)
        writer.bool(preferences.identity != nil)
        if let identity = preferences.identity {
            writer.signed(Int64(identity.device))
            writer.unsigned(identity.inode)
            writer.signed(identity.birthSeconds)
            writer.signed(identity.birthNanoseconds)
        }
        writer.unsigned(eventID)
        writer.string(eventDatabase ?? "")
        writer.date(scannedAt)
        writer.date(fullScanAt)
        writer.strings(skippedVolumes)

        // Les dossiers en préordre : chacun suivi du nombre de ses enfants.
        var stack: [TreeNode] = [root]
        while let node = stack.popLast() {
            writer.string(node.name)
            writer.unsigned(node.fileID)
            writer.status(node.status)
            writer.sizes(node.ownFiles)
            writer.unsigned(UInt64(node.ownFileCount))
            writer.sizes(node.smallFiles)
            writer.unsigned(UInt64(node.smallFileCount))
            writer.date(node.ownLatestModification)
            writer.strings(node.notableFiles)
            writer.unsigned(UInt64(node.files.count))
            for leaf in node.files {
                writer.string(leaf.name)
                writer.sizes(leaf.sizes)
                writer.signed(leaf.logicalSize)
                writer.date(leaf.modified)
                writer.date(leaf.accessed)
                writer.unsigned(leaf.fileID)
                writer.unsigned(leaf.cloneID)
                writer.bool(leaf.isClone)
            }
            writer.unsigned(UInt64(node.children.count))
            // À l'envers sur la pile, pour les relire dans l'ordre.
            stack.append(contentsOf: node.children.reversed())
        }

        for map in [ownership.links, ownership.clones] {
            let entries = map.entries().sorted { $0.key < $1.key }
            writer.unsigned(UInt64(entries.count))
            for entry in entries {
                writer.unsigned(entry.key)
                writer.unsigned(entry.owner)
            }
        }
    }

    static func decode(from reader: inout BinaryReader) -> ScanIndex? {
        guard let rootPath = reader.string(),
              let threads = reader.unsigned(),
              let leafThreshold = reader.signed(),
              let measurePrivateSizes = reader.bool(),
              let excluded = reader.strings(),
              let notable = reader.strings(),
              let readOnlyPreferencesDirectory = reader.string(),
              let resolvedPreferencesDirectory = reader.string(),
              let uncertain = reader.bool(),
              let hasIdentity = reader.bool()
        else { return nil }
        var identity: PreferenceDirectory.Identity?
        if hasIdentity {
            guard let rawDevice = reader.signed(), let device = Int32(exactly: rawDevice),
                  let inode = reader.unsigned(), let birth = reader.signed(), let nanos = reader.signed()
            else { return nil }
            identity = PreferenceDirectory.Identity(device: device, inode: inode, birthSeconds: birth, birthNanoseconds: nanos)
        }
        let preferences = PreferenceDirectory(identity: identity, isUncertain: uncertain,
                                              resolvedPath: resolvedPreferencesDirectory.isEmpty ? nil : resolvedPreferencesDirectory)
        guard let eventID = reader.unsigned(),
              let database = reader.string(),
              let scannedAt = reader.date() ?? nil,
              let fullScanAt = reader.date() ?? nil,
              let skipped = reader.strings()
        else { return nil }
        let options = ScanOptions(threads: Int(threads), leafThreshold: leafThreshold,
                                  measurePrivateSizes: measurePrivateSizes, excludedPaths: Set(excluded),
                                  notableNames: Set(notable),
                                  readOnlyPreferencesDirectory: readOnlyPreferencesDirectory.isEmpty ? nil : readOnlyPreferencesDirectory)

        var root: TreeNode?
        // Les dossiers dont on attend encore des enfants.
        var open: [(node: TreeNode, remaining: UInt64)] = []
        repeat {
            let parent = open.last?.node
            guard let name = reader.string(),
                  let fileID = reader.unsigned(),
                  let status = reader.status(),
                  let ownFiles = reader.sizes(),
                  let ownFileCount = reader.unsigned(),
                  let smallFiles = reader.sizes(),
                  let smallFileCount = reader.unsigned(),
                  let ownLatest = reader.date(),
                  let notableFiles = reader.strings(),
                  let fileCount = reader.unsigned(), fileCount <= UInt64(reader.remaining)
            else { return nil }
            let node = TreeNode(name: name, parent: parent, fileID: fileID, rootPath: parent == nil ? rootPath : nil)
            node.status = status
            node.ownFiles = ownFiles
            node.ownFileCount = Int(ownFileCount)
            node.smallFiles = smallFiles
            node.smallFileCount = Int(smallFileCount)
            node.ownLatestModification = ownLatest
            node.notableFiles = notableFiles
            node.files.reserveCapacity(Int(fileCount))
            for _ in 0..<fileCount {
                guard let leafName = reader.string(),
                      let sizes = reader.sizes(),
                      let logical = reader.signed(),
                      let modified = reader.date(),
                      let accessed = reader.date(),
                      let leafID = reader.unsigned(),
                      let cloneID = reader.unsigned(),
                      let isClone = reader.bool()
                else { return nil }
                node.files.append(FileLeaf(name: leafName, sizes: sizes, modified: modified, accessed: accessed,
                                           fileID: leafID, isClone: isClone, logicalSize: logical, cloneID: cloneID))
            }
            guard let childCount = reader.unsigned(), childCount <= UInt64(reader.remaining) else { return nil }
            node.needsTotals = true
            if let parent {
                parent.children.append(node)
                open[open.count - 1].remaining -= 1
            } else {
                root = node
            }
            while let last = open.last, last.remaining == 0 { open.removeLast() }
            if childCount > 0 {
                node.children.reserveCapacity(Int(childCount))
                open.append((node, childCount))
            }
        } while !open.isEmpty
        guard let root else { return nil }
        root.refreshTotals()

        var maps: [OwnerMap] = []
        for _ in 0..<2 {
            guard let count = reader.unsigned(), count <= UInt64(reader.remaining) else { return nil }
            var entries: [(key: UInt64, owner: UInt64)] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let key = reader.unsigned(), let owner = reader.unsigned() else { return nil }
                entries.append((key, owner))
            }
            maps.append(OwnerMap(entries: entries))
        }
        return ScanIndex(root: root, options: options, ownership: Ownership(links: maps[0], clones: maps[1]),
                         eventID: eventID, eventDatabase: database.isEmpty ? nil : database,
                         scannedAt: scannedAt, fullScanAt: fullScanAt, skippedVolumes: skipped,
                         preferenceDirectory: preferences)
    }
}

// MARK: - Octets

struct BinaryWriter {
    /// Un tableau d'octets plutôt qu'un `Data` : ajouter octet par octet à un
    /// `Data` passe par un appel non inliné à chaque fois.
    private(set) var bytes: [UInt8] = []

    init() {
        bytes.reserveCapacity(64 * 1024 * 1024)
    }


    mutating func unsigned(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    /// ZigZag : les petits négatifs restent courts.
    mutating func signed(_ value: Int64) {
        unsigned(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    mutating func string(_ value: String) {
        let utf8 = value.utf8
        unsigned(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func strings(_ values: [String]) {
        unsigned(UInt64(values.count))
        for value in values { string(value) }
    }

    /// À la milliseconde, `nil` compris : 0 pour l'absence, la valeur + 1 sinon.
    mutating func date(_ value: Date?) {
        guard let value else {
            unsigned(0)
            return
        }
        let milliseconds = Int64((value.timeIntervalSince1970 * 1000).rounded())
        unsigned(UInt64(bitPattern: (milliseconds << 1) ^ (milliseconds >> 63)) &+ 1)
    }

    mutating func sizes(_ value: Sizes) {
        signed(value.allocated)
        signed(value.freeable)
    }

    mutating func status(_ value: NodeStatus) {
        switch value {
        case .ok: unsigned(0)
        case .inaccessible(let code):
            unsigned(1)
            signed(Int64(code))
        case .otherVolume: unsigned(2)
        case .firmlink: unsigned(3)
        case .dataless: unsigned(4)
        case .excluded: unsigned(5)
        }
    }
}

/// Lecture défensive : un index tronqué ou abîmé rend `nil`, jamais un arbre faux.
struct BinaryReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func unsigned() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func signed() -> Int64? {
        guard let raw = unsigned() else { return nil }
        return Int64(bitPattern: (raw >> 1) ^ (0 &- (raw & 1)))
    }

    mutating func bool() -> Bool? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset] != 0
    }

    mutating func string() -> String? {
        guard let length = unsigned(), length <= UInt64(remaining) else { return nil }
        let end = offset + Int(length)
        defer { offset = end }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }

    mutating func strings() -> [String]? {
        guard let count = unsigned(), count <= UInt64(remaining) else { return nil }
        var values: [String] = []
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let value = string() else { return nil }
            values.append(value)
        }
        return values
    }

    /// `.some(nil)` pour une date absente, `nil` pour un index abîmé.
    mutating func date() -> Date?? {
        guard let raw = unsigned() else { return nil }
        guard raw > 0 else { return .some(nil) }
        let zigzag = raw - 1
        let milliseconds = Int64(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
        return .some(Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    mutating func sizes() -> Sizes? {
        guard let allocated = signed(), let freeable = signed() else { return nil }
        return Sizes(allocated: allocated, freeable: freeable)
    }

    mutating func status() -> NodeStatus? {
        switch unsigned() {
        case 0: return .ok
        case 1: return signed().map { .inaccessible(code: Int32(truncatingIfNeeded: $0)) }
        case 2: return .otherVolume
        case 3: return .firmlink
        case 4: return .dataless
        case 5: return .excluded
        default: return nil
        }
    }
}
