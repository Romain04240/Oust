import Darwin
import Foundation
import OustSafety
import Synchronization
import Testing
@testable import OustModel

@Suite(.serialized)
struct DocumentVersionHistoryTests {
    @Test("L’historique affiche les deux révisions locales d’un document fictif")
    func previousRevisions() async throws {
        let manager = FileManager.default
        let fixture = try emptyFixture()
        defer { try? manager.removeItem(at: fixture) }

        let document = fixture.appendingPathComponent("Document.txt")
        let contents = fixture.appendingPathComponent("Revision.txt")
        try "Texte courant".write(to: document, atomically: false, encoding: .utf8)
        try "Première révision".write(to: contents, atomically: false, encoding: .utf8)
        let first = try addRevision(of: document, contents: contents)
        defer { try? first.remove() }
        try "Deuxième révision".write(to: contents, atomically: false, encoding: .utf8)
        let second = try addRevision(of: document, contents: contents)
        defer { try? second.remove() }

        let facts = try #require(FileFacts.of(document.path))
        #expect(facts.allocated < 100_000)
        let history = try #require(await DocumentVersionHistory(url: document).prepare())
        let confirmedFacts = try #require(FileFacts.of(history.path))
        #expect(confirmedFacts.device == facts.device)
        #expect(confirmedFacts.inode == facts.inode)
        #expect(history.byteCount == facts.size)
        let dates = try #require(await history.revisionDates())
        let firstDate = try #require(first.modificationDate)
        let secondDate = try #require(second.modificationDate)
        #expect(dates.count == 2)
        #expect(dates.compactMap { $0 } == [firstDate, secondDate].sorted(by: >))
        #expect(try String(contentsOf: document, encoding: .utf8) == "Texte courant")
        #expect(NSFileVersion.otherVersionsOfItem(at: document)?.count == 2)
    }

    @Test("L’historique d’un document sélectionné refuse son remplacement au même chemin")
    func replacedDocument() async throws {
        let manager = FileManager.default
        let fixture = try emptyFixture()
        defer { try? manager.removeItem(at: fixture) }
        let selected = fixture.appendingPathComponent("Document.txt")
        let original = fixture.appendingPathComponent("Original.txt")
        try Data([1]).write(to: selected)

        let history = try #require(await DocumentVersionHistory(url: selected).prepare())
        try manager.moveItem(at: selected, to: original)
        try Data([2]).write(to: selected)

        let attemptedRead = Mutex(false)
        #expect(await history.revisionDates { _ in
            attemptedRead.withLock { $0 = true }
            return []
        } == nil)
        #expect(!attemptedRead.withLock { $0 })
    }

    @Test("L’historique rejette le résultat si le parent est déplacé puis remis pendant la lecture")
    func movedParentDuringRead() async throws {
        let manager = FileManager.default
        let fixture = try emptyFixture()
        defer { try? manager.removeItem(at: fixture) }
        let parent = fixture.appendingPathComponent("Parent")
        let moved = fixture.appendingPathComponent("Déplacé")
        try manager.createDirectory(at: parent, withIntermediateDirectories: false)
        let selected = parent.appendingPathComponent("Document.txt")
        try Data([1]).write(to: selected)

        let history = try #require(await DocumentVersionHistory(url: selected).prepare())
        let move = Mutex<Result<Void, Error>?>(nil)
        let dates = await history.revisionDates { _ in
            move.withLock { result in
                result = Result {
                    try FileManager.default.moveItem(at: parent, to: moved)
                    try FileManager.default.moveItem(at: moved, to: parent)
                }
            }
            return [Date()]
        }
        try #require(move.withLock { $0 }).get()
        #expect(dates == nil)
        #expect(try Data(contentsOf: selected) == Data([1]))
    }

    @Test("Une modification voisine laisse les révisions du document sélectionné accessibles")
    func siblingChanges() async throws {
        let fixture = try emptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let document = fixture.appendingPathComponent("Document.txt")
        let revision = fixture.appendingPathComponent("Revision.txt")
        try Data([1]).write(to: document)
        try Data([2]).write(to: revision)
        let version = try addRevision(of: document, contents: revision)
        defer { try? version.remove() }

        let history = try #require(await DocumentVersionHistory(url: document).prepare())
        try Data([3]).write(to: fixture.appendingPathComponent("Voisin.txt"))
        let dates = try #require(await history.revisionDates())
        #expect(dates == [version.modificationDate])
    }

    @Test("Le coordinateur est limité aux métadonnées locales, sans demander d’enregistrement")
    func localMetadataOnly() {
        #expect(DocumentVersionHistory.readOptions.contains(.immediatelyAvailableMetadataOnly))
        #expect(DocumentVersionHistory.readOptions.contains(.withoutChanges))
    }

    @Test("Deux lectures coordonnées bloquées gardent leur place après annulation")
    func cancelledReadSaturation() async throws {
        let fixture = try emptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let document = fixture.appendingPathComponent("Document.txt")
        let otherDocument = fixture.appendingPathComponent("Autre.txt")
        try Data([1]).write(to: document)
        try Data([2]).write(to: otherDocument)

        let selection = DocumentVersionHistory(url: document)
        let first = try #require(await selection.prepare())
        let second = try #require(await DocumentVersionHistory(url: otherDocument).prepare())
        let started = AsyncStream<Bool>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let blocked: @Sendable (URL) -> [Date?]? = { _ in
            started.continuation.yield(true)
            _ = release.wait(timeout: .now() + 12)
            return [Date()]
        }
        let firstRead = Task {
            let dates = await first.revisionDates(read: blocked)
            completed.continuation.yield(dates == nil)
        }
        let secondRead = Task {
            let dates = await second.revisionDates(read: blocked)
            completed.continuation.yield(dates == nil)
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            started.continuation.finish()
            completed.continuation.finish()
        }
        var starts = started.stream.makeAsyncIterator()
        #expect(await starts.next() == true)
        #expect(await starts.next() == true)
        firstRead.cancel()
        secondRead.cancel()
        var completions = completed.stream.makeAsyncIterator()
        #expect(await completions.next() == true)
        #expect(await completions.next() == true)
        #expect(await selection.prepare() == nil)
        let attemptedRead = Mutex(false)
        #expect(await first.revisionDates { _ in
            attemptedRead.withLock { $0 = true }
            return []
        } == nil)
        #expect(!attemptedRead.withLock { $0 })
        release.signal()
        release.signal()
        timeout.cancel()
        await firstRead.value
        await secondRead.value
        #expect(await waitForPreparation(selection))
    }

    @Test("L’annulation libère la lecture en attente d’un éditeur")
    func cancelledCoordination() async throws {
        let fixture = try emptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let document = fixture.appendingPathComponent("Document.txt")
        try Data([1]).write(to: document)
        let coordinatedURL = document.resolvingSymlinksInPath()
        let presenter = WaitingHistoryPresenter(url: coordinatedURL)
        NSFileCoordinator.addFilePresenter(presenter)
        defer {
            presenter.release.signal()
            NSFileCoordinator.removeFilePresenter(presenter)
        }

        let selection = DocumentVersionHistory(url: document)
        let history = try #require(await selection.prepare())
        let blockerStarted = AsyncStream<Bool>.makeStream()
        let blockerRelease = DispatchSemaphore(value: 0)
        let blocker = Task {
            await selection.prepare { url in
                blockerStarted.continuation.yield(true)
                _ = blockerRelease.wait(timeout: .now() + 12)
                return url
            }
        }
        defer { blockerRelease.signal() }
        let completion = AsyncStream<Bool>.makeStream()
        let attemptedRead = Mutex(false)
        let task = Task {
            let result = await history.revisionDates { _ in
                attemptedRead.withLock { $0 = true }
                return [Date()]
            }
            completion.continuation.yield(result == nil)
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            blockerStarted.continuation.finish()
            presenter.started.continuation.finish()
            completion.continuation.finish()
        }
        var blockerStart = blockerStarted.stream.makeAsyncIterator()
        #expect(await blockerStart.next() == true)
        var start = presenter.started.stream.makeAsyncIterator()
        let waiting = await start.next()
        #expect(await selection.prepare() == nil)
        task.cancel()
        var result = completion.stream.makeAsyncIterator()
        let wasCancelled = await result.next()
        // Le présentateur est encore bloqué et la seconde place aussi.
        // Seul le rappel d’annulation de Foundation peut libérer la place.
        #expect(await waitForPreparation(selection))
        presenter.release.signal()
        blocker.cancel()
        blockerRelease.signal()
        timeout.cancel()
        await task.value
        _ = await blocker.value
        #expect(waiting == true)
        #expect(wasCancelled == true)
        #expect(!attemptedRead.withLock { $0 })
    }

    private func waitForPreparation(_ document: DocumentVersionHistory) async -> Bool {
        for _ in 0..<100 {
            if await document.prepare() != nil { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("Le premier accès au chemin se fait en arrière-plan, avec la matérialisation désactivée")
    @MainActor
    func protectedPreparation() async throws {
        let fixture = try emptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let document = fixture.appendingPathComponent("Document.txt")
        try Data([1]).write(to: document)

        let result = await DocumentVersionHistory(url: document).prepare { url in
            #expect(!Thread.isMainThread)
            #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
                    == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            return PathGuard.withResolvedParent(url)
        }
        let prepared = try #require(result)
        let dates = await prepared.revisionDates { _ in
            #expect(!Thread.isMainThread)
            #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
                    == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            return []
        }
        #expect(dates == [])
    }

    @Test("Une préparation annulée rend la main et deux accès bloqués refusent les nouvelles demandes")
    @MainActor
    func cancelledPreparation() async throws {
        let fixture = try emptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let document = fixture.appendingPathComponent("Document.txt")
        try Data([1]).write(to: document)
        let history = DocumentVersionHistory(url: document)
        let started = AsyncStream<Bool>.makeStream()
        let completions = AsyncStream<String>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let blocked: @Sendable (URL) -> URL? = { url in
            started.continuation.yield(true)
            _ = release.wait(timeout: .now() + 10)
            return url
        }
        let first = Task {
            if await history.prepare(resolve: blocked) == nil { completions.continuation.yield("first") }
        }
        let second = Task {
            if await history.prepare(resolve: blocked) == nil { completions.continuation.yield("second") }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            started.continuation.finish()
            completions.continuation.finish()
        }
        var starts = started.stream.makeAsyncIterator()
        #expect(await starts.next() == true)
        #expect(await starts.next() == true)
        first.cancel()
        second.cancel()
        let third = Task {
            if await history.prepare() == nil { completions.continuation.yield("third") }
        }
        var arrivals = completions.stream.makeAsyncIterator()
        var returned: Set<String> = []
        for _ in 0..<3 {
            if let label = await arrivals.next() { returned.insert(label) }
        }
        release.signal()
        release.signal()
        timeout.cancel()
        await first.value
        await second.value
        await third.value
        #expect(returned == ["first", "second", "third"])
    }

    private func emptyFixture() throws -> URL {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("oust-document-history-\(UUID())")
        try manager.createDirectory(at: fixture, withIntermediateDirectories: false)
        return fixture
    }

    private func addRevision(of document: URL, contents: URL) throws -> NSFileVersion {
        var requestError: NSError?
        var result: Result<NSFileVersion, Error>?
        NSFileCoordinator().coordinate(writingItemAt: document, options: [], error: &requestError) { target in
            result = Result { try NSFileVersion.addOfItem(at: target, withContentsOf: contents, options: []) }
        }
        if let requestError { throw requestError }
        return try #require(result).get()
    }
}

private final class WaitingHistoryPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let started = AsyncStream<Bool>.makeStream()
    let release = DispatchSemaphore(value: 0)

    init(url: URL) { presentedItemURL = url }

    func relinquishPresentedItem(toReader reader: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        started.continuation.yield(true)
        _ = release.wait(timeout: .now() + 8)
        reader(nil)
    }
}
