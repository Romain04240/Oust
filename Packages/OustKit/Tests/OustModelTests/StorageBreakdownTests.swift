import Testing
import OustCore
import OustModel

@Suite("Répartition du stockage sans double comptage")
struct StorageBreakdownTests {
    @Test("Les catégories, le purgeable et le libre s'additionnent à la capacité")
    func partitions() {
        let capacity = Capacity(total: 1_000, available: 60, availableForImportantUsage: 240)
        let parts = StorageBreakdown(observed: [.applications: 100, .documents: 200]).parts(capacity: capacity)
        #expect(parts.reduce(0) { $0 + $1.bytes } == 1_000)
        #expect(parts.first { $0.category == .system }?.bytes == 460)
        #expect(parts.first { $0.category == .purgeable }?.bytes == 180)
        #expect(capacity.occupied == 760)
        #expect(capacity.used == 940)
    }

    @Test("Une ancienne analyse plus grande que l'occupation actuelle ne déborde pas")
    func staleScan() {
        let capacity = Capacity(total: 1_000, available: 60, availableForImportantUsage: 240)
        let parts = StorageBreakdown(observed: [.applications: 900, .documents: 500]).parts(capacity: capacity)
        #expect(parts.reduce(0) { $0 + $1.bytes } == capacity.total)
        #expect(parts.allSatisfy { $0.bytes >= 0 })
    }

    @Test("Une capacité incohérente est bornée sans purgeable au-delà du disque")
    func clamps() {
        let capacity = Capacity(total: 1_000, available: -50, availableForImportantUsage: 2_000)
        #expect(capacity.available == 0)
        #expect(capacity.availableForImportantUsage == 1_000)
        #expect(capacity.occupied + capacity.purgeable + capacity.available == capacity.total)
    }
}
