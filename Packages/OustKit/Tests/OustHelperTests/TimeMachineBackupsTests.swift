import Foundation
import Synchronization
import Testing
import OustHelperContract
@testable import OustHelperDaemon

/// Les sorties de `tmutil`, telles qu'on les trouve sur un Mac. Aucune n'est lue
/// sur le disque : ce sont des textes recopiés ici.
enum TimeMachineFixtures {

    /// `tmutil listbackups -d /Volumes/Time Machine` sur une destination APFS.
    static let apfsListing = """
        2025-03-03-101530.backup
        2025-09-14-221004.backup
        2026-10-16-093012.backup
        2026-10-17-093544.backup
        2026-10-18-083015.backup
        """

    /// La même, avec `-m` : les sauvegardes montées, et leur chemin.
    static let mountedListing = """
        /Volumes/.timemachine/0D9F2E4B-1C3A-4B5D-9E8F-7A6B5C4D3E2F/2026-10-16-093012.backup/2026-10-16-093012.backup
        /Volumes/.timemachine/0D9F2E4B-1C3A-4B5D-9E8F-7A6B5C4D3E2F/2026-10-18-083015.backup/2026-10-18-083015.backup
        """

    /// Une ancienne destination HFS+, avec une sauvegarde interrompue.
    static let hfsListing = """
        /Volumes/Vieux disque/Backups.backupdb/MacBook Pro de Romain/2019-05-01-120000
        /Volumes/Vieux disque/Backups.backupdb/MacBook Pro de Romain/2019-05-02-120000
        /Volumes/Vieux disque/Backups.backupdb/MacBook Pro de Romain/2019-05-03-120000.inProgress
        """

    /// Ce que `tmutil` écrit quand il n'y a rien pour ce Mac.
    static let noMachineDirectory = "No machine directory found for host.\n"

    /// `tmutil destinationinfo -X` : le disque de Romain monté, un partage
    /// réseau, et un autre disque débranché.
    static let destinationInfo = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>Kind</key><string>Local</string>
                    <key>ID</key><string>72FAB8EC-02B0-4438-99CF-7457FF567141</string>
                    <key>Name</key><string>Time Machine</string>
                    <key>MountPoint</key><string>/Volumes/Time Machine/</string>
                    <key>LastDestination</key><integer>1</integer>
                </dict>
                <dict>
                    <key>Kind</key><string>Network</string>
                    <key>ID</key><string>1B2C3D4E-0000-4000-8000-000000000001</string>
                    <key>Name</key><string>Sauvegardes</string>
                    <key>URL</key><string>smb://nas.local/Sauvegardes</string>
                    <key>MountPoint</key><string>/Volumes/Sauvegardes</string>
                </dict>
                <dict>
                    <key>Kind</key><string>Local</string>
                    <key>ID</key><string>9A8B7C6D-0000-4000-8000-000000000002</string>
                    <key>Name</key><string>Vieux disque</string>
                </dict>
            </array>
        </dict>
        </plist>
        """.utf8)

    /// Le même Mac, sans aucun disque de sauvegarde monté.
    static let unmountedInfo = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Destinations</key><array><dict>
        <key>Kind</key><string>Local</string><key>ID</key><string>72FAB8EC-02B0-4438-99CF-7457FF567141</string>
        <key>Name</key><string>Time Machine</string><key>LastDestination</key><integer>1</integer>
        </dict></array></dict></plist>
        """.utf8)

    static func status(running: Bool) -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>ClientID</key><string>com.apple.backupd</string>
            <key>Percent</key><real>-1</real>
            <key>Running</key><\(running ? "true" : "false")/>
            </dict></plist>
            """.utf8)
    }

    static let mountPoint = "/Volumes/Time Machine"
}

@Suite("Sauvegardes Time Machine : ce que disent les sorties de tmutil")
struct TimeMachineParsingTests {

    @Test("Une destination APFS : cinq sauvegardes, de la plus ancienne à la plus récente")
    func apfsListing() {
        let listed = TimeMachineBackups.timestamps(inListing: TimeMachineFixtures.apfsListing)
        #expect(listed == ["2025-03-03-101530", "2025-09-14-221004", "2026-10-16-093012",
                           "2026-10-17-093544", "2026-10-18-083015"])
        #expect(TimeMachineBackups.latest(of: listed) == "2026-10-18-083015")
    }

    @Test("Les chemins montés et les dossiers HFS+ se lisent aussi ; une sauvegarde interrompue, non")
    func otherListings() {
        #expect(TimeMachineBackups.timestamps(inListing: TimeMachineFixtures.mountedListing)
                == ["2026-10-16-093012", "2026-10-18-083015"])
        #expect(TimeMachineBackups.timestamps(inListing: TimeMachineFixtures.hfsListing)
                == ["2019-05-01-120000", "2019-05-02-120000"])
    }

    @Test("Une ligne d'erreur, du désordre, des doublons : rien d'inventé")
    func noiseIsIgnored() {
        #expect(TimeMachineBackups.timestamps(inListing: TimeMachineFixtures.noMachineDirectory).isEmpty)
        let messy = "2026-10-18-083015.backup\n  2025-03-03-101530.backup  \n2026-10-18-083015\n"
            + "2026-13-01-000000.backup\n2026-10-18-08301.backup\n/\n\n"
        #expect(TimeMachineBackups.timestamps(inListing: messy) == ["2025-03-03-101530", "2026-10-18-083015"])
        #expect(TimeMachineBackups.latest(of: []) == nil)
    }

    @Test("destinationinfo : seule une destination locale montée est admissible")
    func destinations() throws {
        let all = try #require(TimeMachineBackups.destinations(inDestinationInfo: TimeMachineFixtures.destinationInfo))
        #expect(all.count == 3)
        #expect(all[0].mountPoint == "/Volumes/Time Machine")
        #expect(all[0].isEligible)
        #expect(!all[1].isEligible)
        #expect(!all[2].isEligible)
        #expect(TimeMachineBackups.eligibleMountPoints(inDestinationInfo: TimeMachineFixtures.destinationInfo)
                == ["/Volumes/Time Machine"])
        #expect(TimeMachineBackups.eligibleMountPoints(inDestinationInfo: TimeMachineFixtures.unmountedInfo) == [])
    }

    @Test("destinationinfo illisible : nil, jamais une liste vide qui passerait pour « aucune »")
    func unreadableDestinations() {
        #expect(TimeMachineBackups.destinations(inDestinationInfo: Data("tmutil: erreur".utf8)) == nil)
        #expect(TimeMachineBackups.eligibleMountPoints(inDestinationInfo: Data()) == nil)
        let empty = Data(#"<?xml version="1.0"?><plist version="1.0"><dict/></plist>"#.utf8)
        #expect(TimeMachineBackups.destinations(inDestinationInfo: empty) == [])
    }

    @Test("status -X : en cours ou non ; illisible, nil")
    func status() {
        #expect(TimeMachineBackups.isRunning(statusPlist: TimeMachineFixtures.status(running: true)) == true)
        #expect(TimeMachineBackups.isRunning(statusPlist: TimeMachineFixtures.status(running: false)) == false)
        let header = Data("Backup session status:\n".utf8) + TimeMachineFixtures.status(running: true)
        #expect(TimeMachineBackups.isRunning(statusPlist: header) == true)
        let number = Data(#"<plist version="1.0"><dict><key>Running</key><integer>1</integer></dict></plist>"#.utf8)
        #expect(TimeMachineBackups.isRunning(statusPlist: number) == true)
        // L'ancien format texte, celui de `tmutil status` sans `-X`, se lit aussi.
        let oldStyle = "{\n    ClientID = \"com.apple.backupd\";\n    Percent = \"-1\";\n    Running = 1;\n}\n"
        #expect(TimeMachineBackups.isRunning(statusPlist: Data(oldStyle.utf8)) == true)
        #expect(TimeMachineBackups.isRunning(statusPlist: Data("tmutil: status failed".utf8)) == nil)
        #expect(TimeMachineBackups.isRunning(statusPlist: Data(#"<plist version="1.0"><dict/></plist>"#.utf8)) == nil)
    }

    @Test("Un point de montage n'est admis que sous la forme /Volumes/<nom>",
          arguments: [
            ("/Volumes/Time Machine", true), ("/Volumes/Sauvegarde été", true), ("/Volumes/TM-2", true),
            ("/", false), ("/Volumes", false), ("/Volumes/", false), ("/Volumes/..", false),
            ("/Volumes/../System", false), ("/Volumes/a/b", false), ("Volumes/Time Machine", false),
            ("/Volumes/-d", false), ("/Volumes/.timemachine", false), ("/Volumes/Time \"Machine\"", false),
            ("/Volumes/Time\\Machine", false), ("/Volumes/Time\nMachine", false), ("/Volumes/Time`id`", false),
            ("/System/Volumes/Data", false), ("/Applications/Utilities", false),
          ])
    func mountPoints(path: String, accepted: Bool) {
        #expect(TimeMachineBackups.isPlausibleMountPoint(path) == accepted)
    }

    @Test("Un horodatage a la forme exacte d'une date de snapshot, sans rien de plus permissif",
          arguments: [
            ("2026-10-18-083015", true), ("2026-10-18-083015.backup", false), ("2026-10-18", false),
            ("/Volumes/Time Machine", false), ("-p", false), ("2026-10-18-08301", false),
            ("2026-1O-18-083015", false), ("2026-10-18-083015 ", false), ("2026-00-18-083015", false),
            ("2026-10-18-246015", false), ("２０２６-10-18-083015", false),
          ])
    func timestamps(value: String, valid: Bool) {
        #expect(TimeMachineBackups.isValidTimestamp(value) == valid)
    }

    @Test("La réponse du démon fait l'aller-retour ; une réponse d'un autre contrat n'est pas lue")
    func responseRoundTrip() throws {
        let response = BackupDeletionResponse(results: [
            .init(timestamp: "2025-03-03-101530", outcome: .deleted),
            .init(timestamp: "2026-10-18-083015", outcome: .latest),
            .init(timestamp: "2025-09-14-221004", outcome: .failed, message: "Busy"),
        ])
        let decoded = try #require(BackupDeletionResponse(dictionary: response.dictionary))
        #expect(decoded == response)
        #expect(decoded.deleted == ["2025-03-03-101530"])
        let refused = BackupDeletionResponse.refused(.backupRunning)
        #expect(BackupDeletionResponse(dictionary: refused.dictionary) == refused)
        let other: NSDictionary = [HelperContract.Key.contractVersion: HelperContract.version + 1,
                                   HelperContract.Key.results: [] as NSArray]
        #expect(BackupDeletionResponse(dictionary: other) == nil)
    }
}

/// Un `tmutil` de théâtre pour les sauvegardes : il tient une liste et note ce
/// qu'on lui demande. Aucun test ne supprime de vraie sauvegarde.
final class FakeBackupTool: BackupTool {
    struct State {
        var listed: [String]
        var info: Data? = TimeMachineFixtures.destinationInfo
        var listingWorks = true
        /// L'état renvoyé à chaque lecture, dans l'ordre ; le dernier se répète.
        var running: [Bool?] = [false]
        var failing: Set<String> = []
        var lies = false
        var deletions: [String] = []
        var listings = 0
        var statusReads = 0
    }

    let state: Mutex<State>

    init(listed: [String], configure: (inout State) -> Void = { _ in }) {
        var initial = State(listed: listed)
        configure(&initial)
        state = Mutex(initial)
    }

    var deletions: [String] { state.withLock { $0.deletions } }
    var listings: Int { state.withLock { $0.listings } }

    func destinationInfo() -> Data? { state.withLock { $0.info } }

    func status() -> Data? {
        state.withLock { state in
            let index = min(state.statusReads, state.running.count - 1)
            state.statusReads += 1
            return state.running[index].map(TimeMachineFixtures.status(running:))
        }
    }

    func listBackups(mountPoint: String) -> String? {
        state.withLock { state in
            state.listings += 1
            guard state.listingWorks, mountPoint == TimeMachineFixtures.mountPoint else { return nil }
            return state.listed.map { $0 + ".backup" }.joined(separator: "\n")
        }
    }

    func deleteBackup(mountPoint: String, timestamp: String) -> String? {
        state.withLock { state in
            state.deletions.append(timestamp)
            if state.failing.contains(timestamp) { return "Failed to delete backup" }
            if !state.lies { state.listed.removeAll { $0 == timestamp } }
            return nil
        }
    }
}

@Suite("Démon : ce qu'il fait d'une demande de sauvegardes")
struct BackupServiceTests {

    static let listed = ["2025-03-03-101530", "2025-09-14-221004", "2026-10-16-093012",
                         "2026-10-17-093544", "2026-10-18-083015"]
    static let mount = TimeMachineFixtures.mountPoint

    private func handle(_ timestamps: [String], destination: String = mount, version: Int = HelperContract.version,
                        tool: FakeBackupTool) -> BackupDeletionResponse {
        HelperService.handleBackups(timestamps, destination: destination, contractVersion: version, tool: tool)
    }

    @Test("Les plus anciennes, listées et bien formées, sont supprimées une à une")
    func deletesOldest() {
        let tool = FakeBackupTool(listed: Self.listed)
        let response = handle(["2025-03-03-101530", "2025-09-14-221004"], tool: tool)
        #expect(response.refusal == nil)
        #expect(response.deleted == ["2025-03-03-101530", "2025-09-14-221004"])
        #expect(tool.deletions == ["2025-03-03-101530", "2025-09-14-221004"])
    }

    @Test("La plus récente n'est jamais supprimée, même demandée")
    func neverTheLatest() {
        let tool = FakeBackupTool(listed: Self.listed)
        let response = handle(["2026-10-18-083015", "2025-03-03-101530"], tool: tool)
        #expect(response.results.first { $0.timestamp == "2026-10-18-083015" }?.outcome == .latest)
        #expect(tool.deletions == ["2025-03-03-101530"])
    }

    @Test("Une seule sauvegarde sur le disque : rien ne part")
    func onlyOne() {
        let tool = FakeBackupTool(listed: ["2026-10-18-083015"])
        let response = handle(["2026-10-18-083015"], tool: tool)
        #expect(response.results.map(\.outcome) == [.latest])
        #expect(tool.deletions.isEmpty)
    }

    @Test("Un horodatage mal formé ou absent de la liste n'atteint jamais tmutil")
    func malformedAndUnlisted() {
        let tool = FakeBackupTool(listed: Self.listed)
        let response = handle(["/", "-p /Volumes/Time Machine", "2025-03-03-101530.backup", "2024-01-01-000000"],
                              tool: tool)
        #expect(response.results.map(\.outcome) == [.malformed, .malformed, .malformed, .notListed])
        #expect(tool.deletions.isEmpty)
    }

    @Test("Une destination inconnue est refusée en bloc, sans rien lister ni supprimer",
          arguments: ["/", "/Volumes/Autre disque", "/Volumes/Sauvegardes", "/Volumes/Time Machine/..",
                      "/System/Volumes/Data", "/Volumes/Vieux disque"])
    func unknownDestination(destination: String) {
        let tool = FakeBackupTool(listed: Self.listed)
        let response = handle(["2025-03-03-101530"], destination: destination, tool: tool)
        #expect(response.refusal == .unknownDestination)
        #expect(tool.deletions.isEmpty)
        #expect(tool.listings == 0)
    }

    @Test("Disque débranché depuis : refusé en bloc")
    func unmounted() {
        let tool = FakeBackupTool(listed: Self.listed) { $0.info = TimeMachineFixtures.unmountedInfo }
        #expect(handle(["2025-03-03-101530"], tool: tool).refusal == .unknownDestination)
        #expect(tool.deletions.isEmpty)
    }

    @Test("Une sauvegarde en cours, ou un état illisible : rien n'est fait", arguments: [true, nil] as [Bool?])
    func backupRunning(running: Bool?) {
        let tool = FakeBackupTool(listed: Self.listed) { $0.running = [running] }
        let response = handle(["2025-03-03-101530"], tool: tool)
        #expect(response.refusal == .backupRunning)
        #expect(tool.deletions.isEmpty)
        #expect(tool.listings == 0)
    }

    @Test("Une sauvegarde qui démarre en route arrête tout : le reste est laissé")
    func backupStartsMidway() {
        // Lu une fois avant de lister, puis avant chaque suppression.
        let tool = FakeBackupTool(listed: Self.listed) { $0.running = [false, false, true] }
        let response = handle(["2025-03-03-101530", "2025-09-14-221004", "2026-10-16-093012"], tool: tool)
        #expect(response.refusal == nil)
        #expect(response.results.map(\.outcome) == [.deleted, .backupRunning, .backupRunning])
        #expect(tool.deletions == ["2025-03-03-101530"])
    }

    @Test("Refus en bloc avant de rien lister : contrat, vide, démesuré")
    func wholeRefusals() {
        let tool = FakeBackupTool(listed: Self.listed)
        #expect(handle(["2025-03-03-101530"], version: HelperContract.version + 1, tool: tool).refusal == .contractMismatch)
        #expect(handle([], tool: tool).refusal == .empty)
        let many = Array(repeating: "2025-03-03-101530", count: TimeMachineBackups.maximumPerRequest + 1)
        #expect(handle(many, tool: tool).refusal == .tooMany)
        #expect(tool.listings == 0)
        #expect(tool.deletions.isEmpty)
    }

    @Test("Destinations ou liste illisibles : refusé, rien n'est comparable")
    func unreadable() {
        let noInfo = FakeBackupTool(listed: Self.listed) { $0.info = nil }
        #expect(handle(["2025-03-03-101530"], tool: noInfo).refusal == .listingFailed)
        let noListing = FakeBackupTool(listed: Self.listed) { $0.listingWorks = false }
        #expect(handle(["2025-03-03-101530"], tool: noListing).refusal == .listingFailed)
        #expect(noListing.deletions.isEmpty)
    }

    @Test("tmutil qui dit « fait » sans rien faire n'est pas cru")
    func lyingTool() {
        let tool = FakeBackupTool(listed: Self.listed) { $0.lies = true }
        let response = handle(["2025-03-03-101530"], tool: tool)
        #expect(response.results.map(\.outcome) == [.failed])
        #expect(response.results.first?.message == "still listed")
    }

    @Test("Un échec de tmutil est rapporté tel quel, les autres continuent")
    func failureIsReported() {
        let tool = FakeBackupTool(listed: Self.listed) { $0.failing = ["2025-03-03-101530"] }
        let response = handle(["2025-03-03-101530", "2025-09-14-221004"], tool: tool)
        #expect(response.results.map(\.outcome) == [.failed, .deleted])
        #expect(response.results.first?.message == "Failed to delete backup")
    }

    @Test("Un doublon n'est demandé qu'une fois")
    func duplicates() {
        let tool = FakeBackupTool(listed: Self.listed)
        _ = handle(["2025-03-03-101530", "2025-03-03-101530"], tool: tool)
        #expect(tool.deletions == ["2025-03-03-101530"])
    }

    @Test("Le vrai outil refuse de lui-même ce qui n'a pas la forme attendue, sans lancer tmutil")
    func systemToolGuards() {
        let tool = SystemBackupTool()
        #expect(tool.deleteBackup(mountPoint: "/", timestamp: "2025-03-03-101530") == "unknown destination")
        #expect(tool.deleteBackup(mountPoint: "/Volumes/Time Machine", timestamp: "/") == "malformed")
        #expect(tool.listBackups(mountPoint: "/System/Volumes/Data") == nil)
    }
}
