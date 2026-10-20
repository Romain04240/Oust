import Darwin
import Foundation
import OustAPFS
import OustCore

public struct SnapshotInventory: Sendable {
    public var snapshots: [LocalSnapshot]
    /// La place retenue par les seuls snapshots Time Machine, blocs partagés
    /// entre eux compris. Elle ne se déduit pas de la somme des tailles privées.
    public var retainedBytes: Int64?

    public init(snapshots: [LocalSnapshot], retainedBytes: Int64? = nil) {
        self.snapshots = snapshots
        self.retainedBytes = retainedBytes
    }
}

/// La mesure peut prendre quelques secondes. Un acteur la sérialise hors du
/// fil principal ; les listes légères de suppression continuent à passer par tmutil.
public actor SnapshotInventoryReader {
    public static let shared = SnapshotInventoryReader()

    public func read() -> SnapshotInventory? {
        let root = VolumeService.bootDataRoot.path
        let fd = open(root, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return nil }
        let maximum = Int64(fs.f_blocks) * Int64(fs.f_bsize)
        guard maximum > 0 else { return nil }
        let size = 65_536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        var snapshots: [LocalSnapshot] = []
        while true {
            let count = oust_snapshot_list(fd, buffer, size)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            guard let decoded = Self.decode(Data(bytes: buffer, count: size), count: Int(count), maximum: maximum) else { return nil }
            snapshots.append(contentsOf: decoded)
            if snapshots.count > 10_000 { return nil }
        }
        snapshots.sort { ($0.transactionID ?? 0) < ($1.transactionID ?? 0) }
        // La mesure par plages ne doit pas englober un snapshot système ou
        // d'une autre application. Une plage s'arrête à chaque date non choisie.
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        var retained: Int64?
        if version == 26 || version == 27 {
            retained = Self.retained(in: snapshots, maximum: maximum) { first, last in
                var bytes: UInt64 = 0
                guard oust_snapshot_space(first, last, &bytes) == 0, bytes <= UInt64(maximum) else { return nil }
                return Int64(bytes)
            }
        }
        return SnapshotInventory(snapshots: snapshots, retainedBytes: retained)
    }

    static func retained(in snapshots: [LocalSnapshot], maximum: Int64,
                         query: (UInt64, UInt64) -> Int64?) -> Int64? {
        var ranges: [(UInt64, UInt64)] = []
        var start: UInt64?
        var end: UInt64 = 0
        var previous: UInt64 = 0
        for snapshot in snapshots {
            guard let xid = snapshot.transactionID, xid > previous else { return nil }
            previous = xid
            if snapshot.isDeletable {
                if start == nil { start = xid }
                end = xid
            } else if let first = start {
                ranges.append((first, end)); start = nil
            }
        }
        if let start { ranges.append((start, end)) }
        var total: Int64 = 0
        for (first, last) in ranges {
            guard let bytes = query(first, last), bytes >= 0, bytes <= maximum - total else { return nil }
            total += bytes
        }
        return total
    }

    /// Les attributs de fs_snapshot_list sont alignés sur quatre octets. Toutes
    /// les bornes et les attributs retournés sont contrôlés avant une lecture.
    static func decode(_ data: Data, count: Int, maximum: Int64) -> [LocalSnapshot]? {
        guard count > 0, count <= data.count / 24 else { return nil }
        return data.withUnsafeBytes { raw -> [LocalSnapshot]? in
            func u32(_ offset: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            func u64(_ offset: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            var offset = 0
            var result: [LocalSnapshot] = []
            for _ in 0..<count {
                guard offset <= data.count - 24 else { return nil }
                let length = Int(u32(offset))
                guard length >= 24, length <= data.count - offset else { return nil }
                let end = offset + length
                let common = u32(offset + 4)
                let file = u32(offset + 16)
                let extended = u32(offset + 20)
                let expected = UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_OBJID) | UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_UUID)
                guard common & ~expected == 0, file & ~UInt32(ATTR_FILE_DATAALLOCSIZE) == 0,
                      extended & ~UInt32(ATTR_CMNEXT_PRIVATESIZE) == 0 else { return nil }
                var cursor = offset + 24
                if common & UInt32(ATTR_CMN_ERROR) != 0 {
                    guard cursor <= end - 4, u32(cursor) == 0 else { return nil }
                    cursor += 4
                }
                guard common & UInt32(ATTR_CMN_NAME) != 0, cursor <= end - 8 else { return nil }
                let displacement = Int(Int32(bitPattern: u32(cursor)))
                let nameLength = Int(u32(cursor + 4))
                let nameStart = cursor + displacement
                guard nameLength > 1, nameStart >= offset, nameStart <= end,
                      nameLength <= end - nameStart, raw[nameStart + nameLength - 1] == 0 else { return nil }
                guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength - 1)), encoding: .utf8),
                      !name.contains("\0") else { return nil }
                cursor += 8
                var snapshot = LocalSnapshot(name: name)
                if common & UInt32(ATTR_CMN_OBJID) != 0 {
                    guard cursor <= end - 8 else { return nil }
                    snapshot.transactionID = u64(cursor) & 0x3fff_ffff_ffff_ffff
                    cursor += 8
                }
                if common & UInt32(ATTR_CMN_CRTIME) != 0 { cursor += 16 }
                if common & UInt32(ATTR_CMN_UUID) != 0 { cursor += 16 }
                if file & UInt32(ATTR_FILE_DATAALLOCSIZE) != 0 { cursor += 8 }
                if extended & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                    guard cursor <= end - 8 else { return nil }
                    let bytes = u64(cursor)
                    guard bytes <= UInt64(max(0, maximum)) else { return nil }
                    snapshot.privateBytes = Int64(bytes)
                    cursor += 8
                }
                guard cursor <= end else { return nil }
                result.append(snapshot)
                offset = end
            }
            return result
        }
    }
}
