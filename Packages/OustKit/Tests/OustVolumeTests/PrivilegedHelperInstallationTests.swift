import Foundation
import Testing
@testable import OustVolume

@Suite("Composant privilégié : diagnostic sans installation")
struct PrivilegedHelperInstallationTests {
    @Test("Une empreinte différente propose une réparation sans autoriser un service absent ou refusé")
    func changedFingerprintOnlyForApprovedService() {
        #expect(PrivilegedHelper.installationUpdate(registration: .notInstalled,
                    currentFingerprint: "new", registeredFingerprint: "old") == .none)
        #expect(PrivilegedHelper.installationUpdate(registration: .awaitingApproval,
                    currentFingerprint: "new", registeredFingerprint: "old") == .none)
        #expect(PrivilegedHelper.installationUpdate(registration: .enabled,
                    currentFingerprint: "new", registeredFingerprint: "old") == .deferred)
        #expect(PrivilegedHelper.installationUpdate(registration: .enabled,
                    currentFingerprint: "new", registeredFingerprint: nil) == .deferred)
    }

    @Test("Une empreinte inchangée ou illisible ne propose pas de mise à jour")
    func unchangedOrUnreadableFingerprint() {
        #expect(PrivilegedHelper.installationUpdate(registration: .enabled,
                    currentFingerprint: "same", registeredFingerprint: "same") == .none)
        #expect(PrivilegedHelper.installationUpdate(registration: .enabled,
                    currentFingerprint: nil, registeredFingerprint: "old") == .none)
    }

    @Test("Le paquet incomplet et la configuration altérée sont identifiés avant toute installation")
    func bundleDiagnostics() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("oust-helper-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(PrivilegedHelper.inspectBundle(at: temporary) == .incompleteBundle)
        let executable = temporary.appendingPathComponent("Contents/MacOS/oust-helper")
        let plist = temporary.appendingPathComponent("Contents/Library/LaunchDaemons/fr.meaillais.oust.helper.plist")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not executable code".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var configuration: [String: Any] = ["Label": "foreign", "BundleProgram": "Contents/MacOS/oust-helper",
                                            "MachServices": ["fr.meaillais.oust.helper": true]]
        try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0).write(to: plist)
        #expect(PrivilegedHelper.inspectBundle(at: temporary) == .invalidConfiguration)
        configuration["Label"] = "fr.meaillais.oust.helper"
        try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0).write(to: plist)
        #expect(PrivilegedHelper.inspectBundle(at: temporary) == .invalidSignature)
        configuration["ProgramArguments"] = ["/usr/bin/true"]
        try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0).write(to: plist)
        #expect(PrivilegedHelper.inspectBundle(at: temporary) == .invalidConfiguration)
    }

}
