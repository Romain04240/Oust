import Darwin
import Foundation
import Testing
@testable import OustClean
import OustCore
import OustSafety

extension Bench {
    /// Du texte qui se compresse comme du code : un paragraphe au hasard, répété.
    @discardableResult
    func text(_ relative: String, kilobytes: Int) throws -> URL {
        let vocabulary = ["let", "var", "func", "return", "struct", "import", "guard", "else", "self", "oust"]
        var generator = SystemRandomNumberGenerator()
        let paragraph = (0..<4_000).map { _ in vocabulary.randomElement(using: &generator)! }.joined(separator: " ")
        var data = Data()
        while data.count < kilobytes * 1_000 { data.append(contentsOf: Array((paragraph + "\n").utf8)) }
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.prefix(kilobytes * 1_000).write(to: url)
        return url
    }

    /// Un faux outil : un script qui note ses arguments et son environnement,
    /// puis fait ce que ferait l'outil (`action`).
    @discardableResult
    func fakeTool(_ name: String, action: String = "", output: String = "") throws -> URL {
        let url = root.appendingPathComponent("_outils/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let log = root.appendingPathComponent("_outils/\(name).log").path
        try """
        #!/bin/sh
        echo "$@" > '\(log)'
        env >> '\(log)'
        \(action)
        printf '%s' '\(output)'
        """.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }

    func toolLog(_ name: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent("_outils/\(name).log"), encoding: .utf8)) ?? ""
    }
}

@Suite("Compression transparente d'APFS : vérifiée avant de remplacer")
struct CompressorTests {

    @Test("Un fichier compressé se relit à l'identique et occupe moins")
    func compressesAndVerifies() throws {
        let bench = try Bench()
        let url = try bench.text("projet/journal.log", kilobytes: 700)
        let original = try Data(contentsOf: url)
        let before = try #require(FileFacts.of(url.path))

        let result = Compressor.compressFile(url)

        guard case .compressed(let saved) = result else { Issue.record("résultat : \(result)"); return }
        let after = try #require(FileFacts.of(url.path))
        #expect(after.isCompressed)
        #expect(after.size == before.size)
        #expect(saved == before.allocated - after.allocated && saved > 300_000)
        #expect(try Data(contentsOf: url) == original)
        #expect(after.modified.tv_sec == before.modified.tv_sec)
        // Aucun temporaire ne traîne à côté.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["journal.log"])
    }

    @Test("Sur plusieurs blocs de 64 Kio, la dernière partie comprise")
    func multipleChunks() throws {
        let bench = try Bench()
        let url = try bench.text("projet/gros.txt", kilobytes: 1_000)
        // Une fin qui ne tombe pas sur une frontière de bloc.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("fin.".utf8))
        try handle.close()
        let original = try Data(contentsOf: url)

        guard case .compressed = Compressor.compressFile(url) else { Issue.record("non compressé"); return }

        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Ce qui ne se compresse pas reste tel quel, sans temporaire")
    func incompressible() throws {
        let bench = try Bench()
        let url = bench.root.appendingPathComponent("projet/aleatoire.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        try Data((0..<400_000).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
        let before = try #require(FileFacts.of(url.path))

        #expect(Compressor.compressFile(url) == .skipped("incompressible"))
        #expect(FileFacts.of(url.path)?.inode == before.inode)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["aleatoire.bin"])
    }

    @Test("Lien physique, clone, petit fichier, fichier verrouillé : on n'y touche pas")
    func refusals() throws {
        let bench = try Bench()
        let linked = try bench.text("p/lie.txt", kilobytes: 200)
        try FileManager.default.linkItem(at: linked, to: bench.root.appendingPathComponent("p/autre-nom.txt"))
        let source = try bench.text("p/source.txt", kilobytes: 200)
        let clone = bench.root.appendingPathComponent("p/clone.txt")
        #expect(clonefile(source.path, clone.path, 0) == 0)
        let small = try bench.text("p/petit.txt", kilobytes: 3)
        let locked = try bench.text("p/verrou.txt", kilobytes: 200)
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        defer { chflags(locked.path, 0) }

        #expect(Compressor.compressFile(linked) == .skipped("hard-linked"))
        #expect(Compressor.compressFile(clone) == .skipped("clone"))
        #expect(Compressor.compressFile(small) == .skipped("size"))
        #expect(Compressor.compressFile(locked) == .skipped("not-eligible"))
    }

    @Test("Droits, attributs étendus et dates passent à la version compressée")
    func keepsMetadata() throws {
        let bench = try Bench()
        let script = try bench.text("p/gradlew", kilobytes: 300)
        chmod(script.path, 0o755)
        var tag: [UInt8] = Array("bleu".utf8)
        setxattr(script.path, "com.exemple.etiquette", &tag, tag.count, 0, 0)
        let before = try #require(FileFacts.of(script.path))
        let attributes = try #require(FileFacts.extendedAttributeNames(script.path))
        #expect(attributes.contains("com.exemple.etiquette"))

        guard case .compressed = Compressor.compressFile(script) else { Issue.record("non compressé"); return }

        let after = try #require(FileFacts.of(script.path))
        #expect(after.isCompressed)
        #expect(after.mode == before.mode)
        // Les mêmes attributs, et ceux de la compression restent cachés.
        #expect(FileFacts.extendedAttributeNames(script.path) == attributes)
        #expect(after.modified.tv_sec == before.modified.tv_sec)
    }

    @Test("Un fichier lecture seule se compresse et reste en lecture seule")
    func readOnly() throws {
        let bench = try Bench()
        let url = try bench.text("p/archive.txt", kilobytes: 300)
        chmod(url.path, 0o444)

        guard case .compressed = Compressor.compressFile(url) else { Issue.record("non compressé"); return }

        #expect(FileFacts.of(url.path)?.mode == S_IFREG | 0o444)
    }

    @Test("Un fichier modifié au dernier moment : l'échange est défait, l'original reste")
    func swapBack() throws {
        let bench = try Bench()
        let url = try bench.text("p/vivant.txt", kilobytes: 300)
        let seen = try #require(FileFacts.of(url.path))
        // Une écriture se glisse après la lecture.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ajout".utf8))
        try handle.close()
        let current = try Data(contentsOf: url)
        let temporary = bench.root.appendingPathComponent("p/\(CompressionPolicy.temporaryPrefix)test")
        try Data("autre".utf8).write(to: temporary)

        #expect(Compressor.swapIn(temporary.path, for: url.path, original: seen, saved: 1) == .skipped("changed"))
        #expect(try Data(contentsOf: url) == current)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test("Un fichier ouvert par un processus n'est pas remplacé ; un vieux temporaire est retiré")
    func openFilesAndLeftovers() throws {
        let bench = try Bench()
        let project = bench.root.appendingPathComponent("vieux")
        let held = try bench.text("vieux/tenu.log", kilobytes: 300)
        try bench.text("vieux/libre.log", kilobytes: 300)
        let handle = try FileHandle(forReadingFrom: held)
        defer { try? handle.close() }
        // Un temporaire compressé laissé par un arrêt brutal.
        let leftover = try bench.text("vieux/source.txt", kilobytes: 300)
        guard case .compressed = Compressor.compressFile(leftover) else { Issue.record("non compressé"); return }
        let stale = bench.root.appendingPathComponent("vieux/\(CompressionPolicy.temporaryPrefix)ancien")
        #expect(clonefile(leftover.path, stale.path, 0) == 0)

        let summary = Compressor.compressTree(project, notAfter: nil)

        #expect(FileFacts.of(held.path)?.isCompressed == false)
        #expect(FileFacts.of(bench.root.appendingPathComponent("vieux/libre.log").path)?.isCompressed == true)
        #expect(summary.compressed == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("Bases de données et images disque restent telles quelles")
    func liveData() {
        #expect(CompressionPolicy.skipsFile(named: "app.sqlite"))
        #expect(CompressionPolicy.skipsFile(named: "data.db-wal"))
        #expect(CompressionPolicy.skipsFolder(named: "Disque.sparsebundle"))
        #expect(!CompressionPolicy.skipsFile(named: "main.swift"))
    }

    @Test("Un fichier modifié après l'analyse est laissé tel quel")
    func modifiedSinceScan() throws {
        let bench = try Bench()
        let url = try bench.text("p/neuf.txt", kilobytes: 200)

        #expect(Compressor.compressFile(url, notAfter: Date().addingTimeInterval(-86_400)) == .skipped("modified"))
    }

    @Test("Un arbre : git et node_modules intacts, dates des dossiers rendues")
    func tree() throws {
        let bench = try Bench()
        let project = bench.root.appendingPathComponent("vieux")
        try bench.text("vieux/src/a.swift", kilobytes: 150)
        try bench.text("vieux/src/b.swift", kilobytes: 150)
        let packed = try bench.text("vieux/.git/objects/pack.idx", kilobytes: 150)
        let module = try bench.text("vieux/node_modules/x/index.js", kilobytes: 150)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: project.appendingPathComponent("src").path)

        let summary = Compressor.compressTree(project, notAfter: nil)

        #expect(summary.compressed == 2)
        #expect(summary.failures.isEmpty)
        #expect(summary.savedBytes > 0)
        #expect(FileFacts.of(packed.path)?.isCompressed == false)
        #expect(FileFacts.of(module.path)?.isCompressed == false)
        let folder = try FileManager.default.attributesOfItem(atPath: project.appendingPathComponent("src").path)
        #expect((folder[.modificationDate] as? Date) == old)
    }

    @Test("Le moteur compresse depuis la corbeille et note le gain réel")
    func engine() async throws {
        let bench = try Bench()
        let project = bench.root.appendingPathComponent("vieux")
        try bench.text("vieux/journal.log", kilobytes: 800)
        var item = bench.item(project, method: .compressInPlace, safety: .review)
        item.sizes = Sizes(private: 1)

        let (_, report) = await bench.run([item])
        let outcome = try #require(report?.outcomes.first)

        #expect(outcome.result == .compressed)
        #expect(outcome.bytes > 400_000)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("journal.log").path))
    }
}

@Suite("Éviction : rien n'est supprimé, seul le nuage est concerné")
struct EvictorTests {

    @Test("Chaque fichier évinçable est évincé, et seul ce qui l'a été compte")
    func counts() {
        let root = URL(fileURLWithPath: "/nuage/Photos")
        var evicted: [String] = []
        let summary = Evictor.evict([root], walk: { _, visit in
            _ = visit(root.appendingPathComponent("a.jpg"), 2_000, nil)
            _ = visit(root.appendingPathComponent("b.jpg"), 3_000, nil)
        }, evict: { url in
            if url.lastPathComponent == "b.jpg" { throw CocoaError(.fileWriteNoPermission) }
            evicted.append(url.lastPathComponent)
        })

        #expect(evicted == ["a.jpg"])
        #expect(summary.evictedBytes == 2_000)
        #expect(summary.failures.count == 1)
    }

    @Test("La garde n'autorise l'éviction que dans le nuage")
    func guardForEviction() {
        let guardian = PathGuard(home: URL(fileURLWithPath: "/Home/test"))
        #expect(guardian.allowsEviction(URL(fileURLWithPath: "/Home/test/Library/Mobile Documents/com~apple~CloudDocs/Photos")))
        #expect(guardian.allowsEviction(URL(fileURLWithPath: "/Home/test/Library/CloudStorage/GoogleDrive-x/Mon Drive")))
        #expect(!guardian.allowsEviction(URL(fileURLWithPath: "/Home/test/Library/CloudStorage")))
        #expect(!guardian.allowsEviction(URL(fileURLWithPath: "/Home/test/Documents/x")))
        #expect(!guardian.allowsEviction(URL(fileURLWithPath: "/Home/test/Library/CloudStorage/../Caches/x")))
    }

    @Test("Un élément à évincer hors du nuage est refusé par le moteur")
    func engineRefusesOutsideCloud() async throws {
        let bench = try Bench()
        let file = try bench.file("Documents/a.txt")
        let item = bench.item(file, method: .evictLocalCopy, safety: .review)

        let (_, report) = await bench.run([item])

        #expect(report?.outcomes.first?.result == .skipped(.refusedByGuard))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite("Une application rouverte depuis l'analyse protège ce qui est à elle")
struct RunningOwnerTests {
    @Test("Le cache d'une application ouverte après l'analyse n'est pas supprimé")
    func cacheOfReopenedApp() async throws {
        let bench = try Bench()
        let cache = try bench.file("Caches/com.spotify.client/Data/a")
        let folder = cache.deletingLastPathComponent().deletingLastPathComponent()
        let engine = CleanupEngine(trasher: FolderTrasher(folder: bench.trash), history: nil,
                                   pathGuard: PathGuard(home: bench.root.appendingPathComponent("maison")),
                                   processes: { ProcessSnapshot(processes: []) }, capacity: { _ in nil },
                                   deleteSnapshots: { _ in false }, runningApps: { ["com.spotify.client"] })
        var item = bench.item(folder, method: .removeNow, safety: .safe)
        item = CleanupItem(id: item.id, title: "Spotify", paths: [folder], category: .appCaches, owner: "Spotify",
                           ruleID: "cache.app", safety: .safe, method: .removeNow, sizes: item.sizes,
                           rebuild: .automatic, fingerprint: item.fingerprint)

        var result: OutcomeResult?
        for await event in engine.run([item]) {
            if case .itemFinished(let outcome) = event { result = outcome.result }
        }

        #expect(result == .skipped(.nowProtected(.appRunning(name: "com.spotify.client"))))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test("Mail et Messages : leurs pièces jointes dépendent d'eux")
    func owners() {
        let path = [URL(fileURLWithPath: "/x/GUID")]
        #expect(AppOwnership.runningOwner(ruleID: "attachments.mail", paths: path, running: ["com.apple.mail"]) == "Mail")
        #expect(AppOwnership.runningOwner(ruleID: "attachments.messages", paths: path, running: ["com.apple.mail"]) == nil)
        #expect(AppOwnership.runningOwner(ruleID: "artifact.node_modules", paths: path, running: ["com.apple.mail"]) == nil)
    }
}

@Suite("Les outils font eux-mêmes leur ménage")
struct ToolVerbTests {

    @Test("pyenv uninstall -f, avec son dossier, et le résultat vérifié")
    func pyenv() async throws {
        let bench = try Bench()
        let version = try bench.file("pyenv/versions/3.11.9/bin/python")
        let folder = version.deletingLastPathComponent().deletingLastPathComponent()
        let pyenv = try bench.fakeTool("pyenv", action: "rm -rf '\(folder.path)'")
        var item = bench.item(folder, method: .uninstallVersion(tool: .pyenv, executable: pyenv.path,
                                                                root: bench.root.path + "/pyenv", version: "3.11.9"))
        item.sizes = Sizes(private: 10_000)

        let (_, report) = await bench.run([item])

        #expect(report?.outcomes.first?.result == .delegated)
        let log = bench.toolLog("pyenv")
        #expect(log.hasPrefix("uninstall -f 3.11.9\n"))
        #expect(log.contains("PYENV_ROOT=\(bench.root.path)/pyenv"))
    }

    @Test("Le dossier encore là après la commande : échec, pas succès")
    func toolDidNothing() async throws {
        let bench = try Bench()
        let folder = try bench.file("rustup/toolchains/nightly/bin/rustc").deletingLastPathComponent().deletingLastPathComponent()
        let rustup = try bench.fakeTool("rustup")
        let item = bench.item(folder, method: .uninstallVersion(tool: .rustup, executable: rustup.path,
                                                                root: bench.root.path + "/rustup", version: "nightly"))

        let (_, report) = await bench.run([item])

        guard case .failed = report?.outcomes.first?.result else { Issue.record("attendu : échec"); return }
        #expect(bench.toolLog("rustup").hasPrefix("toolchain uninstall nightly\n"))
    }

    @Test("Un exécutable qui n'est pas l'outil, ou une version qui ressemble à une option : refusés")
    func validation() async throws {
        let bench = try Bench()
        let impostor = try bench.fakeTool("pas-pyenv")
        #expect(await ToolActions.uninstallVersion(tool: .pyenv, executable: impostor.path, root: "/x", version: "3.11",
                                                   folder: nil) != nil)
        let pyenv = try bench.fakeTool("pyenv")
        #expect(await ToolActions.uninstallVersion(tool: .pyenv, executable: pyenv.path, root: "/x", version: "--all",
                                                   folder: nil) != nil)
        #expect(bench.toolLog("pyenv").isEmpty)
        #expect(ToolActions.isPlainName("3.12.4"))
        #expect(ToolActions.isPlainName("stable-aarch64-apple-darwin"))
        #expect(!ToolActions.isPlainName("../3.12"))
        #expect(!ToolActions.isPlainName("-f"))
        #expect(!ToolActions.isPlainName(".."))
        #expect(!ToolActions.isPlainName("."))
    }

    /// Un faux `docker` : local, et qui annonce l'espace rendu.
    func fakeDocker(_ bench: Bench, endpoint: String = "unix:///var/run/docker.sock") throws -> URL {
        try bench.fakeTool("docker", action: """
        if [ "$1" = context ]; then echo '\(endpoint)'; exit 0; fi
        """, output: "Deleted build cache objects:\\nabc\\n\\nTotal reclaimed space: 1.5GB")
    }

    func dockerItem(_ docker: URL, scope: PruneScope, ids: [String]) -> CleanupItem {
        CleanupItem(id: "container|x|\(scope.rawValue)", title: "Docker", paths: [], category: .containers,
                    owner: "OrbStack", ruleID: "container.build_cache", safety: .rebuilds,
                    method: .containerPrune(executable: docker.path, scope: scope, ids: ids),
                    sizes: Sizes(private: 1_000), rebuild: .automatic)
    }

    @Test("docker builder prune : moteur local revérifié, espace annoncé par Docker")
    func dockerPrune() async throws {
        let bench = try Bench()
        let docker = try fakeDocker(bench)

        let (_, report) = await bench.run([dockerItem(docker, scope: .buildCache, ids: [])])
        let outcome = try #require(report?.outcomes.first)

        #expect(outcome.result == .delegated)
        #expect(outcome.bytes == 1_500_000_000)
        #expect(bench.toolLog("docker").hasPrefix("builder prune -f\n"))
        // Rendu dans le disque virtuel : pas compté comme libéré tout de suite sur le Mac.
        #expect(report?.expectedNow == 0)
    }

    @Test("docker container rm : seulement les identifiants relevés, sans -f")
    func dockerRemovesRecordedContainers() async throws {
        let bench = try Bench()
        let docker = try fakeDocker(bench)

        _ = await bench.run([dockerItem(docker, scope: .stoppedContainers, ids: ["d1e2f3", "a9b8c7"])])

        #expect(bench.toolLog("docker").hasPrefix("container rm d1e2f3 a9b8c7\n"))
    }

    @Test("Contexte distant ou identifiant douteux : Docker n'est pas appelé pour supprimer")
    func dockerRefusals() async throws {
        let bench = try Bench()
        let remote = try fakeDocker(bench, endpoint: "ssh://prod.exemple.fr")
        let (_, report) = await bench.run([dockerItem(remote, scope: .buildCache, ids: [])])
        guard case .failed = report?.outcomes.first?.result else { Issue.record("attendu : échec"); return }
        #expect(bench.toolLog("docker").hasPrefix("context inspect"))

        let local = try fakeDocker(bench)
        let (_, second) = await bench.run([dockerItem(local, scope: .unusedImages, ids: ["-f", "alpine"])])
        guard case .failed = second?.outcomes.first?.result else { Issue.record("attendu : échec"); return }
        #expect(!bench.toolLog("docker").contains("image rm"))
    }

    @Test("brew cleanup, sans réseau")
    func brew() async throws {
        let bench = try Bench()
        let old = try bench.file("Cellar/node/21.0.0/bin/node")
        let brew = try bench.fakeTool("brew")
        let item = bench.item(old.deletingLastPathComponent().deletingLastPathComponent(), method: .brewCleanup(executable: brew.path),
                              safety: .safe)

        let (_, report) = await bench.run([item])

        #expect(report?.outcomes.first?.result == .delegated)
        let log = bench.toolLog("brew")
        #expect(log.hasPrefix("cleanup\n"))
        #expect(log.contains("HOMEBREW_NO_AUTO_UPDATE=1") && log.contains("HOMEBREW_NO_ANALYTICS=1"))
        // Sans quoi `brew cleanup` désinstallerait aussi des dépendances orphelines, jamais montrées.
        #expect(log.contains("HOMEBREW_NO_AUTOREMOVE=1"))
    }
}
