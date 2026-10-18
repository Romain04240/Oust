import Foundation
import Testing
import OustArchive
import OustCore
import OustModel
import OustUninstall

/// Les clés construites à l'exécution (`category.\(rawValue)`, `rule.\(id).what`)
/// échappent au lint, qui ne lit que les littéraux : on les vérifie ici.
///
/// `swift build` recopie le catalogue sans le compiler ; on lit donc la source.
@Suite("Le catalogue couvre chaque clé construite")
struct CatalogTests {
    /// Les clés seules : un ensemble de chaînes est `Sendable`, un dictionnaire de `Any` non.
    static let catalog: Set<String> = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OustLocalization/Resources/Localizable.xcstrings")
        let data = (try? Data(contentsOf: url)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Set((object?["strings"] as? [String: Any] ?? [:]).keys)
    }()

    static let ruleIDs: [String] = [
        "artifact.node_modules", "artifact.framework_build", "artifact.build_cache", "artifact.coverage",
        "artifact.output", "artifact.swiftpm", "artifact.pods", "artifact.xcode_local", "artifact.flutter",
        "artifact.gradle", "artifact.rust", "artifact.python_env", "artifact.vendor", "artifact.pycache",
        "cache.npm", "cache.yarn", "cache.pnpm", "cache.bun", "cache.pip", "cache.gradle", "cache.maven",
        "cache.cocoapods", "cache.cargo", "cache.go", "cache.homebrew", "cache.pub", "cache.browsers_test",
        "xcode.module_cache", "xcode.derived_data", "xcode.derived_data_orphan", "xcode.device_support",
        "xcode.archive", "xcode.logs", "xcode.previews", "simulator.device", "simulator.unavailable",
        "simulator.runtime", "agent.worktree", "agent.codex_worktree", "agent.claude_history",
        "agent.claude_history_orphan", "agent.codex_sessions", "agent.codex_workspace", "agent.codex_images",
        "agent.cache", "model.huggingface", "model.lmstudio", "model.ollama", "model.app_models",
        "downloads.installer", "downloads.large", "trash.contents", "ios.backup", "vm.image", "vm.docker",
        "snapshot.time_machine", "browser.cache", "browser.history", "browser.cookies", "duplicate.copy",
        "explorer.item", "uninstall.app", "archive.project", "largefile.item",
        "cloud.icloud", "cloud.file_provider", "compress.project",
        "version.xcode", "version.macos_installer", "version.nvm", "version.pyenv", "version.jdk_gradle",
        "version.jdk_system", "version.ndk", "version.rustup", "tool.brew_cleanup",
        "container.build_cache", "container.images", "container.stopped",
        "cache.app", "attachments.mail", "attachments.messages", "ios.update", "screenshots.desktop",
        "creative.library.render", "creative.library.transcoded", "creative.resolve.cache",
        "creative.resolve.proxy", "creative.resolve.gallery", "creative.insta360.cache", "creative.insta360.proxy",
        "creative.blender.cache", "creative.blender.temp", "creative.sound_library",
        "game.steam.appcache", "game.steam.shadercache", "game.steam.depotcache", "game.steam.leftover",
        "game.epic.vault", "game.epic.leftover", "game.gog.webcache", "game.steam.download", "game.epic.download",
        "cache.electron", "cache.telegram", "creative.adobe.media_cache", "creative.capcut.cache",
        "creative.filmora.temp", "creative.plex.updates",
        "creative.ableton.cache", "creative.protools.wavecache", "creative.avid.cache", "creative.redshift.cache",
        "creative.maxon.assetcache", "creative.unity.cache", "creative.unity.asset_store", "creative.unreal.ddc",
        "creative.godot.cache", "creative.autocad.graphics_cache", "creative.archicad.cache",
        "creative.indesign.cache", "creative.lightroom.previews", "creative.captureone.cache",
        "game.battlenet.cache", "game.prism.cache", "game.heroic.cache", "game.roblox.logs",
        "photos.video", "photos.screenshot", "photos.screen_recording", "photos.duplicate", "photos.similar",
        "photos.utility", "clouds.file", "duplicate.similar",
        "trash.volume", "volume.installer", "volume.appledouble", "volume.appledouble_orphan", "volume.ds_store",
        "volume.time_machine", "volume.photo_library",
    ]

    @Test("Classes, catégories, sections et onglets des Réglages")
    func enums() {
        let keys = SafetyClass.allCases.map(\.localizationKey)
            + ItemCategory.allCases.map(\.localizationKey)
            + AppSection.allCases.map(\.localizationKey)
            + SettingsTab.allCases.map(\.localizationKey)
        for key in keys { #expect(Self.catalog.contains(key), "clé absente : \(key)") }
    }

    @Test("Protections, notes, méthodes et raisons de refus")
    func reasons() {
        let protections: [ProtectionReason] = [
            .activeProcess(name: ""), .uncommittedChanges(count: 0), .gitLocked, .uniqueIgnoredFiles([]),
            .appRunning(name: ""), .inUse, .newestKept, .booted, .needsFullDiskAccess, .systemPath,
            .daemonRunning(name: ""), .unknownState, .usedByAnotherApp(name: ""), .insidePackage(name: ""),
            .activeVersion, .relatedAppInstalled(name: ""), .recentlyWritten(days: 7),
            .photoFavorite, .photoShared, .photoHidden, .timeMachine, .photoLibrary, .virtualMachine, .readOnlyVolume,
            .cloudAppClosed(name: ""), .cloudDisconnected,
        ]
        let notes: [ItemNote] = [.notMerged, .recentlyModified(days: 1), .orphan, .partlyShared, .alreadyClone, .managedSeparately,
                                 .usedByProject(name: ""), .hasEnvironments(count: 1), .estimated, .photoInCloud,
                                 .cloudOnly]
        let methods: [CleanupMethod] = [
            .removeNow, .trash, .gitWorktreeRemove(repository: ""), .simulatorDevice(udid: ""),
            .simulatorRuntime(identifier: ""), .localSnapshot(date: ""), .firefoxHistory(database: ""),
            .cloneOf(original: ""), .manual, .archive(copy: ""),
            .evictLocalCopy, .compressInPlace,
            .uninstallVersion(tool: .pyenv, executable: "", root: "", version: ""), .brewCleanup(executable: ""),
            .containerPrune(executable: "", scope: .buildCache, ids: []),
            .photoAsset(localIdentifier: ""), .trashFromCloud,
            .timeMachineBackup(destination: "", timestamp: ""),
        ]
        let skips: [SkipReason] = [.vanished, .changedSinceScan, .nowProtected(.inUse), .refusedByGuard, .cancelled]
        let keys = protections.map(\.localizationKey) + notes.map(\.localizationKey)
            + methods.map(\.localizationKey) + skips.map(\.localizationKey)
            + MethodFamily.allCases.map(\.localizationKey) + AgeFilter.allCases.map(\.localizationKey)
            + SizeFilter.allCases.map(\.localizationKey)
        for key in keys { #expect(Self.catalog.contains(key), "clé absente : \(key)") }
    }

    @Test("Chaque règle a son titre, son explication et son retour")
    func rules() {
        for id in Self.ruleIDs {
            for part in ["title", "what", "back"] {
                #expect(Self.catalog.contains("rule.\(id).\(part)"), "clé absente : rule.\(id).\(part)")
            }
        }
    }

    @Test("Phase 2 : restes, exclusions, archivage et filtres")
    func phaseTwo() {
        var keys = LeftoverKind.allCases.flatMap { kind in
            ["title", "what", "back"].map { "rule.\(kind.ruleID).\($0)" }
        }
        // Les restes d'applications disparues ont leurs propres explications.
        keys += OrphanFinder.kinds.flatMap { kind in
            ["title", "what", "back"].map { "rule.orphan.\(kind.rawValue).\($0)" }
        }
        keys += AppExclusion.allCases.flatMap { [$0.localizationKey, $0.localizationKey + "_short"] }
        let blockers: [ArchiveBlocker] = [
            .activeProcess(name: ""), .isWorktree, .externalWorktrees(count: 0), .inaccessible, .cloudOnly,
            .containsMountPoint, .systemPath, .unknownState,
        ]
        let errors: [ArchiveError] = [
            .cancelled, .unsupportedFile(path: ""), .crossesVolume(path: ""), .readFailed(path: "", code: 0),
            .copyFailed(path: "", code: 0), .verificationFailed(path: ""), .sourceChanged(path: ""),
        ]
        let refusals: [DestinationRefusal] = [
            .readOnly, .sameVolume, .notEnoughSpace(needed: 0, available: 0), .fileTooLarge(name: ""),
        ]
        let warnings: [FileSystemWarning] = [.exfat, .fat, .network, .unknown]
        keys += blockers.map(\.localizationKey) + errors.map(\.localizationKey) + refusals.map(\.localizationKey)
        keys += warnings.map(\.localizationKey)
        keys += LargeFilesModel.AgePreset.allCases.map(\.localizationKey)
        for key in keys { #expect(Self.catalog.contains(key), "clé absente : \(key)") }
    }

    @Test("Photothèque : onglets, périodes, résultat et coût de retour")
    func photos() {
        let keys = PhotosModel.Tab.allCases.map(\.localizationKey)
            + PhotosModel.Period.allCases.map(\.localizationKey)
            + ["outcome.recentlyDeleted", "rebuild.photosRecentlyDeleted"]
        for key in keys { #expect(Self.catalog.contains(key), "clé absente : \(key)") }
    }

    @Test("Nuages : onglets, durées et coût de retour")
    func clouds() {
        let keys = CloudsModel.Tab.allCases.map(\.localizationKey)
            + CloudsModel.AgePreset.allCases.map(\.localizationKey)
            + ["rebuild.cloudTrash"]
        for key in keys { #expect(Self.catalog.contains(key), "clé absente : \(key)") }
    }
}
