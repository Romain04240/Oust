import Darwin
import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety
import OustScan

/// Un faux disque externe dans le dossier temporaire du test : sa racine joue
/// `/Volumes/<disque>` (RULES.md, règle 8).
private extension FakeHome {
    var volume: URL { root.appendingPathComponent("_Volume", isDirectory: true) }

    func onVolume(_ relative: String, bytes: Int = 50_000) throws {
        try file("_Volume/" + relative, bytes: bytes)
    }

    func volumeContext(fileSystem: String = "exfat", readOnly: Bool = false, tree: TreeNode? = nil,
                       processes: [ActiveProcess] = []) -> RuleContext {
        var context = self.context(processes: processes)
        context.volume = VolumeScope(root: volume, name: "Disque", fileSystem: fileSystem, isReadOnly: readOnly)
        context.projectRoots = [volume]
        if let tree { context.tree = { tree } }
        return context
    }

    /// Un disque comme on en branche : des projets, un montage, des installeurs,
    /// sa corbeille, des traces de macOS, et ce qui doit rester protégé.
    func populateVolume() throws {
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        // Projets
        try text("_Volume/Dev/site/package.json", "{}")
        try onVolume("Dev/site/node_modules/react/index.js")
        // Montage
        try onVolume("Montage/Film.fcpbundle/Tournage/Render Files/r.mov", bytes: 1_200_000)
        try onVolume("Montage/Resolve/CacheClip/c.dvcc", bytes: 1_200_000)
        try onVolume("Montage/Resolve/ProxyMedia/p.mov", bytes: 1_200_000)
        // Installeurs
        try onVolume("Logiciels/Outil.dmg", bytes: 11_000_000)
        try onVolume("Logiciels/petit.pkg", bytes: 200_000)
        // La corbeille du disque
        try onVolume(".Trashes/\(getuid())/vieux film.mov", bytes: 2_000_000)
        try onVolume(".Trashes/\(getuid())/dossier jeté/a.txt")
        // Traces de macOS
        try onVolume("Photos 2019/plage.jpg")
        try onVolume("Photos 2019/._plage.jpg", bytes: 4_096)
        try onVolume("Photos 2019/._disparue.jpg", bytes: 4_096)
        try onVolume("Photos 2019/.DS_Store", bytes: 6_148)
        try onVolume("._Photos 2019", bytes: 4_096)
        try onVolume("Photos 2019/._.DS_Store", bytes: 4_096)
        // Le `._` de ce qui est protégé est protégé avec lui.
        try onVolume("Anciennes/._Famille.photoslibrary", bytes: 4_096)
        try onVolume("VM/._Windows.utm", bytes: 4_096)
        try onVolume("._Backups.backupdb", bytes: 4_096)
        // Une application sur ce disque garde ses `._` : jamais touchés.
        try onVolume("Applications/Outil.app/Contents/._Info.plist", bytes: 4_096)
        // Protégé : Time Machine, photothèque, machine virtuelle
        try onVolume("Backups.backupdb/Mac/2026-10-01-101500/Macintosh HD/Users/x/Installeur.dmg", bytes: 11_000_000)
        try onVolume("Backups.backupdb/Mac/2026-10-01-101500/Macintosh HD/Users/x/._a", bytes: 4_096)
        try onVolume("Anciennes/Famille.photoslibrary/originals/A/IMG.heic", bytes: 2_000_000)
        try onVolume("Anciennes/Famille.photoslibrary/._x", bytes: 4_096)
        try onVolume("VM/Windows.utm/Data/disk.qcow2", bytes: 2_000_000)
        try onVolume("VM/linux.vmdk", bytes: 2_000_000)
    }
}

@Suite("Un autre disque s'analyse comme le disque de démarrage")
struct VolumeFindersTests {

    @Test("Une mesure du volume ne suit pas un dossier remplacé au même chemin")
    func boundMeasurementRejectsReplacement() async throws {
        let home = try FakeHome()
        try home.text("_Volume/Dev/site/package.json", "{}")
        try home.onVolume("Dev/site/node_modules/original", bytes: 1_200_000)
        let anchor = try home.openVolume(home.volume)
        let snapshot = await ScanIndex.refreshBound(nil, root: anchor, options: ScanOptions(), progress: ScanProgress())
        var context = home.volumeContext(tree: snapshot.index.root)
        context.volume?.root = anchor.url
        context.projectRoots = [anchor.url]
        context.volumeAnchor = anchor
        let initial = await RuleEngine.collect(context, finders: [.projectArtifacts])
        let measured = try #require(initial.first { $0.ruleID == "artifact.node_modules" })
        #expect(measured.sizes.allocated >= 1_200_000)
        #expect(!measured.protections.contains(.unknownState))

        let target = home.volume.appendingPathComponent("Dev/site/node_modules")
        try FileManager.default.moveItem(at: target, to: home.root.appendingPathComponent("original"))
        try home.onVolume("Dev/site/node_modules/replacement", bytes: 4096)
        let rescanned = await RuleEngine.collect(context, finders: [.projectArtifacts])
        let replacement = try #require(rescanned.first { $0.ruleID == "artifact.node_modules" })
        #expect(replacement.sizes == .zero)
        #expect(replacement.protections.contains(.unknownState))
        #expect(!replacement.isSelectable)
    }

    @Test("Les petits fichiers de métadonnées restent sur le volume et sans suivi de liens")
    func boundMetadataReadsOnlyConfirmedFiles() throws {
        let home = try FakeHome()
        try home.text("_Volume/Local/metadata", "known")
        try home.text("Outside/metadata", "other")
        let fs = FileManager.default
        let local = home.volume.appendingPathComponent("Local")
        let outside = home.root.appendingPathComponent("Outside")
        try fs.createSymbolicLink(at: home.volume.appendingPathComponent("Redirect"), withDestinationURL: outside)
        try fs.createSymbolicLink(at: local.appendingPathComponent("Symbolic"), withDestinationURL: outside.appendingPathComponent("metadata"))
        try fs.linkItem(at: outside.appendingPathComponent("metadata"), to: local.appendingPathComponent("Hard"))
        var context = home.volumeContext()
        let anchor = try home.openVolume(home.volume)
        context.volumeAnchor = anchor
        let physicalLocal = anchor.url.appendingPathComponent("Local")
        let redirect = anchor.url.appendingPathComponent("Redirect")
        let metadata = physicalLocal.appendingPathComponent("metadata")
        #expect(context.volumeData(at: metadata, maximumBytes: 5) == Data("known".utf8))
        #expect(context.volumeData(at: metadata, maximumBytes: 4) == nil)
        #expect(context.volumeData(at: physicalLocal.appendingPathComponent("Symbolic"), maximumBytes: 10) == nil)
        #expect(context.volumeData(at: physicalLocal.appendingPathComponent("Hard"), maximumBytes: 10) == nil)
        #expect(context.volumeData(at: redirect.appendingPathComponent("metadata"), maximumBytes: 10) == nil)
        #expect(context.volumeEntries(in: redirect) == nil)
    }

    @Test("Le moteur externe ne relève que les traces du dossier ouvert")
    func boundTracesStayOnOriginalVolume() async throws {
        let home = try FakeHome()
        try home.onVolume("Dossier/._Original.txt", bytes: 4096)
        try home.onVolume("Dossier/Original.txt", bytes: 4096)
        try home.onVolume("2026-11-18-120000.backup/Temoin.txt", bytes: 4096)
        try home.file("Autre/._Remplacement.txt", bytes: 4096)
        try home.file("Autre/Remplacement.txt", bytes: 4096)
        let physical = try #require(realpath(home.volume.path, nil))
        defer { free(physical) }
        let url = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let opened = try #require(AnalysisRoot(url))
        let fs = FileManager.default
        try fs.moveItem(at: home.volume, to: home.root.appendingPathComponent("Deplace"))
        try fs.createSymbolicLink(at: home.volume, withDestinationURL: home.root.appendingPathComponent("Autre"))
        #expect(VolumeProtection.timeMachineVolumeMarker(in: opened) == true)

        var context = home.volumeContext()
        context.volume?.root = url
        context.volumeAnchor = opened
        let items = await RuleEngine.collect(context, finders: [.volumeTraces, .projectArtifacts], measurer: Measurer { _ in
            Issue.record("Le moteur externe ne doit pas lancer la mesure brute.")
            return [:]
        })
        let item = try #require(items.first { $0.ruleID == "volume.appledouble" })
        #expect(item.paths.map(\.lastPathComponent) == ["._Original.txt"])
        #expect(items.flatMap(\.paths).allSatisfy { !$0.lastPathComponent.contains("Remplacement") })
    }

    @Test("Artefacts, montage, installeurs, corbeille du disque et traces : chacun dans sa section")
    func findsEachKind() async throws {
        let home = try FakeHome()
        try home.populateVolume()

        let items = await RuleEngine.collect(home.volumeContext(), finders: FinderKind.volumeFinders)

        let node = try #require(items.first { $0.ruleID == "artifact.node_modules" })
        #expect(node.category.section == .developer && node.owner == "Dev")
        #expect(items.contains { $0.ruleID == "creative.library.render" && $0.title == "Film" })
        let cache = try #require(items.first { $0.ruleID == "creative.resolve.cache" })
        #expect(cache.method == .removeNow && cache.safety == .rebuilds)
        let proxy = try #require(items.first { $0.ruleID == "creative.resolve.proxy" })
        #expect(proxy.method == .trash && proxy.safety == .review)

        let installer = try #require(items.first { $0.ruleID == "volume.installer" })
        #expect(installer.title == "Outil.dmg" && installer.category == .systemDownloads)
        #expect(installer.safety == .review && installer.method == .trash && !PreselectionPolicy().preselects(installer))
        #expect(!items.contains { $0.title == "petit.pkg" })

        let trash = try #require(items.first { $0.ruleID == "trash.volume" })
        #expect(trash.category == .trash && trash.method == .removeNow && trash.safety == .review)
        #expect(Set(trash.paths.map(\.lastPathComponent)) == ["vieux film.mov", "dossier jeté"])
        #expect(trash.sizes.allocated >= 2_000_000)
    }

    @Test("Un « ._ » avec son fichier part à la corbeille, sans lui tout de suite ; jamais dans un paquet")
    func appleDouble() async throws {
        let home = try FakeHome()
        try home.populateVolume()

        let items = await RuleEngine.collect(home.volumeContext(), finders: [.volumeTraces])

        let orphans = try #require(items.first { $0.ruleID == "volume.appledouble_orphan" })
        #expect(orphans.paths.map(\.lastPathComponent) == ["._disparue.jpg"])
        #expect(orphans.method == .removeNow && orphans.safety == .review && orphans.category == .diskTraces)
        let described = items.filter { $0.ruleID == "volume.appledouble" }
        #expect(Set(described.flatMap(\.paths).map(\.lastPathComponent)) == ["._plage.jpg", "._Photos 2019"])
        #expect(described.allSatisfy { $0.method == .trash && $0.safety == .review })
        let stores = try #require(items.first { $0.ruleID == "volume.ds_store" })
        #expect(Set(stores.paths.map(\.lastPathComponent)) == [".DS_Store", "._.DS_Store"])
        // Tout ce qui est proposé passe la garde : rien ne bloquerait le groupe au nettoyage.
        let guardian = PathGuard(home: home.root.appendingPathComponent("Maison"), otherVolumeRoots: [home.volume])
        #expect(items.flatMap(\.paths).allSatisfy(guardian.allows))
        #expect(stores.sizes.allocated > 0)
        // Ni les paquets (application, photothèque), ni les sauvegardes, ni la corbeille.
        let paths = items.flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.contains(".app/") || $0.contains(".photoslibrary") })
        #expect(!paths.contains { $0.contains("Backups.backupdb") || $0.contains(".Trashes") })
        #expect(items.allSatisfy { !PreselectionPolicy().preselects($0) })
    }

    @Test("Sur APFS ou HFS+, pas de traces à chercher")
    func noTracesOnAppleFileSystems() async throws {
        let home = try FakeHome()
        try home.populateVolume()
        for fileSystem in ["apfs", "hfs"] {
            let items = await RuleEngine.collect(home.volumeContext(fileSystem: fileSystem), finders: [.volumeTraces])
            #expect(items.isEmpty)
        }
    }

    @Test("Time Machine, photothèques et machines virtuelles : montrées, protégées, jamais ailleurs")
    func protectedContent() async throws {
        let home = try FakeHome()
        try home.populateVolume()

        let items = await RuleEngine.collect(home.volumeContext(), finders: FinderKind.volumeFinders)

        let backups = try #require(items.first { $0.ruleID == "volume.time_machine" })
        #expect(backups.protections == [.timeMachine] && !backups.isSelectable)
        #expect(backups.category == .protectedOnDisk && backups.method == .manual)
        let library = try #require(items.first { $0.ruleID == "volume.photo_library" })
        #expect(library.title == "Famille" && library.protections == [.photoLibrary] && !library.isSelectable)
        #expect(library.sizes.allocated >= 2_000_000)
        let machines = items.filter { $0.ruleID == "vm.image" }
        #expect(Set(machines.map(\.title)) == ["Windows", "linux"])
        #expect(machines.allSatisfy { $0.protections == [.virtualMachine] && !$0.isSelectable })
        // Rien d'autre ne vient de ces trois-là : pas l'installeur de la
        // sauvegarde, pas un fichier de la photothèque.
        let others = items.filter { !["volume.time_machine", "volume.photo_library", "vm.image"].contains($0.ruleID) }
        let paths = others.flatMap(\.paths).map(\.path)
        #expect(!paths.contains { $0.contains("Backups.backupdb") || $0.contains(".photoslibrary") || $0.contains(".utm") })
        #expect(!paths.contains { $0.hasSuffix(".vmdk") || $0.hasSuffix(".qcow2") })
    }

    @Test("Un .sparsebundle de Time Machine est reconnu à ses marques, un autre non")
    func timeMachineSparseBundle() async throws {
        let home = try FakeHome()
        try FileManager.default.createDirectory(at: home.volume, withIntermediateDirectories: true)
        try home.onVolume("Mac.sparsebundle/com.apple.TimeMachine.MachineID.plist", bytes: 500)
        try home.onVolume("Mac.sparsebundle/bands/0", bytes: 1_000_000)
        try home.onVolume("Projet.sparsebundle/bands/0", bytes: 1_000_000)
        try home.onVolume("Bureau.backupbundle/bands/0", bytes: 1_000_000)

        let items = await RuleEngine.collect(home.volumeContext(), finders: [.volumeKept])

        #expect(Set(items.map(\.title)) == ["Mac.sparsebundle", "Bureau.backupbundle"])
        #expect(items.allSatisfy { $0.protections == [.timeMachine] })
    }

    @Test("Un disque en lecture seule : tout est montré, rien n'est sélectionnable")
    func readOnly() async throws {
        let home = try FakeHome()
        try home.populateVolume()

        let items = await RuleEngine.collect(home.volumeContext(readOnly: true), finders: FinderKind.volumeFinders)

        #expect(!items.isEmpty)
        #expect(items.allSatisfy { !$0.isSelectable && $0.protections.contains(.readOnlyVolume) })
    }

    @Test("Les gardes habituelles tiennent : un processus dans le projet le protège")
    func projectGuards() async throws {
        let home = try FakeHome()
        try home.populateVolume()
        let busy = ActiveProcess(pid: 7, name: "node", workingDirectory: home.volume.path + "/Dev/site")

        let items = await RuleEngine.collect(home.volumeContext(processes: [busy]), finders: [.projectArtifacts])

        let node = try #require(items.first { $0.ruleID == "artifact.node_modules" })
        #expect(node.protections == [.activeProcess(name: "node")])
    }

    @Test("Avec l'arbre de l'analyse : les mêmes éléments, les « ._ » retenus par leur nom")
    func fromTree() async throws {
        let home = try FakeHome()
        try home.populateVolume()
        let backups = home.volume.appendingPathComponent("Backups.backupdb").path
        let options = ScanOptions(leafThreshold: 100_000, excludedPaths: [backups],
                                  notableNames: RuleEngine.notableNames(fileSystem: "exfat"))
        let (index, _) = await ScanIndex.refresh(nil, root: home.volume, options: options)
        let photos = try #require(index.root.descendant(atPath: home.volume.appendingPathComponent("Photos 2019").path))
        #expect(Set(photos.notableFiles).isSuperset(of: ["._plage.jpg", "._disparue.jpg", ".DS_Store"]))
        // Les sauvegardes ne sont jamais parcourues.
        #expect(index.root.child(named: "Backups.backupdb")?.status == .excluded)

        let fromDisk = await RuleEngine.collect(home.volumeContext(), finders: FinderKind.volumeFinders)
        let fromTree = await RuleEngine.collect(home.volumeContext(tree: index.root), finders: FinderKind.volumeFinders,
                                                measurer: .tree { index.root })

        // `FileManager` rend parfois `/private/var/…` là où l'arbre dit `/var/…` : un même chemin.
        func ids(_ items: [CleanupItem]) -> Set<String> {
            Set(items.map { $0.id.replacingOccurrences(of: "/private/var/", with: "/var/") })
        }
        #expect(ids(fromTree) == ids(fromDisk))
        let orphans = try #require(fromTree.first { $0.ruleID == "volume.appledouble_orphan" })
        #expect(orphans.paths.map(\.lastPathComponent) == ["._disparue.jpg"])
    }

    @Test("Sans disque choisi, les chercheurs d'un disque ne trouvent rien")
    func bootContextFindsNothing() async throws {
        let home = try FakeHome()
        try home.populateVolume()
        let items = await RuleEngine.collect(home.context(),
                                             finders: [.volumeInstallers, .volumeTrash, .volumeTraces, .volumeKept])
        #expect(items.isEmpty)
    }

    @Test("Chaque règle d'un disque est connue du catalogue")
    func catalogued() {
        let ids = ["trash.volume", "volume.installer", "volume.appledouble", "volume.appledouble_orphan",
                   "volume.ds_store", "volume.time_machine", "volume.photo_library"]
        #expect(Set(ids).isSubset(of: Set(RuleCatalog.ruleIDs)))
    }
}
