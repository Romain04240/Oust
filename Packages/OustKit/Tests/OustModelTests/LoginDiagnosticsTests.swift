import Foundation
import Testing
@testable import OustModel

struct LoginDiagnosticsTests {
    @Test("Un paquet local supprimé est signalé avec un volume d’origine indéterminé")
    func missingBundle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Démo locale.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let entry = record(path: app.path, name: "Démo locale")
        let report = section(501, entry)
        #expect(LoginDiagnostics.inspect(report, uid: 501) == .checked(volumeIndeterminate: []))

        try FileManager.default.removeItem(at: app)
        #expect(LoginDiagnostics.inspect(report, uid: 501) == .checked(volumeIndeterminate: [
            .init(id: id, name: "Démo locale"),
        ]))
    }

    @Test("Le dossier local laissé par un montage personnalisé ne confirme pas le volume d’origine")
    func leftoverMountDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mount = directory.appendingPathComponent("Montage", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let app = mount.appendingPathComponent("Démo externe.app", isDirectory: true)
        let report = section(501, record(path: app.path, name: "Démo externe"))

        #expect(LoginDiagnostics.inspect(report, uid: 501) == .checked(volumeIndeterminate: [
            .init(id: id, name: "Démo externe"),
        ]))
    }

    @Test("Une cible incertaine ou modifiée par redirection ne devient pas une absence confirmée")
    func uncertainTargets() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("Lien")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let app = directory.appendingPathComponent("Lien.app")
        try FileManager.default.createSymbolicLink(
            at: app, withDestinationURL: directory.appendingPathComponent("Supprimée.app")
        )
        let paths = [
            app.path,
            link.appendingPathComponent("Supprimée.app").path,
            directory.appendingPathComponent("Parent-absent/Supprimée.app").path,
            directory.appendingPathComponent("CloudStorage/Supprimée.app").path,
            "/Volumes/Oust-QA-\(UUID())/Supprimée.app",
            "/System/Volumes/Data/volumes/Oust-QA-\(UUID())/Supprimée.app",
        ]
        let records = paths.enumerated().map { record(path: $0.element, index: $0.offset, id: UUID()) }
        #expect(LoginDiagnostics.inspect(section(501, records.joined(separator: "\n")), uid: 501)
                == .checked(volumeIndeterminate: []))
    }

    @Test("Seules les inscriptions actives du compte courant et à cible cohérente sont retenues")
    func reportScope() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("Absente.app").path
        let records = [
            record(path: path, type: "login item (0x4)", index: 0),
            record(path: path, disposition: "[disabled, allowed, notified] (0xa)", index: 1),
            record(path: path, identifier: "file:///Autre.app", index: 2),
            record(path: path, identifier: "file://serveur" + path, index: 3),
        ]
        let otherUser = section(502, record(path: path))
        let report = section(501, records.joined(separator: "\n")) + "\n" + otherUser
        #expect(LoginDiagnostics.inspect(report, uid: 501) == .checked(volumeIndeterminate: []))
        #expect(LoginDiagnostics.inspect(otherUser, uid: 501) == .unavailable)
        #expect(LoginDiagnostics.inspect("Résultat illisible", uid: 501) == .unavailable)
    }

    private let id = UUID()

    private func temporaryDirectory() throws -> URL {
        // Foundation réécrit /private/var en /var, un lien que le diagnostic refuse.
        let location = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("oust-login-diagnostics-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        return location
    }

    private func section(_ uid: UInt32, _ records: String) -> String {
        " Records for UID \(uid) : \(UUID())\n\(records)"
    }

    private func record(path: String, name: String = "Application", type: String = "user item (0x1)",
                        disposition: String = "[enabled, allowed, not notified] (0x3)",
                        identifier: String? = nil, index: Int = 0, id: UUID? = nil) -> String {
        """
         #\(index):
                         UUID: \(id ?? self.id)
                         Name: \(name)
                         Type: \(type)
                  Disposition: \(disposition)
                   Identifier: \(identifier ?? URL(fileURLWithPath: path, isDirectory: true).absoluteString)
                          URL: \(path)
        """
    }
}
