import Foundation
import Testing
@testable import OustRules
import OustCore
import OustScan

@Suite("Les bibliothèques de jeux d’un volume ouvert")
struct BoundVolumeGamesTests {
    private static let gameBytes = 1_200_000
    private static let steam = "Volume/SteamLibrary/steamapps"

    private func context(for home: FakeHome) async throws -> RuleContext {
        let volume = home.root.appendingPathComponent("Volume", isDirectory: true)
        let anchor = try home.openVolume(volume)
        let options = ScanOptions(leafThreshold: 100_000, notableNames: RuleEngine.notableNames(fileSystem: "apfs"))
        let (index, _) = await ScanIndex.refreshBound(nil, root: anchor, options: options, progress: ScanProgress())
        var context = home.context()
        context.volume = VolumeScope(root: anchor.url, name: "Volume", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.volumeAnchor = anchor
        context.tree = { index.root }
        return context
    }

    @Test("Steam lit les manifestes locaux, Epic reste protégé sans registre sur le volume")
    func readsOnlyVolumeMetadata() async throws {
        let home = try FakeHome()
        try home.text("\(Self.steam)/appmanifest_620.acf", """
            "name" "Portal 2"
            "installdir" "Portal 2"
            """)
        try home.file("\(Self.steam)/downloading/620/chunk", bytes: Self.gameBytes)
        try home.file("\(Self.steam)/common/Portal 2/game", bytes: Self.gameBytes)
        try home.file("\(Self.steam)/common/Ancien jeu/game", bytes: Self.gameBytes)
        try home.file("Volume/Epic Games/Jeu Epic/.egstore/bps/chunk", bytes: Self.gameBytes)
        try home.file("Volume/Autres/Jeu isolé/.egstore/game", bytes: Self.gameBytes)
        let epic = home.root.appendingPathComponent("Volume/Epic Games/Jeu Epic").path
        try home.text("Library/Application Support/Epic/UnrealEngineLauncher/LauncherInstalled.dat",
                      #"{"InstallationList":[{"InstallLocation":"\#(epic)"}]}"#)

        let items = await RuleEngine.collect(try await context(for: home), finders: [.games])
        let download = try #require(items.first { $0.ruleID == "game.steam.download" })
        #expect(download.title == "Portal 2")
        let leftovers = items.filter { $0.ruleID == "game.steam.leftover" }
        #expect(leftovers.map(\.title) == ["Ancien jeu"])
        #expect(leftovers.allSatisfy { $0.isSelectable })
        let epicItems = items.filter { $0.owner == "Epic Games Launcher" }
        #expect(Set(epicItems.map(\.title)) == ["Jeu Epic", "Jeu isolé"])
        #expect(epicItems.allSatisfy {
            $0.ruleID == "game.epic.leftover" && $0.protections.contains(.unknownState)
                && !$0.isSelectable && $0.sizes.freeable == 0
        })
    }

    @Test("Un manifeste redirigé protège les restes, les caches et fragments redirigés sont ignorés")
    func redirectsAreNotFollowed() async throws {
        let home = try FakeHome()
        try home.file("\(Self.steam)/common/Peut-être installé/game", bytes: Self.gameBytes)
        try home.file("\(Self.steam)/downloading/620/chunk", bytes: Self.gameBytes)
        try home.text("Autre/manifest.acf", """
            "name" "Nom extérieur"
            "installdir" "Peut-être installé"
            """)
        try home.file("Autre/shaders/cache", bytes: Self.gameBytes)
        try home.file("Autre/state.patch")
        let steam = home.root.appendingPathComponent(Self.steam)
        let fs = FileManager.default
        try fs.createSymbolicLink(at: steam.appendingPathComponent("appmanifest_620.acf"),
                                  withDestinationURL: home.root.appendingPathComponent("Autre/manifest.acf"))
        try fs.createSymbolicLink(at: steam.appendingPathComponent("shadercache"),
                                  withDestinationURL: home.root.appendingPathComponent("Autre/shaders"))
        try fs.createSymbolicLink(at: steam.appendingPathComponent("downloading/state_620_621.patch"),
                                  withDestinationURL: home.root.appendingPathComponent("Autre/state.patch"))

        let items = await RuleEngine.collect(try await context(for: home), finders: [.games])
        let leftover = try #require(items.first { $0.ruleID == "game.steam.leftover" })
        #expect(leftover.title == "Peut-être installé")
        #expect(leftover.protections.contains(.unknownState))
        #expect(!leftover.isSelectable && leftover.sizes.freeable == 0)
        let download = try #require(items.first { $0.ruleID == "game.steam.download" })
        #expect(download.title == "Steam")
        #expect(download.paths.map(\.lastPathComponent) == ["620"])
        #expect(!items.contains { $0.ruleID == "game.steam.shadercache" })
    }
}
