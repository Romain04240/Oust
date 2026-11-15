import Foundation
import Testing
import OustCore
import OustDuplicates
import OustDesignSystem
@testable import OustModel

@Suite("Exclusions et sélections de Doublons")
@MainActor
struct DuplicateExclusionModelTests {
    @Test("Une exclusion persiste et vide seulement les sélections issues de Doublons")
    func savesAndInvalidates() async throws {
        let defaults = MemoryDefaults()
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-exclusions-\(UUID())", isDirectory: true)
        let folder = fixture.appendingPathComponent("Prive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let app = AppModel(home: fixture, defaults: defaults)
        func sample(_ category: ItemCategory, id: String) -> CleanupItem {
            CleanupItem(id: id, title: id, detail: "", paths: [fixture.appendingPathComponent(id)],
                        category: category, owner: "", ruleID: "", safety: .review, method: .evictLocalCopy,
                        sizes: Sizes(allocated: 1, freeable: 1), lastActivity: nil, rebuild: .irreversible)
        }
        let duplicate = sample(.duplicates, id: "copie")
        let similar = sample(.similarImages, id: "similaire")
        let other = sample(.cloudFiles, id: "autre")
        app.add([duplicate, similar, other])
        #expect(app.cart.count == 3)
        #expect(app.canUseDuplicateQuickLook)
        app.duplicates = .done(Date())
        #expect(await app.excludeDuplicateFolder(folder))
        #expect(!app.canUseDuplicateQuickLook)
        #expect(app.cart == [other.id])
        #expect(app.duplicates == .idle)
        #expect(app.similarImages.phase == .idle)
        app.add([duplicate, similar])
        #expect(app.cart == [other.id])

        let reopened = AppModel(home: fixture, defaults: defaults)
        let entry = try #require(reopened.preferences.duplicateExclusions.folders.first)
        #expect(entry.isCurrent)
        #expect(!reopened.canUseDuplicateQuickLook)
        await reopened.removeDuplicateExclusion(entry.id)
        #expect(reopened.canUseDuplicateQuickLook)
        #expect(Preferences.load(home: fixture, defaults: defaults).duplicateExclusions.folders.isEmpty)
        #expect(!app.canMoveFiles && !app.canCloneDuplicates)
    }

    @Test("Une ligne obsolète ne retire pas une sélection provenant d’une autre rubrique")
    func staleSimilarToggleCannotRemoveOtherSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-stale-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("Prive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(home: root, defaults: MemoryDefaults())
        let file = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: file)
        let image = SimilarImage(url: file, logicalSize: 3, allocated: 4096, privateSize: 4096,
                                 modified: nil, captured: nil, pixelWidth: 10, pixelHeight: 10)
        let stale = SimilarImageGroup(images: [image])
        let item = CleanupItem(id: "autre", title: "photo", detail: "", paths: [file], category: .cloudFiles,
                               owner: "", ruleID: "", safety: .review, method: .evictLocalCopy,
                               sizes: Sizes(allocated: 4096, freeable: 4096), lastActivity: nil, rebuild: .irreversible)
        app.add([item])
        #expect(await app.excludeDuplicateFolder(folder))
        app.similarImages.toggle(image, in: stale)
        #expect(app.cart == [item.id])
    }

    @Test("La liste attend les lecteurs admis et révoque vignettes en attente et voisins de Coup d’œil")
    func revokesBeforePublishing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-transition-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("Prive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        let neighbor = folder.appendingPathComponent("b.txt")
        try Data([1]).write(to: file)
        try Data([2]).write(to: neighbor)
        let defaults = MemoryDefaults()
        let app = AppModel(home: root, defaults: defaults)
        let preview = FilePreview()
        preview.show(file, among: [file, neighbor])
        #expect(preview.items == [file, neighbor])
        let secondWindow = FilePreview()
        secondWindow.show(neighbor, among: [neighbor, file])
        let firstOwner = UUID()
        let secondOwner = UUID()
        let closedOwner = UUID()
        app.setDuplicatePreviewRevoker(for: secondOwner) { secondWindow.revoke() }
        app.setDuplicatePreviewRevoker(for: closedOwner) { Issue.record("Fenêtre déjà fermée") }
        app.setDuplicatePreviewRevoker(for: closedOwner, nil)
        let previous = app.duplicateReadSession
        try #require(previous.acquire())
        let (revoking, notification) = AsyncStream<Void>.makeStream()
        app.setDuplicatePreviewRevoker(for: firstOwner) {
            preview.revoke()
            notification.yield(())
        }
        let change = Task {
            defer { notification.finish() }
            return await app.excludeDuplicateFolder(folder)
        }
        for await _ in revoking {
            #expect(!app.canUseDuplicateQuickLook)
            #expect(!previous.acquire())
            #expect(Preferences.load(home: root, defaults: defaults).duplicateExclusions.folders.isEmpty)
            #expect(preview.current == nil && preview.items.isEmpty)
            #expect(secondWindow.current == nil && secondWindow.items.isEmpty)
            preview.step(1)
            #expect(preview.current == nil)
            previous.release()
            break
        }
        #expect(await change.value)
        #expect(Preferences.load(home: root, defaults: defaults).duplicateExclusions.folders.count == 1)
        #expect(!previous.acquire())
    }

    @Test("Une liste révoquée attend la fermeture du panneau natif avant toute persistance")
    func waitsForNativePanel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-native-panel-\(UUID())", isDirectory: true)
        let excluded = root.appendingPathComponent("Prive", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let visible = excluded.appendingPathComponent("copie.txt")
        try Data([1]).write(to: visible)
        let alternate = root.appendingPathComponent("visible.txt")
        try Data([2]).write(to: alternate)

        let app = AppModel(home: root, defaults: MemoryDefaults())
        let previewA = FilePreview()
        let previewB = FilePreview()
        previewA.show(alternate, among: [alternate, visible])
        previewB.show(visible, among: [visible, alternate])
        app.setDuplicatePreviewRevoker(for: UUID()) { previewA.revoke() }
        app.setDuplicatePreviewRevoker(for: UUID()) { previewB.revoke() }

        for cancel in [true, false] {
            let previous = app.duplicateReadSession
            var panelClosed = false
            let (events, observer) = AsyncStream<Void>.makeStream()
            app.duplicateNativePanelClosed = {
                observer.yield(())
                return panelClosed
            }
            let applying = Task {
                defer { observer.finish() }
                return await app.excludeDuplicateFolder(excluded)
            }
            for await _ in events {
                #expect(app.changingDuplicateExclusions)
                #expect(!app.canUseDuplicateQuickLook)
                #expect(app.preferences.duplicateExclusions.folders.isEmpty)
                #expect(app.duplicateReadSession === previous)
                let admitted = previous.acquire()
                #expect(!admitted)
                if admitted { previous.release() }
                #expect(previewA.items.isEmpty && previewB.items.isEmpty)
                if cancel {
                    applying.cancel()
                } else {
                    panelClosed = true
                }
                break
            }
            #expect(await applying.value == !cancel)
            #expect(!app.changingDuplicateExclusions)
            #expect(!app.duplicateExclusionsWaitingForQuickLook)
            #expect(app.duplicateReadSession !== previous)
            #expect(app.preferences.duplicateExclusions.folders.count == (cancel ? 0 : 1))
            #expect(!app.canMoveFiles && !app.canCloneDuplicates)
        }
    }

    @Test("Une liste illisible suspend les recherches")
    func unreadableList() async throws {
        let defaults = MemoryDefaults()
        defaults.set(Data([0xFF]), forKey: Preferences.duplicateExclusionsKey)
        let home = FileManager.default.temporaryDirectory
        let app = AppModel(home: home, defaults: defaults)
        await app.findDuplicates(in: [home])
        #expect(app.duplicateExclusionBlocked)
        #expect(!app.canUseDuplicateQuickLook)
        #expect(app.duplicates == .idle)
        #expect(!app.canMoveFiles && !app.canCloneDuplicates)
    }
}

/// Simule les valeurs persistées sans écrire dans les préférences du Mac.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
}
