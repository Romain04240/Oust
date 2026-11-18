import Foundation
import Synchronization
import Testing
@testable import OustRules
import OustCore
import OustSafety
import OustScan

@Suite("Les fiches externes exclues restent sans lecture")
struct NoReadVolumeRowsTests {
    @Test("La fiche Time Machine ne devient jamais une racine de mesure")
    func timeMachineKeepsNoReadIntent() async throws {
        let home = try FakeHome()
        try home.file("Volume/Backups.backupdb/Mac/sauvegarde/donnees", bytes: 4096)
        let anchor = try home.openVolume(home.root.appendingPathComponent("Volume", isDirectory: true))
        let backup = anchor.url.appendingPathComponent("Backups.backupdb", isDirectory: true)
        let item = CleanupItem(title: "Backups.backupdb", paths: [backup], category: .protectedOnDisk,
                               owner: "Time Machine", ruleID: "volume.time_machine", safety: .protected,
                               method: .manual, rebuild: .irreversible)
        let candidates = [Candidate(item: item, needsMeasure: false)]
        let measured = await RuleEngine.measure(candidates, using: Measurer { _ in
            Issue.record("La sauvegarde exclue ne doit jamais être mesurée")
            return [:]
        }, pathGuard: PathGuard(home: home.root), volumeAnchor: anchor)
        let row = try #require(measured.first)
        #expect(row.sizes == .zero)
        #expect(!row.isSelectable)
    }

    @Test("La taille prélevée par le chercheur de traces est remesurée")
    func traceMeasurementIsRefreshed() async throws {
        let home = try FakeHome()
        try home.file("Volume/.DS_Store", bytes: 4096)
        let anchor = try home.openVolume(home.root.appendingPathComponent("Volume", isDirectory: true))
        let file = anchor.url.appendingPathComponent(".DS_Store", isDirectory: false)
        let seen = Mutex<[URL]>([])
        let item = CleanupItem(title: ".DS_Store", paths: [file], category: .diskTraces,
                               owner: "Finder", ruleID: "volume.ds_store", safety: .review,
                               method: .removeNow, rebuild: .automatic)
        let measured = await RuleEngine.measure([Candidate(item: item, needsMeasure: false)], using: Measurer { paths in
            seen.withLock { $0 = paths }
            return await Scanner.measureBound(paths, root: anchor)
        }, pathGuard: PathGuard(home: home.root), volumeAnchor: anchor)
        #expect(seen.withLock { $0 } == [file])
        #expect((measured.first?.sizes.allocated ?? 0) >= 4096)
    }
}
