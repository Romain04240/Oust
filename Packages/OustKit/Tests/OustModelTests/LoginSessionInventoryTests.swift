import Darwin
import Foundation
import Synchronization
import Testing
import OustCore
@testable import OustModel

@Suite("Inventaire partiel des éléments de connexion déclarés")
struct LoginSessionInventoryTests {
    private let uid: uid_t = 501
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let path = "/Applications/PrivatePathMarker.app"

    @Test("Douze composants modernes et une application ancienne sans promouvoir les contenants")
    func representativePartialReport() throws {
        let states = Array(repeating: "[enabled, allowed, not notified] (0x3)", count: 2)
            + Array(repeating: "[enabled, allowed, notified] (0x13)", count: 5)
            + Array(repeating: "[disabled, allowed] (0xa)", count: 2)
            + Array(repeating: "[disabled, disallowed] (0x0)", count: 2)
            + ["[enabled, disallowed] (0x1)"]
        var records = states.enumerated().map { index, state in
            record(index: index, id: identifier(index + 10), name: "Composant \(index)", disposition: state,
                url: "Contents/Library/LoginItems/PrivatePathMarker.app")
        }
        records += (0..<51).map { record(index: $0 + 20, id: identifier($0 + 100), type: "app (0x2)") }
        records.append(record(index: 80, type: "user item (0x1)", identifier: "file:///Applications/PrivatePathMarker.app"))
        let foreign = section(502, record(index: 0, id: identifier(999), name: "Autre compte"))
        let result = LoginSessionInventory.parse(section(uid, records.joined(separator: "\n")) + "\n" + foreign, uid: uid)
        guard case .partial(let entries) = result else { Issue.record("Inventaire partiel attendu"); return }
        #expect(entries.count == 13)
        #expect(entries.filter { $0.kind == .component }.count == 12)
        #expect(entries.filter { $0.kind == .application }.count == 1)
        #expect(entries.filter { $0.kind == .component && $0.isEnabled == true && $0.isAllowed == true }.count == 7)
        #expect(entries.filter { $0.kind == .component && $0.isEnabled == true && $0.isAllowed == false }.count == 1)
        #expect(!String(reflecting: result).contains("PrivatePathMarker"))
        let first = try #require(entries.first)
        #expect(Set(Mirror(reflecting: first).children.compactMap(\.label)) == ["id", "name", "kind", "isEnabled", "isAllowed"])
    }

    @Test("Les deux axes restent indépendants et ne sont jamais déduits des bits hexadécimaux",
          arguments: ["enabled", "disabled", "disallowed", "bothFalse", "enableConflict", "allowConflict", "noEnable", "noAllow", "unknown", "substring", "badSuffix", "missing"])
    func independentStates(_ variant: String) throws {
        let disposition: String?
        let expected: (Bool?, Bool?)
        switch variant {
        case "enabled": disposition = "[enabled, allowed, visible, not notified] (0x0)"; expected = (true, true)
        case "disabled": disposition = "[disabled, allowed, notified] (0x3)"; expected = (false, true)
        case "disallowed": disposition = "[enabled, disallowed] (0xa)"; expected = (true, false)
        case "bothFalse": disposition = "[disabled, disallowed] (0x3)"; expected = (false, false)
        case "enableConflict": disposition = "[enabled, disabled, allowed]"; expected = (nil, true)
        case "allowConflict": disposition = "[enabled, allowed, disallowed]"; expected = (true, nil)
        case "noEnable": disposition = "[allowed]"; expected = (nil, true)
        case "noAllow": disposition = "[enabled]"; expected = (true, nil)
        case "unknown": disposition = "[enabled, allowed, future flag]"; expected = (nil, nil)
        case "substring": disposition = "[preenabled, allowed]"; expected = (nil, nil)
        case "badSuffix": disposition = "[enabled, allowed] trailing"; expected = (nil, nil)
        default: disposition = nil; expected = (nil, nil)
        }
        let entries = try partial(section(uid, record(disposition: disposition)))
        let entry = try #require(entries.first)
        #expect(entries.count == 1 && entry.isEnabled == expected.0 && entry.isAllowed == expected.1)
    }

    @Test("Seules des cibles applicatives locales lexicalement cohérentes sont retenues",
          arguments: ["componentRaw", "componentFileURL", "componentRelative", "componentLeaf", "legacy", "legacyNoIdentifier", "trailingSlash"])
    func localApplicationShapes(_ variant: String) throws {
        let legacy = variant == "legacy" || variant == "legacyNoIdentifier"
        let url: String
        switch variant {
        case "componentFileURL": url = "file:///Applications/PrivatePathMarker.app"
        case "componentRelative": url = "Contents/Library/LoginItems/Helper fictif.app"
        case "componentLeaf": url = "Helper fictif.app"
        case "trailingSlash": url = path + "/"
        default: url = path
        }
        let identifier = variant == "legacy" ? "file:///Applications/PrivatePathMarker.app/" : nil
        let entries = try partial(section(uid, record(type: legacy ? "user item (0x1)" : "login item (0x4)",
            url: url, identifier: identifier)))
        #expect(entries == [.init(id: id, name: "Composant", kind: legacy ? .application : .component,
            isEnabled: true, isAllowed: true)])
    }

    @Test("Les champs malformés, chemins et types étrangers ne deviennent pas des éléments affichables",
          arguments: ["uuid", "nullName", "emptyName", "controlName", "bidiName", "lineName", "pathName", "urlName", "container", "daemon", "document", "server", "relative", "dotdot", "doubleSlash", "query", "fragment", "userinfo", "identifierMismatch", "relativeDotdot", "relativeDot", "relativeEmpty", "relativeBackslash", "relativeScheme", "relativeFileURL", "relativeControl"])
    func malformedEntriesAreExcluded(_ variant: String) throws {
        var text = record()
        switch variant {
        case "uuid": text = text.replacingOccurrences(of: id.uuidString, with: "not-a-uuid")
        case "nullName": text = record(name: "(null)")
        case "emptyName": text = record(name: "")
        case "controlName": text = record(name: "Compo\u{0001}sant")
        case "bidiName": text = record(name: "Compo\u{202e}sant")
        case "lineName": text = record(name: "Compo\u{2028}sant")
        case "pathName": text = record(name: path)
        case "urlName": text = record(name: "file:///Applications/Secret.app")
        case "container": text = record(type: "app (0x2)")
        case "daemon": text = record(type: "daemon (0x10)")
        case "document": text = record(url: "/Applications/Document.pdf")
        case "server": text = record(url: "file://server/Applications/Foo.app")
        case "relative": text = record(type: "user item (0x1)", url: "Applications/Foo.app")
        case "dotdot": text = record(url: "/Applications/../Foo.app")
        case "doubleSlash": text = record(url: "//server/Foo.app")
        case "query": text = record(url: "file:///Applications/Foo.app?query=1")
        case "fragment": text = record(url: "file:///Applications/Foo.app#part")
        case "userinfo": text = record(url: "file://user@/Applications/Foo.app")
        case "relativeDotdot": text = record(url: "Contents/../Foo.app")
        case "relativeDot": text = record(url: "Contents/./Foo.app")
        case "relativeEmpty": text = record(url: "Contents//Foo.app")
        case "relativeBackslash": text = record(url: "Contents\\LoginItems\\Foo.app")
        case "relativeScheme": text = record(url: "https://server/Foo.app")
        case "relativeFileURL": text = record(url: "file:Helper.app")
        case "relativeControl": text = record(url: "Contents/Bad\u{0001}.app")
        default: text = record(type: "user item (0x1)", identifier: "file:///Applications/Different.app")
        }
        #expect(try partial(section(uid, text)).isEmpty)
    }

    @Test("L'identité d'un doublon inclut les champs non exposés comme la cible",
          arguments: ["identical", "name", "path", "state", "invalid", "duplicateField"])
    func duplicateIdentities(_ variant: String) throws {
        let original = record()
        let other: String
        switch variant {
        case "name": other = record(index: 1, name: "Différent")
        case "path": other = record(index: 1, url: "/Applications/Another.app")
        case "state": other = record(index: 1, disposition: "[disabled, allowed]")
        case "invalid": other = record(index: 1, name: "(null)")
        case "duplicateField": other = record(index: 1) + "\n UUID: \(identifier(2))"
        default: other = record(index: 1)
        }
        let entries = try partial(section(uid, original + "\n" + other))
        #expect(entries.count == (variant == "identical" ? 1 : 0))
    }

    @Test("Une section UID absente, ambiguë ou illisible n'est pas un inventaire vide",
          arguments: ["silence", "foreign", "uidPrefix", "duplicate", "badHeader"])
    func unavailableScope(_ variant: String) {
        let text: String
        switch variant {
        case "foreign": text = section(502, record())
        case "uidPrefix": text = section(5010, record())
        case "duplicate": text = section(uid, record()) + "\n" + section(uid, "")
        case "badHeader": text = "Records for UID 501 : invalid\n" + record()
        default: text = " \n\t"
        }
        #expect(LoginSessionInventory.parse(text, uid: uid) == .unavailable)
    }

    @Test("Une section unique décodable reste explicitement partielle même sans entrée retenue")
    func emptySectionIsOnlyPartial() {
        #expect(LoginSessionInventory.parse(section(uid, ""), uid: uid) == .partial([]))
    }

    @Test("Un en-tête irrégulier d'un autre compte ferme toujours la section courante",
          arguments: ["Records for UID\t502 : 11111111-1111-1111-1111-111111111111", "Records for UID: 502"])
    func malformedForeignBoundary(_ boundary: String) throws {
        let text = section(uid, record()) + "\n" + boundary + "\n"
            + record(index: 1, id: identifier(2), name: "Autre compte")
        let entries = try partial(text)
        #expect(entries.count == 1 && entries.first?.id == id)
    }

    @Test("Le diagnostic et l'inventaire partagent exactement une lecture sous opt-in")
    func sharedRead() async {
        let report = section(getuid(), record())
        let calls = Mutex(0)
        let previous = CommandCancellationContext.cancelsReadOnlyCommands
        let snapshot = await LoginDiagnostics.readSession(read: {
            calls.withLock { $0 += 1 }
            #expect(CommandCancellationContext.cancelsReadOnlyCommands)
            return CommandResult(status: 0, stdout: Data(report.utf8), stderr: Data(), timedOut: false)
        })
        #expect(calls.withLock { $0 } == 1)
        #expect(snapshot.inventory == LoginSessionInventory.parse(report, uid: getuid()))
        #expect(snapshot.diagnostic == LoginDiagnostics.inspect(report, uid: getuid()))
        #expect(CommandCancellationContext.cancelsReadOnlyCommands == previous)
    }

    @Test("Une inspection de disque hors délai ne masque pas les déclarations lisibles")
    func diagnosticUnavailableKeepsInventory() async {
        let report = section(getuid(), record())
        let calls = Mutex(0)
        let snapshot = await LoginDiagnostics.readSession(read: {
            calls.withLock { $0 += 1 }
            return CommandResult(status: 0, stdout: Data(report.utf8), stderr: Data(), timedOut: false)
        }, readDiagnostic: { output, uid in
            #expect(output == report && uid == getuid())
            return nil
        })
        #expect(calls.withLock { $0 } == 1 && snapshot.diagnostic == .unavailable)
        #expect(snapshot.inventory == LoginSessionInventory.parse(report, uid: getuid()))
    }

    @Test("Un encodage illisible ne devient pas un inventaire valide par remplacement de caractères")
    func invalidEncodingIsUnavailable() async {
        var bytes = Data(section(getuid(), record()).utf8)
        bytes.append(0xff)
        let reply = CommandResult(status: 0, stdout: bytes, stderr: Data(), timedOut: false)
        let snapshot = await LoginDiagnostics.readSession(read: { reply }, readDiagnostic: { _, _ in .unavailable })
        #expect(snapshot.inventory == .unavailable)
    }

    @Test("Une session déjà annulée ne sollicite pas son lecteur")
    func alreadyCancelledSession() async {
        let calls = Mutex(0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LoginDiagnostics.readSession(read: {
                calls.withLock { $0 += 1 }
                return .notRun
            })
        }
        #expect(await task.value == .init(diagnostic: .unavailable, inventory: .unavailable))
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("Une session annulée ignore aussi un inventaire valide reçu tardivement", arguments: ["read", "diagnostic"])
    func cancelledLateSession(_ phase: String) async {
        let gate = SessionInventoryDelayedRead(); defer { gate.finish(.notRun) }
        let report = section(getuid(), record())
        let command = CommandResult(status: 0, stdout: Data(report.utf8), stderr: Data(), timedOut: false)
        let task = Task {
            if phase == "read" {
                return await LoginDiagnostics.readSession(read: { await gate.read() })
            }
            return await LoginDiagnostics.readSession(read: { command }, readDiagnostic: { _, _ in
                _ = await gate.read()
                return .checked(volumeIndeterminate: [])
            })
        }
        await gate.waitUntilEntered()
        task.cancel()
        gate.finish(command)
        #expect(await task.value == .init(diagnostic: .unavailable, inventory: .unavailable))
    }

    @Test("Les erreurs de commande rendent les deux vues indisponibles", arguments: ["status", "stderr", "timeout", "notRun"])
    func failedSession(_ variant: String) async {
        var command = CommandResult(status: 0, stdout: Data(section(getuid(), record()).utf8), stderr: Data(), timedOut: false)
        switch variant {
        case "status": command.status = 1
        case "stderr": command.stderr = Data("warning".utf8)
        case "timeout": command.timedOut = true
        default: command = .notRun
        }
        let reply = command
        let snapshot = await LoginDiagnostics.readSession(read: { reply })
        #expect(snapshot == .init(diagnostic: .unavailable, inventory: .unavailable))
    }

    private func identifier(_ number: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012d", number))!
    }

    private func section(_ uid: uid_t, _ records: String) -> String {
        " Records for UID \(uid) : 11111111-1111-1111-1111-111111111111\n\(records)"
    }

    private func record(index: Int = 0, id: UUID? = nil, name: String = "Composant", type: String = "login item (0x4)",
                        disposition: String? = "[enabled, allowed, not notified] (0x3)", url: String? = nil,
                        identifier: String? = nil) -> String {
        """
         #\(index):
             UUID: \(id ?? self.id)
             Name: \(name)
             Type: \(type)
             URL: \(url ?? path)
        """ + (disposition.map { "\n Disposition: " + $0 } ?? "")
            + (identifier.map { "\n Identifier: " + $0 } ?? "")
    }

    private func partial(_ text: String) throws -> [LoginSessionInventory.Entry] {
        guard case .partial(let entries) = LoginSessionInventory.parse(text, uid: uid) else {
            Issue.record("Inventaire partiel attendu")
            throw InventoryFixtureError.unavailable
        }
        return entries
    }
}

private enum InventoryFixtureError: Error { case unavailable }

private final class SessionInventoryDelayedRead: Sendable {
    private struct State {
        var entered = false
        var continuation: CheckedContinuation<CommandResult, Never>?
        var prepared: CommandResult?
    }
    private let state = Mutex(State())

    func read() async -> CommandResult {
        await withCheckedContinuation { continuation in
            let prepared: CommandResult? = state.withLock {
                $0.entered = true
                if let prepared = $0.prepared { return prepared }
                $0.continuation = continuation
                return nil as CommandResult?
            }
            if let prepared { continuation.resume(returning: prepared) }
        }
    }

    func finish(_ result: CommandResult) {
        let continuation = state.withLock {
            $0.prepared = result
            let pending = $0.continuation
            $0.continuation = nil
            return pending
        }
        continuation?.resume(returning: result)
    }

    func waitUntilEntered() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !state.withLock({ $0.entered }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(state.withLock { $0.entered })
    }
}
