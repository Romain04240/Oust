import Foundation
import Testing
import OustCore
import OustHelperContract

@Suite("Démon : dates et noms des snapshots")
struct SnapshotDatesTests {

    @Test("Une date au format exact est admise", arguments: [
        "2026-10-17-014534", "2026-01-01-000000", "2026-12-31-235959",
    ])
    func acceptsExactDates(date: String) {
        #expect(SnapshotDates.isValid(date))
    }

    @Test("Tout le reste est refusé, à commencer par ce que tmutil prendrait pour un volume", arguments: [
        "", "/", "/System/Volumes/Data", "-d", "--help",
        "2026-10-17-01453",            // trop court
        "2026-10-17-0145345",          // trop long
        "2026-10-17 014534",           // espace à la place du tiret
        "2026/10/17-014534",
        "2026-1a-17-014534",
        " 2026-10-17-014534",
        "2026-10-17-014534\n",
        "2026-10-17-014534; rm -rf /",
        "2026-10-17-014534\0",
        "２０２６-10-17-014534",        // chiffres pleine chasse
        "٢٠٢٦-10-17-014534",           // chiffres arabes-indiens
        "2026-13-17-014534",           // mois 13
        "2026-00-17-014534",
        "2026-10-00-014534",
        "2026-10-32-014534",
        "2026-10-17-244534",           // 24 h
        "2026-10-17-016034",           // 60 min
        "2026-10-17-014560",           // 60 s
    ])
    func refusesEverythingElse(value: String) {
        #expect(!SnapshotDates.isValid(value))
    }

    @Test("Seuls les snapshots Time Machine locaux sont lus dans la liste, jamais ceux du système")
    func readsOnlyTimeMachineSnapshots() {
        let listing = """
        Snapshots for disk /System/Volumes/Data:
        com.apple.TimeMachine.2026-10-17-014534.local
          com.apple.TimeMachine.2026-10-18-004536.local
        com.apple.os.update-5D8A1C0E.1
        com.apple.os.update-2026-10-17-014534.local
        com.apple.TimeMachine.2026-10-17-024519.local.evil
        com.apple.TimeMachine.2026-10-17-03451.local
        com.apple.TimeMachine..local
        com.apple.TimeMachine.2026-10-17-044519
        xcom.apple.TimeMachine.2026-10-17-054519.local
        """
        #expect(SnapshotDates.timeMachineDates(inListing: listing) == ["2026-10-17-014534", "2026-10-18-004536"])
    }

    @Test("Le nom d'un snapshot se reconstruit exactement")
    func snapshotName() {
        #expect(SnapshotDates.snapshotName(for: "2026-10-17-014534") == "com.apple.TimeMachine.2026-10-17-014534.local")
    }

    /// L'application valide avant de demander, le démon revalide : ce que
    /// l'application envoie, le démon doit l'admettre, et ce qu'elle refuse,
    /// lui aussi.
    @Test("Le démon et l'application s'accordent sur les dates", arguments: [
        "com.apple.TimeMachine.2026-10-17-014534.local",
        "com.apple.TimeMachine.2026-10-17-01453.local",
        "com.apple.TimeMachine.2026-1a-17-014534.local",
        "com.apple.TimeMachine.2026-10-17-014534.local; rm -rf ~",
        "com.apple.os.update-5D8A1C0E.1",
    ])
    func agreesWithTheApp(name: String) {
        let fromApp = LocalSnapshot(name: name).date
        let fromDaemon = SnapshotDates.timeMachineDates(inListing: name).first
        #expect(fromApp == fromDaemon)
        if let fromApp { #expect(SnapshotDates.isValid(fromApp)) }
    }
}
