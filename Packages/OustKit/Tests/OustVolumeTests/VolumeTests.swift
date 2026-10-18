import Foundation
import Testing
@testable import OustVolume
import OustCore

@Suite("Volumes et snapshots")
struct VolumeTests {

    @Test("Seuls les snapshots Time Machine sont supprimables")
    func parseSnapshots() {
        let output = """
        Snapshots for disk /System/Volumes/Data:
        com.apple.TimeMachine.2026-10-17-014534.local
        com.apple.TimeMachine.2026-10-18-004536.local
        com.apple.os.update-5D8A1C0E.1
        """
        let snapshots = VolumeService.parseSnapshots(output)
        #expect(snapshots.count == 3)
        #expect(snapshots.filter(\.isDeletable).map(\.date) == ["2026-10-17-014534", "2026-10-18-004536"])
        #expect(snapshots.last?.isDeletable == false)
    }

    @Test("Une date mal formée n'entre jamais dans la commande administrateur",
          arguments: [
            "com.apple.TimeMachine.2026-10-17-014534.local; rm -rf ~",
            "com.apple.TimeMachine.2026-10-17-01453.local",
            "com.apple.TimeMachine.2026-1a-17-014534.local",
            "com.apple.TimeMachine.\"2026-10-17-014534\".local",
          ])
    func refusesMalformedDates(name: String) {
        let snapshot = LocalSnapshot(name: name)
        #expect(snapshot.date == nil)
        #expect(VolumeService.deletionScript(for: [snapshot]) == nil)
    }

    @Test("La commande ne contient que tmutil et des dates validées")
    func deletionScript() throws {
        let snapshots = [
            LocalSnapshot(name: "com.apple.TimeMachine.2026-10-17-014534.local"),
            LocalSnapshot(name: "com.apple.TimeMachine.2026-10-17-024519.local"),
        ]
        let script = try #require(VolumeService.deletionScript(for: snapshots))
        #expect(script == "do shell script \"/usr/bin/tmutil deletelocalsnapshots 2026-10-17-014534; /usr/bin/tmutil deletelocalsnapshots 2026-10-17-024519\" with administrator privileges")
    }

    @Test("Un mélange avec un snapshot système est refusé en bloc")
    func refusesSystemSnapshot() {
        let snapshots = [
            LocalSnapshot(name: "com.apple.TimeMachine.2026-10-17-014534.local"),
            LocalSnapshot(name: "com.apple.os.update-5D8A1C0E.1"),
        ]
        #expect(VolumeService.deletionScript(for: snapshots) == nil)
    }

    @Test("Le disque de démarrage se parcourt depuis le volume de données")
    func bootVolume() throws {
        let boot = try #require(VolumeService.bootVolume())
        #expect(boot.scanRoot.path == "/System/Volumes/Data")
        #expect(boot.capacity.total > 0)
        #expect(boot.capacity.availableForImportantUsage >= boot.capacity.available)
    }

    @Test("La capacité purgeable est la différence entre les deux libres")
    func purgeable() {
        let capacity = Capacity(total: 1_000, available: 100, availableForImportantUsage: 350)
        #expect(capacity.used == 900)
        #expect(capacity.purgeable == 250)
    }
}
