import Darwin
import Foundation
import Testing
@testable import OustVolume
import OustCore

@Suite("Mesures natives des snapshots APFS")
struct SnapshotInventoryTests {
    func record(name: String, xid: UInt64 = 12, bytes: UInt64 = 500) -> Data {
        let name = Data((name + "\0").utf8)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(48 + name.count))
        append(UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJID))
        append(UInt32(0)); append(UInt32(0)); append(UInt32(0))
        append(UInt32(ATTR_CMNEXT_PRIVATESIZE))
        append(Int32(24)); append(UInt32(name.count))
        append(xid); append(bytes)
        data.append(name)
        return data
    }

    @Test("La taille privée et le XID sont lus, y compris une taille réellement nulle")
    func privateSizes() throws {
        let name = "com.apple.TimeMachine.2026-10-20-101500.local"
        for bytes in [UInt64(0), 500] {
            let decoded = try #require(SnapshotInventoryReader.decode(record(name: name, bytes: bytes), count: 1, maximum: 1_000))
            #expect(decoded.first?.name == name)
            #expect(decoded.first?.privateBytes == Int64(bytes))
            #expect(decoded.first?.transactionID == 12)
        }
    }

    @Test("Des enregistrements tronqués, une référence hors limites ou une taille impossible sont refusés")
    func malformed() {
        let data = record(name: "com.apple.TimeMachine.2026-10-20-101500.local")
        for length in 0..<data.count {
            #expect(SnapshotInventoryReader.decode(Data(data.prefix(length)), count: 1, maximum: 1_000) == nil)
        }
        var outside = data
        outside.replaceSubrange(24..<28, with: [0xff, 0xff, 0xff, 0x7f])
        #expect(SnapshotInventoryReader.decode(outside, count: 1, maximum: 1_000) == nil)
        #expect(SnapshotInventoryReader.decode(record(name: "x", bytes: .max), count: 1, maximum: 1_000) == nil)
    }

    @Test("Les blocs partagés sont mesurés par plages, jamais en additionnant les tailles privées")
    func ranges() {
        func snapshot(_ xid: UInt64, timeMachine: Bool = true) -> LocalSnapshot {
            var result = LocalSnapshot(name: timeMachine ? "com.apple.TimeMachine.2026-10-20-101500.local" : "com.apple.os.update-test")
            result.transactionID = xid
            result.privateBytes = 1
            return result
        }
        let snapshots = [snapshot(10), snapshot(20), snapshot(30, timeMachine: false), snapshot(40)]
        var requested: [[UInt64]] = []
        let total = SnapshotInventoryReader.retained(in: snapshots, maximum: 1_000) { first, last in
            requested.append([first, last]); return first == 10 ? 500 : 200
        }
        #expect(requested == [[10, 20], [40, 40]])
        #expect(total == 700)
        #expect(SnapshotInventoryReader.retained(in: snapshots, maximum: 100) { _, _ in 500 } == nil)
        #expect(SnapshotInventoryReader.retained(in: snapshots, maximum: 1_000) { _, _ in nil } == nil)
    }
}
