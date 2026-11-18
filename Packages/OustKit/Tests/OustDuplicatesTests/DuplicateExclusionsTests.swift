import Darwin
import Foundation
import Testing
@testable import OustDuplicates
import OustCore
import OustScan

@Suite("Les dossiers exclus de Doublons")
struct DuplicateExclusionsTests {
    @Test("Identiques conserve le dossier ouvert si son ancien chemin est redirigé")
    func exactStaysOnOpenedRoot() async throws {
        let pile = try Pile()
        let elsewhere = try Pile()
        let original = try pile.file("Dossier/A.bin").deletingLastPathComponent()
        _ = try pile.file("Dossier/B.bin")
        _ = try elsewhere.file("Redirection-Un.bin", seed: 33)
        _ = try elsewhere.file("Redirection-Deux.bin", seed: 33)
        let root = try openedRoot(original)
        let moved = pile.root.appendingPathComponent("Original")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: elsewhere.root)
        var options = DuplicateOptions(roots: [root.url])
        options.exclusions.analysisRoots = [root]

        let groups = await DuplicateFinder.find(options)
        #expect(groups.count == 1)
        #expect(Set(groups.flatMap(\.files).map { $0.url.lastPathComponent }) == ["A.bin", "B.bin"])
    }

    @Test("Images similaires ignore une redirection de dossier après l’admission")
    func similarStaysOnOpenedRoot() async throws {
        let pile = try ImageFolder()
        let other = try ImageFolder()
        let first = try pile.image("Dossier/Original.jpg", Drawing.landscape())
        _ = try pile.image("Dossier/Original copie.jpg", Drawing.landscape(), quality: 0.7)
        _ = try other.image("Redirection.jpg", Drawing.city())
        _ = try other.image("Redirection copie.jpg", Drawing.city(), quality: 0.7)
        let path = first.deletingLastPathComponent()
        let root = try openedRoot(path)
        try FileManager.default.moveItem(at: path, to: pile.root.appendingPathComponent("Original"))
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: other.root)
        var options = pile.options()
        options.roots = [root.url]
        options.exclusions.analysisRoots = [root]

        let found = await SimilarImageFinder.find(options)
        #expect(found.examined == 2)
        #expect(Set(found.groups.flatMap(\.images).map { $0.url.lastPathComponent })
                == ["Original.jpg", "Original copie.jpg"])
    }

    private func openedRoot(_ url: URL) throws -> AnalysisRoot {
        let path = try #require(realpath(url.path, nil))
        defer { free(path) }
        return try #require(AnalysisRoot(URL(fileURLWithPath: String(cString: path), isDirectory: true)))
    }

    @Test("Coup d’œil reçoit des copies limitées et refuse un original remplacé")
    func quickLookUsesPrivateBoundCopies() async throws {
        let pile = try Pile()
        let first = try pile.file("Premiere.bin", bytes: 4096)
        _ = try pile.file("Seconde.bin", bytes: 4096)
        let root = try openedRoot(pile.root)
        var options = DuplicateOptions(roots: [root.url], minimumSize: 1)
        options.exclusions.analysisRoots = [root]
        let groups = await DuplicateFinder.find(options)
        let group = try #require(groups.first)
        let selected = try #require(group.files.first(where: { $0.url.lastPathComponent == first.lastPathComponent }))
        let sources = group.files.map(DuplicatePreviewCopies.Source.init)
        #expect(DuplicatePreviewCopies.prepare(selected.url, sources: sources, exclusions: options.exclusions,
                                               maximumFileBytes: 4095) == nil)
        var owner = DuplicatePreviewCopies.prepare(selected.url, sources: sources, exclusions: options.exclusions,
                                                   maximumFileBytes: 4096, maximumGroupBytes: 4096)
        let copy = try #require(owner?.urls[selected.url])
        #expect(owner?.urls.count == 1)
        #expect(copy != selected.url)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: selected.url))
        var info = stat()
        #expect(lstat(copy.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        try FileManager.default.moveItem(at: selected.url, to: pile.root.appendingPathComponent("Original.bin"))
        _ = try pile.file(first.lastPathComponent, bytes: 4096, seed: 42)
        #expect(DuplicatePreviewCopies.prepare(selected.url, sources: sources, exclusions: options.exclusions) == nil)
        #expect(try Data(contentsOf: copy) != Data(contentsOf: selected.url))
        owner = nil
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test("Le nettoyage d’un aperçu laisse intact un dossier de remplacement")
    func previewCleanupKeepsReplacement() async throws {
        let pile = try Pile()
        _ = try pile.file("Un.txt", bytes: 4096)
        _ = try pile.file("Deux.txt", bytes: 4096)
        let root = try openedRoot(pile.root)
        var options = DuplicateOptions(roots: [root.url], minimumSize: 1)
        options.exclusions.analysisRoots = [root]
        let files = try #require(await DuplicateFinder.find(options).first?.files)
        let requested = try #require(files.first?.url)
        var owner = DuplicatePreviewCopies.prepare(requested, sources: files.map(DuplicatePreviewCopies.Source.init),
                                                   exclusions: options.exclusions, maximumGroupBytes: 8192)
        let copy = try #require(owner?.urls[requested])
        let original = copy.deletingLastPathComponent().deletingLastPathComponent()
        let moved = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.moveItem(at: original, to: moved)
        defer { try? fm.removeItem(at: moved); try? fm.removeItem(at: original) }
        try fm.createDirectory(at: original, withIntermediateDirectories: false)
        let marker = original.appendingPathComponent("Temoin.txt")
        try Data([12]).write(to: marker)
        owner = nil
        #expect(fm.fileExists(atPath: marker.path))
        #expect(!fm.fileExists(atPath: moved.appendingPathComponent("0").appendingPathComponent(copy.lastPathComponent).path))
    }

    @Test("Identiques : la lecture directe et l'arbre suivent la même exclusion")
    func bothExactPaths() async throws {
        let pile = try Pile()
        let hidden = try pile.file("Prive/interne/cache.bin")
        let sibling = try pile.file("Prive-archive/copier.bin")
        let other = try pile.file("Autre/copier.bin")
        let root = pile.root.appendingPathComponent("Prive", isDirectory: true)
        let entry = try #require(DuplicateExclusion(folder: root))
        var options = pile.options
        options.exclusions = DuplicateExclusions(folders: [entry])
        let tree = await Scanner.scan([pile.root], options: ScanOptions(leafThreshold: 100_000)).roots[0]
        for source in [nil, tree] {
            let result = await DuplicateFinder.find(options, tree: source)
            #expect(result.count == 1)
            #expect(Set(result.flatMap(\.files).map { $0.url.pathComponents.suffix(2) })
                    == [sibling.pathComponents.suffix(2), other.pathComponents.suffix(2)])
        }
        options.roots = [hidden.deletingLastPathComponent()]
        let progress = DuplicateProgress()
        #expect(await DuplicateFinder.find(options, tree: tree, progress: progress).isEmpty)
        #expect(progress.filesExamined == 0)

        options.roots = [pile.root]
        progress.cancel()
        #expect(await DuplicateFinder.find(options, progress: progress).isEmpty)
        #expect(progress.filesHashed == 0)
    }

    @Test("Images similaires : ni la racine exclue ni un lien vers elle ne sont lus")
    func similarListing() throws {
        let pile = try Pile()
        _ = try pile.file("Prive/interne/test.png")
        let shown = try pile.file("Prive-sauvegarde/test.png")
        let root = pile.root.appendingPathComponent("Prive", isDirectory: true)
        let alias = pile.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let entry = try #require(DuplicateExclusion(folder: root))
        #expect(DuplicateExclusion(folder: alias) == nil)
        var options = SimilarImageOptions(roots: [pile.root, root.appendingPathComponent("interne"), alias])
        options.exclusions = DuplicateExclusions(folders: [entry])
        let files = SimilarImageFinder.collect(options, progress: SimilarImageProgress()).files
        #expect(files.map { $0.url.path } == [shown.path])
    }

    @Test("Renommage, remplacement et lien physique : le doute bloque")
    func changedFolderDoesNotOpen() async throws {
        let pile = try Pile()
        let hidden = try pile.file("Prive/test.bin")
        let root = hidden.deletingLastPathComponent()
        let entry = try #require(DuplicateExclusion(folder: root))
        let exclusions = DuplicateExclusions(folders: [entry])
        let linked = pile.root.appendingPathComponent("lien.bin")
        #expect(link(hidden.path, linked.path) == 0)
        #expect(!exclusions.permitsFile(linked))

        let renamed = pile.root.appendingPathComponent("renomme")
        try FileManager.default.moveItem(at: root, to: renamed)
        _ = try pile.file("Prive/nouveau.bin")
        #expect(!entry.isCurrent)
        #expect(!exclusions.permitsDirectory(renamed))
        #expect(!exclusions.canSearch([pile.root]))
        var options = pile.options
        options.exclusions = exclusions
        let progress = DuplicateProgress()
        #expect(await DuplicateFinder.find(options, progress: progress).isEmpty)
        #expect(progress.filesHashed == 0)
    }

    @Test("Une ouverture abandonnée ne transmet aucun octet quand le nom ou le parent change")
    func replacementBetweenValidationAndOpen() throws {
        for replaceParent in [false, true] {
            let pile = try Pile()
            let file = try pile.file("Visible/test.bin")
            let excluded = try pile.file("Prive/test.bin", seed: 9).deletingLastPathComponent()
            let entry = try #require(DuplicateExclusion(folder: excluded))
            let policy = DuplicateExclusions(folders: [entry])
            let expected = try #require(policy.readIdentity(file))
            let parent = file.deletingLastPathComponent()
            var attempted = false
            let result: Data? = policy.withRead(file, expected: expected, beforeOpen: {
                do {
                    if replaceParent {
                        try FileManager.default.moveItem(at: parent, to: pile.root.appendingPathComponent("Original"))
                        _ = try pile.file("Visible/test.bin", seed: 8)
                    } else {
                        try FileManager.default.moveItem(at: file, to: parent.appendingPathComponent("original.bin"))
                        _ = try pile.file("Visible/test.bin", seed: 8)
                    }
                    attempted = true
                } catch { Issue.record("Modification du dossier fictif impossible : \(error)") }
            }) { _, _ in
                Issue.record("Aucun lecteur ne doit recevoir le fichier après le remplacement")
                return Data()
            }
            #expect(attempted)
            #expect(result == nil)
        }
    }

    @Test("ImageIO décode une vraie image fictive depuis le descripteur et refuse un ancien résultat remplacé")
    func boundImageAndStaleThumbnail() async throws {
        let pile = try ImageFolder()
        let first = try pile.image("Visible/IMG_1.jpg", Drawing.landscape())
        _ = try pile.image("Visible/IMG_1 copie.jpg", Drawing.landscape(), quality: 0.7)
        let excluded = try pile.image("Prive/cache.jpg", Drawing.city()).deletingLastPathComponent()
        let entry = try #require(DuplicateExclusion(folder: excluded))
        let policy = DuplicateExclusions(folders: [entry])
        var options = pile.options()
        options.exclusions = policy
        let found = await SimilarImageFinder.find(options)
        #expect(found.examined == 2)
        let image = try #require(found.groups.flatMap(\.images).first { $0.url.lastPathComponent == first.lastPathComponent })
        #expect(ImageReader.thumbnail(of: image, side: 120, exclusions: policy) != nil)

        try FileManager.default.moveItem(at: first, to: pile.root.appendingPathComponent("ancienne.jpg"))
        _ = try pile.image("Visible/IMG_1.jpg", Drawing.city())
        #expect(ImageReader.thumbnail(of: image, side: 120, exclusions: policy) == nil)
    }

    @Test("Une taille privée reste liée au fichier lu, même si une feuille indexée conserve son ancienne taille")
    func staleTreeAndStorage() async throws {
        let pile = try Pile()
        let original = try pile.file("Visible/test.bin")
        _ = try pile.file("Copie/test.bin")
        let excluded = try pile.file("Prive/test.bin", seed: 9).deletingLastPathComponent()
        let entry = try #require(DuplicateExclusion(folder: excluded))
        let policy = DuplicateExclusions(folders: [entry])
        let expected = try #require(policy.readIdentity(original))
        let measured = try #require(policy.storage(of: original, expected: expected))
        #expect(measured.allocated > 0)
        let tree = await Scanner.scan([pile.root], options: ScanOptions(leafThreshold: 100_000)).roots[0]
        let backup = excluded.appendingPathComponent("ancien.bin")
        try FileManager.default.moveItem(at: original, to: backup)
        _ = try pile.file("Visible/test.bin")
        #expect(policy.storage(of: original, expected: expected) == nil)
        var options = pile.options
        options.exclusions = policy
        #expect(await DuplicateFinder.find(options, tree: tree).isEmpty)
    }

    @Test("Une exclusion étrangère au groupe conserve la déduplication APFS dans les trois parcours")
    func cloneDeduplicationWithExclusions() async throws {
        let pile = try Pile()
        let original = try pile.file("a/original.bin")
        let clone = pile.root.appendingPathComponent("clone.bin")
        try #require(clonefile(original.path, clone.path, 0) == 0)
        let folder = try pile.file("Prive/autre.bin").deletingLastPathComponent()
        let entry = try #require(DuplicateExclusion(folder: folder))
        var options = pile.options
        options.exclusions = DuplicateExclusions(folders: [entry])
        let tree = await Scanner.scan([pile.root], options: ScanOptions(leafThreshold: 100_000)).roots[0]
        #expect(await DuplicateFinder.find(options).isEmpty)
        #expect(await DuplicateFinder.find(options, tree: tree).isEmpty)

        let photos = try ImageFolder()
        let picture = try photos.image("original.jpg", Drawing.landscape())
        let pictureClone = photos.root.appendingPathComponent("original copie.jpg")
        try #require(clonefile(picture.path, pictureClone.path, 0) == 0)
        let hidden = try photos.image("Prive/autre.jpg", Drawing.city()).deletingLastPathComponent()
        let imageEntry = try #require(DuplicateExclusion(folder: hidden))
        var similar = photos.options()
        similar.exclusions = DuplicateExclusions(folders: [imageEntry])
        let found = await SimilarImageFinder.find(similar)
        #expect(found.examined == 1)
        #expect(found.groups.isEmpty)
    }

    @Test("Une mesure inconnue ne compte aucun gain et ne classe pas le groupe parmi les clones")
    func unknownSizeKeepsGroup() throws {
        let pile = try Pile()
        let original = try pile.file("original.png")
        let copy = try pile.file("copie.png")
        let best = SimilarImage(url: original, logicalSize: 1024, allocated: 4096, privateSize: 4096,
                                modified: nil, captured: nil, pixelWidth: 640, pixelHeight: 640)
        func group(size: Int64?, clone: Bool) -> SimilarImageGroup {
            SimilarImageGroup(images: [best, SimilarImage(
                url: copy, logicalSize: 1024, allocated: 4096, privateSize: size, modified: nil, captured: nil,
                pixelWidth: 320, pixelHeight: 320, confirmedFullClone: clone
            )])
        }
        let unknown = group(size: nil, clone: false)
        #expect(unknown.potential == 0)
        #expect(!unknown.isCloneOnly)
        #expect(unknown.images.last?.privateSizeKnown == false)
        #expect(unknown.images.last?.isClone == false)
        #expect(group(size: 0, clone: false).isCloneOnly == false)
        #expect(group(size: 0, clone: true).isCloneOnly)
    }
}
