import Darwin
import Foundation
import Testing
@testable import OustRules
import OustCore

@Suite("Les artefacts de projets sur un volume ouvert")
struct BoundProjectArtifactsTests {
    @Test("Seuls les répertoires et marqueurs locaux et vérifiés qualifient un artefact")
    func verifiesMarkersAndArtifactDirectories() async throws {
        let home = try FakeHome()
        let disk = home.root.appendingPathComponent("Volume", isDirectory: true)
        try home.text("Volume/Outil/package.json", "{}")
        try home.text("Volume/Outil/package-lock.json", "{}")
        try home.file("Volume/Outil/node_modules/fixture.js", bytes: 4_096)
        try home.file("Volume/Outil/build/index.js", bytes: 4_096)
        try home.file("Volume/Outil/dist/index.js", bytes: 4_096)
        try home.file("Volume/LienMarqueur/node_modules/fixture.js", bytes: 4_096)
        try home.file("Volume/LienArtefact/package.json", bytes: 4_096)
        try home.file("Volume/2026-11-18-120000.backup/Outil/node_modules/fixture.js", bytes: 4_096)
        try home.text("Volume/2026-11-18-120000.backup/Outil/package.json", "{}")
        try home.text("Autre/package.json", "{}")
        try home.text("Autre/pnpm-lock.yaml", "")
        try home.file("Autre/node_modules/fixture.js", bytes: 4_096)
        let other = home.root.appendingPathComponent("Autre", isDirectory: true)
        let fs = FileManager.default
        try fs.createSymbolicLink(at: disk.appendingPathComponent("Outil/pnpm-lock.yaml"),
                                  withDestinationURL: other.appendingPathComponent("pnpm-lock.yaml"))
        try fs.createSymbolicLink(at: disk.appendingPathComponent("LienMarqueur/package.json"),
                                  withDestinationURL: other.appendingPathComponent("package.json"))
        try fs.createSymbolicLink(at: disk.appendingPathComponent("LienArtefact/node_modules"),
                                  withDestinationURL: other.appendingPathComponent("node_modules"))
        try fs.createSymbolicLink(at: disk.appendingPathComponent("LienProjet"), withDestinationURL: other)

        let context = try makeContext(home, disk: disk)
        let candidates = await ProjectArtifactsFinder(context: context).find()

        let opened = try #require(context.volumeAnchor)
        #expect(candidates.map(\.item.paths) == [[opened.url.appendingPathComponent("Outil/node_modules", isDirectory: true)]])
        #expect(candidates.first?.item.rebuild == .command("npm ci", minutes: 2))
    }

    @Test("Le remplacement du chemin du volume ne redirige pas la découverte")
    func keepsOpenedVolumeWhenPathIsRedirected() async throws {
        let home = try FakeHome()
        let disk = home.root.appendingPathComponent("Volume", isDirectory: true)
        try home.text("Volume/ProjetInitial/Package.swift", "// fixture")
        try home.file("Volume/ProjetInitial/.build/debug/a.o", bytes: 4_096)
        try home.text("Autre/ProjetLeurre/Package.swift", "// fixture")
        try home.file("Autre/ProjetLeurre/.build/debug/b.o", bytes: 4_096)
        let context = try makeContext(home, disk: disk)
        let fs = FileManager.default
        try fs.moveItem(at: disk, to: home.root.appendingPathComponent("Deplace"))
        try fs.createSymbolicLink(at: disk, withDestinationURL: home.root.appendingPathComponent("Autre"))

        let candidates = await ProjectArtifactsFinder(context: context).find()

        #expect(candidates.map(\.item.owner) == ["ProjetInitial"])
    }

    private func makeContext(_ home: FakeHome, disk: URL) throws -> RuleContext {
        var context = home.context()
        let anchor = try home.openVolume(disk)
        context.volume = VolumeScope(root: anchor.url, name: "Test", fileSystem: "apfs")
        context.volume?.root = anchor.url
        context.projectRoots = [anchor.url]
        context.volumeAnchor = anchor
        return context
    }
}
