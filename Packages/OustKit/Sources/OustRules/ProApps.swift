import Darwin
import Foundation
import OustCore
import OustSafety

/// Les caches des logiciels professionnels de photo, d'audio, de vidéo, de 3D et
/// de CAO : à un emplacement fixe, ou à côté d'un catalogue (Lightroom Classic,
/// Capture One).
///
/// Aucun n'est installé sur le Mac où ces règles ont été écrites (18/10/2026) :
/// chaque chemin vient de la documentation de son éditeur, citée en face, et
/// seul ce qu'il dit recréé est proposé. Ce qu'il ne documente pas (cache Camera
/// Raw, Bridge, fichiers temporaires de Photoshop, Luminar, ON1, Affinity) attend.
/// Jamais un catalogue, un projet, un réglage ni ce qui peut être la seule copie
/// d'une retouche (les aperçus dynamiques de Lightroom).
struct ProAppsFinder {
    let context: RuleContext

    static let minimumAllocated: Int64 = 1_000_000

    /// Un cache à un emplacement fixe : il suffit de le décrire.
    struct Entry: Sendable {
        enum Base: Sendable { case home, shared }
        let rule: String
        let owner: String
        let base: Base
        /// Relatifs à la base ; `*` vaut n'importe quel nom à ce niveau (une version).
        let patterns: [String]
        /// Des noms jamais pris, même sous un `*`.
        var kept: Set<String> = []
        let safety: SafetyClass
        let method: CleanupMethod
        let rebuild: RebuildCost
        var category: ItemCategory = .creative
    }

    static let entries: [Entry] = [
        // help.ableton.com, « Decoding cache » : les plus anciens fichiers sont
        // effacés d'eux-mêmes pour faire de la place.
        Entry(rule: "creative.ableton.cache", owner: "Ableton Live", base: .home,
              patterns: ["Library/Caches/Ableton/Cache"], safety: .rebuilds, method: .removeNow, rebuild: .automatic),
        // kb.avid.com, « Waveform Issue » : recréé au prochain lancement. Pas
        // `Workspace.wksp`, à côté, qui garde les catalogues de l'utilisateur.
        Entry(rule: "creative.protools.wavecache", owner: "Pro Tools", base: .shared,
              patterns: ["Pro Tools/WaveCache.wfm"], safety: .rebuilds, method: .removeNow, rebuild: .automatic),
        // kb.avid.com, « Rebuilding the Avid Cache folders » : reconstruits au
        // relancement. Jamais `Avid Attic` (sauvegardes des chutiers) ni les médias.
        Entry(rule: "creative.avid.cache", owner: "Media Composer", base: .shared,
              patterns: ["AvidMediaComposer/AvidImageCache", "AvidMediaComposer/AvidSourceBrowserCache"],
              safety: .rebuilds, method: .removeNow, rebuild: .automatic),
        // support.maxon.net et l'aide de Cinema 4D 2025 : « You can also delete the
        // caches manually at any time », application fermée.
        Entry(rule: "creative.redshift.cache", owner: "Redshift", base: .home,
              patterns: ["Library/Preferences/Maxon/*/redshift/cache", "redshift/cache",
                         "Library/Application Support/Redshift/TextureCache"],
              safety: .rebuilds, method: .removeNow, rebuild: .automatic),
        // support.maxon.net : les assets téléchargés depuis l'Asset Browser.
        Entry(rule: "creative.maxon.assetcache", owner: "Cinema 4D", base: .home,
              patterns: ["Library/Preferences/Maxon/_assetcache"], safety: .review, method: .removeNow,
              rebuild: .download),
        // docs.unity3d.com, « upm-cache » : le cache global des paquets, retéléchargés au besoin.
        Entry(rule: "creative.unity.cache", owner: "Unity", base: .home,
              patterns: ["Library/Caches/Unity/upm"], safety: .rebuilds, method: .removeNow, rebuild: .download),
        // docs.unity.com, « Asset Store packages » : téléchargés, à retélécharger.
        Entry(rule: "creative.unity.asset_store", owner: "Unity", base: .home,
              patterns: ["Library/Unity/Asset Store-5.x"], safety: .review, method: .removeNow, rebuild: .download),
        // dev.epicgames.com, Zen Storage Server (UE 5.4+) : « Content stored in the
        // DDC is disposable ».
        Entry(rule: "creative.unreal.ddc", owner: "Unreal Engine", base: .home,
              patterns: ["Library/Application Support/Epic/UnrealEngine/Common/Zen/Data"],
              safety: .rebuilds, method: .removeNow, rebuild: .automatic),
        // docs.godotengine.org, « Data paths » : « can safely be removed when Godot is closed ».
        Entry(rule: "creative.godot.cache", owner: "Godot", base: .home,
              patterns: ["Library/Caches/Godot"], safety: .safe, method: .removeNow, rebuild: .automatic),
        // help.autodesk.com, AutoCAD for Mac : le cache graphique, par produit,
        // version et langue.
        Entry(rule: "creative.autocad.graphics_cache", owner: "AutoCAD", base: .home,
              patterns: ["Library/Application Support/Autodesk/local/*/*/*/GraphicsCache"],
              safety: .rebuilds, method: .removeNow, rebuild: .automatic),
        // community.graphisoft.com (article de Graphisoft) : « Archicad will
        // automatically recreate them ». Jamais `Application Support/Graphisoft`.
        Entry(rule: "creative.archicad.cache", owner: "Archicad", base: .home,
              patterns: ["Library/Caches/Graphisoft"], safety: .rebuilds, method: .removeNow, rebuild: .automatic),
        // helpx.adobe.com, emplacements d'InDesign : « temporary files that can be
        // regenerated if deleted ». Sauf la récupération des documents non enregistrés.
        Entry(rule: "creative.indesign.cache", owner: "InDesign", base: .home,
              patterns: ["Library/Caches/Adobe InDesign/*/*"], kept: ["InDesign Recovery", "SavedData"],
              safety: .rebuilds, method: .removeNow, rebuild: .automatic),
    ]

    func find() async -> [Candidate] {
        // Une lecture des fichiers ouverts par racine, plutôt qu'une par élément :
        // une application ouverte tient ses caches. Après le parcours de l'analyse,
        // dont les dossiers ouverts fausseraient la réponse.
        _ = await context.tree?()
        // Sur un autre disque, seulement ce qu'on y range soi-même : catalogues
        // Lightroom et Capture One. Les caches fixes vivent dans le dossier personnel.
        let volumeRoot = context.volumeAnchor?.url ?? context.volume?.root
        let roots = volumeRoot.map { [$0.path] } ?? [context.home.path, context.sharedFolder.path]
        let open = roots.reduce(into: Set<String>()) { $0.formUnion(OpenFiles.paths(under: $1)) }
        let candidates = (volumeRoot == nil ? fixedCaches() : []) + (await lightroomPreviews()) + (await captureOne())
        return candidates.map { candidate in
            var candidate = candidate
            let scopes = candidate.item.activityScope.map { [$0] } ?? candidate.item.paths
            // Le verrou Lightroom a déjà été revérifié via la racine ouverte.
            if context.volumeAnchor == nil,
               let owner = AppOwnership.runningOwner(ruleID: candidate.item.ruleID, paths: candidate.item.paths,
                                                     running: context.runningApps) {
                candidate.item.protect(.appRunning(name: owner))
            } else if open.contains(where: { file in scopes.contains { PathNormalizer.isWithin(file, $0.path) } }) {
                candidate.item.protect(.appRunning(name: candidate.item.owner))
            }
            return candidate
        }
    }

    func candidate(_ title: String, detail: URL, paths: [URL], owner: String, rule: String, safety: SafetyClass,
                   method: CleanupMethod, rebuild: RebuildCost, scope: URL? = nil) -> Candidate {
        Candidate(item: CleanupItem(
            title: title, detail: detail.abbreviated(home: context.home), paths: paths, category: .creative,
            owner: owner, ruleID: rule, safety: safety, method: method, rebuild: rebuild, activityScope: scope
        ), minimumAllocated: Self.minimumAllocated)
    }

    // MARK: - Emplacements fixes

    func fixedCaches() -> [Candidate] {
        Self.fixedCaches(Self.entries, context: context)
    }

    /// Un élément par entrée, avec tout ce qui existe de ses chemins.
    static func fixedCaches(_ entries: [Entry], context: RuleContext) -> [Candidate] {
        entries.compactMap { entry in
            let base = entry.base == .home ? context.home : context.sharedFolder
            let paths = entry.patterns.flatMap { expand($0, under: base, kept: entry.kept) }
            guard let first = paths.first else { return nil }
            let detail = paths.count == 1 ? first : first.deletingLastPathComponent()
            return Candidate(item: CleanupItem(
                title: entry.owner, detail: detail.abbreviated(home: context.home), paths: paths,
                category: entry.category, owner: entry.owner, ruleID: entry.rule, safety: entry.safety,
                method: entry.method, rebuild: entry.rebuild
            ), minimumAllocated: minimumAllocated)
        }
    }

    /// Ce qui existe, sous `base`, de « `Library/Preferences/Maxon/*/redshift/cache` »,
    /// liens symboliques écartés.
    static func expand(_ pattern: String, under base: URL, kept: Set<String>) -> [URL] {
        var current = [base]
        for component in pattern.split(separator: "/").map(String.init) {
            current = current.flatMap { folder -> [URL] in
                if component == "*" {
                    return FileManager.default.children(of: folder)
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                }
                return [folder.appendingPathComponent(component)]
            }
            .filter { !$0.isSymbolicLink && !kept.contains($0.lastPathComponent) }
        }
        return current.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Lightroom Classic

    /// Les aperçus d'un catalogue (`<catalogue> Previews.lrdata`, à côté de
    /// `<catalogue>.lrcat`) : vignettes, aperçus standard et 1:1, refaits à
    /// l'ouverture de chaque dossier (helpx.adobe.com, « Preview cache »).
    ///
    /// Jamais `<catalogue> Smart Previews.lrdata` : sans les originaux, ces
    /// aperçus dynamiques sont la seule copie qu'on puisse retoucher. Un catalogue
    /// ouvert pose un `.lrcat.lock` à côté de lui : protégé.
    func lightroomPreviews() async -> [Candidate] {
        let suffix = " Previews.lrdata"
        let fileManager = FileManager.default
        let pictures = context.home.appendingPathComponent("Pictures", isDirectory: true)
        let folders = await context.findFolders(fallback: [pictures], depth: 2) { $0.hasSuffix(suffix) }
        return folders.compactMap { folder -> Candidate? in
            let name = String(folder.lastPathComponent.dropLast(suffix.count))
            let parent = folder.deletingLastPathComponent()
            let catalog = parent.appendingPathComponent(name + ".lrcat", isDirectory: false)
            let smartCatalog = parent.appendingPathComponent(String(name.dropLast(6)) + ".lrcat", isDirectory: false)
            let lock = parent.appendingPathComponent(name + ".lrcat.lock", isDirectory: false)
            let lockProtection: ProtectionReason?
            let boundProof: (@Sendable () -> Bool)?
            let requiresSmartCatalogAbsence = name.hasSuffix(" Smart")
            if let anchor = context.volumeAnchor {
                guard let facts = VolumeDirectory.entry(catalog, in: anchor).facts,
                      facts.isRegularFile, facts.linkCount == 1 else { return nil }
                if requiresSmartCatalogAbsence {
                    guard case .missing = VolumeDirectory.entry(smartCatalog, in: anchor) else { return nil }
                }
                switch VolumeDirectory.entry(lock, in: anchor) {
                case .facts: lockProtection = .appRunning(name: "Lightroom Classic")
                case .missing: lockProtection = nil
                case .unknown: lockProtection = .unknownState
                }
                // Keep the first validated identity. A failed later lookup
                // must invalidate the proof instead of removing its requirement.
                if lockProtection == nil {
                    boundProof = { @Sendable () -> Bool in
                        guard case .missing = VolumeDirectory.entry(lock, in: anchor),
                              let current = VolumeDirectory.entry(catalog, in: anchor).facts,
                              current.device == facts.device, current.mode == facts.mode,
                              current.isUnchanged(comparedTo: facts) else { return false }
                        if requiresSmartCatalogAbsence {
                            guard case .missing = VolumeDirectory.entry(smartCatalog, in: anchor) else { return false }
                        }
                        return true
                    }
                } else {
                    boundProof = nil
                }
            } else {
                guard fileManager.fileExists(atPath: catalog.path) else { return nil }
                if requiresSmartCatalogAbsence, fileManager.fileExists(atPath: smartCatalog.path) { return nil }
                lockProtection = fileManager.fileExists(atPath: lock.path) ? .appRunning(name: "Lightroom Classic") : nil
                boundProof = nil
            }
            var previews = candidate(name, detail: parent, paths: [folder], owner: "Lightroom Classic",
                                     rule: "creative.lightroom.previews", safety: .rebuilds, method: .removeNow,
                                     rebuild: .automatic)
            if let lockProtection { previews.item.protect(lockProtection) }
            previews.boundProof = boundProof
            return previews
        }
    }

    // MARK: - Capture One

    /// Le dossier `Cache` d'un catalogue (`.cocatalog`) et ceux des sessions
    /// (`CaptureOne/Cache`, à côté de `Settings…`) : aperçus, proxys, vignettes.
    /// « Deleting the Cache does not remove your images or adjustments »
    /// (support.captureone.com). Jamais `Settings…`, qui tient les retouches.
    func captureOne() async -> [Candidate] {
        let fileManager = FileManager.default
        let pictures = context.home.appendingPathComponent("Pictures", isDirectory: true)
        let folders = await context.findFolders(fallback: [pictures], depth: 4) {
            $0 == "CaptureOne" || $0.lowercased().hasSuffix(".cocatalog")
        }
        return folders.compactMap { folder in
            let cache = folder.appendingPathComponent("Cache", isDirectory: true)
            let isCatalog = folder.pathExtension.lowercased() == "cocatalog"
            // Un dossier « CaptureOne » sans réglages à côté n'est pas forcément le sien.
            if let anchor = context.volumeAnchor {
                guard let facts = VolumeDirectory.entry(cache, in: anchor).facts,
                      facts.mode & S_IFMT == S_IFDIR else { return nil }
                if !isCatalog {
                    let hasSettings = context.volumeEntries(in: folder)?.contains {
                        $0.url.lastPathComponent.hasPrefix("Settings") && $0.facts.mode & S_IFMT == S_IFDIR
                    }
                    guard hasSettings == true else { return nil }
                }
            } else {
                guard fileManager.isDirectory(cache), !cache.isSymbolicLink else { return nil }
                if !isCatalog, !fileManager.children(of: folder).contains(where: {
                    $0.lastPathComponent.hasPrefix("Settings")
                }) { return nil }
            }
            let title = isCatalog ? folder.deletingPathExtension().lastPathComponent
                : folder.deletingLastPathComponent().lastPathComponent
            return candidate(title, detail: isCatalog ? folder : folder.deletingLastPathComponent(), paths: [cache],
                             owner: "Capture One", rule: "creative.captureone.cache", safety: .rebuilds,
                             method: .removeNow, rebuild: .automatic, scope: folder)
        }
    }
}
