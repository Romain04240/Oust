import Darwin
import Foundation
import OustCore
import OustSafety

/// Les modèles IA locaux : coûteux à retélécharger, jamais présélectionnés.
struct ModelFinder {
    let context: RuleContext

    func find() async -> [Candidate] {
        let fileManager = FileManager.default
        var candidates: [Candidate] = []

        // HuggingFace : un dossier par modèle ; les fichiers de `snapshots/` sont
        // des liens vers `blobs/`, que le parcours ne suit pas, donc rien n'est
        // compté deux fois.
        let hub = context.path(".cache/huggingface/hub")
        for entry in fileManager.children(of: hub) where fileManager.isDirectory(entry) {
            let name = entry.lastPathComponent
            guard name.hasPrefix("models--") || name.hasPrefix("datasets--") else { continue }
            let display = name.split(separator: "--", omittingEmptySubsequences: true).dropFirst().joined(separator: "/")
            candidates.append(Candidate(item: CleanupItem(
                title: display.isEmpty ? name : display, detail: "Hugging Face", paths: [entry],
                category: .aiModels, owner: "Hugging Face", ruleID: "model.huggingface", safety: .review,
                method: .trash, lastActivity: entry.modificationDate, rebuild: .download
            )))
        }

        // LM Studio (emplacement actuel et ancien).
        for base in [".lmstudio/models", ".cache/lm-studio/models"] {
            for publisher in fileManager.children(of: context.path(base)) where fileManager.isDirectory(publisher) {
                for model in fileManager.children(of: publisher) where fileManager.isDirectory(model) {
                    candidates.append(Candidate(item: CleanupItem(
                        title: "\(publisher.lastPathComponent)/\(model.lastPathComponent)", detail: "LM Studio",
                        paths: [model], category: .aiModels, owner: "LM Studio", ruleID: "model.lmstudio",
                        safety: .review, method: .trash, lastActivity: model.modificationDate, rebuild: .download
                    )))
                }
            }
        }

        // Ollama : ses blobs sont partagés entre modèles ; on montre l'ensemble
        // et on renvoie à `ollama rm`, seul à savoir ce qui est encore utilisé.
        let ollama = context.path(".ollama/models")
        if fileManager.isDirectory(ollama) {
            candidates.append(Candidate(item: CleanupItem(
                title: "Ollama", detail: ollama.abbreviated(home: context.home), paths: [ollama],
                category: .aiModels, owner: "Ollama", ruleID: "model.ollama", safety: .review,
                method: .manual, lastActivity: ollama.modificationDate, rebuild: .download
            )))
        }

        // Dossiers « models » d'applications (dictée, transcription…).
        let support = context.path("Library/Application Support")
        for app in fileManager.children(of: support) where fileManager.isDirectory(app) {
            let models = app.appendingPathComponent("models")
            guard fileManager.isDirectory(models) else { continue }
            candidates.append(Candidate(item: CleanupItem(
                title: app.lastPathComponent, detail: models.abbreviated(home: context.home), paths: [models],
                category: .aiModels, owner: app.lastPathComponent, ruleID: "model.app_models", safety: .review,
                method: .trash, lastActivity: models.modificationDate, rebuild: .download
            )))
        }
        return candidates
    }
}

/// Le contenu de l'utilisateur : téléchargements, corbeille, sauvegardes, VM.
struct UserContentFinder {
    let context: RuleContext

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    func find() async -> [Candidate] {
        let fileManager = FileManager.default
        var candidates: [Candidate] = []

        // Téléchargements : paquets Safari en lecture seule, installeurs et gros fichiers anciens.
        let downloads = context.path("Downloads")
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let safariDirectory = safariDownloadDirectory(at: downloads)
        for entry in (try? fileManager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: Array(keys))) ?? [] {
            if SafariDownloadPath.hasPackageExtension(entry.lastPathComponent) {
                if let safariDirectory, let facts = localDirectory(entry), facts.device == safariDirectory.device {
                    let modified = facts.modificationDate
                    candidates.append(Candidate(item: CleanupItem(
                        title: entry.lastPathComponent, detail: modified.formatted(date: .abbreviated, time: .omitted),
                        paths: [entry], category: .downloads, owner: "Safari", ruleID: CleanupItem.incompleteSafariDownloadRuleID,
                        safety: .protected, protections: [.unknownState], method: .manual,
                        lastActivity: modified, rebuild: .irreversible,
                        fingerprint: Fingerprint(modificationDate: modified, fileID: facts.inode)
                    ), location: AnalyzedItemLocation(directory: safariDirectory, entry: facts)))
                }
                // Un .download non reconnu ne doit pas ressortir comme gros fichier ancien.
                continue
            }
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            let modified = values.contentModificationDate
            let age = modified.map { context.now.timeIntervalSince($0) } ?? 0
            let isInstaller = Self.installerExtensions.contains(entry.pathExtension.lowercased())
            if isInstaller && size >= 10_000_000 {
                candidates.append(Candidate(item: CleanupItem(
                    title: entry.lastPathComponent, detail: modified.map { "\($0.formatted(date: .abbreviated, time: .omitted))" },
                    paths: [entry], category: .downloads, owner: "Downloads", ruleID: "downloads.installer",
                    safety: .review, method: .trash, lastActivity: modified, rebuild: .download
                )))
            } else if values.isDirectory != true, size >= context.largeDownloadBytes, age > 30 * 86_400 {
                candidates.append(Candidate(item: CleanupItem(
                    title: entry.lastPathComponent, detail: modified.map { "\($0.formatted(date: .abbreviated, time: .omitted))" },
                    paths: [entry], category: .downloads, owner: "Downloads", ruleID: "downloads.large",
                    safety: .review, method: .trash, lastActivity: modified, rebuild: .irreversible
                )))
            }
        }

        // Corbeille : son contenu, vidé d'un coup.
        let trash = context.path(".Trash")
        if let contents = try? fileManager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
            let items = contents.filter { $0.lastPathComponent != ".DS_Store" }
            if !items.isEmpty {
                candidates.append(Candidate(item: CleanupItem(
                    id: "trash|\(trash.path)", title: "Corbeille", detail: "\(items.count)", paths: items,
                    category: .trash, owner: "Finder", ruleID: "trash.contents", safety: .review,
                    method: .removeNow, rebuild: .irreversible
                )))
            }
        } else if fileManager.fileExists(atPath: trash.path) {
            var item = CleanupItem(id: "trash|\(trash.path)", title: "Corbeille", paths: [trash], category: .trash,
                                   owner: "Finder", ruleID: "trash.contents", safety: .review, method: .removeNow,
                                   rebuild: .irreversible)
            item.protect(.needsFullDiskAccess)
            candidates.append(Candidate(item: item, needsMeasure: false))
        }

        // Sauvegardes iOS : on garde toujours la plus récente.
        let backups = context.path("Library/Application Support/MobileSync/Backup")
        let backupEntries = fileManager.children(of: backups).filter { fileManager.isDirectory($0) }
        let newest = backupEntries.max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        for backup in backupEntries {
            var item = CleanupItem(
                title: Self.backupName(backup) ?? backup.lastPathComponent,
                detail: backup.modificationDate.map { $0.formatted(date: .abbreviated, time: .omitted) },
                paths: [backup], category: .iosBackups, owner: "iOS", ruleID: "ios.backup", safety: .review,
                method: .trash, lastActivity: backup.modificationDate, rebuild: .irreversible
            )
            if backup == newest { item.protect(.newestKept) }
            candidates.append(Candidate(item: item))
        }

        // Machines virtuelles et images Docker : gérées à part, hors du total en titre.
        let vmFolders = ["Virtual Machines.localized", "Virtual Machines", "Parallels",
                         "Library/Containers/com.utmapp.UTM/Data/Documents", ".tart/vms", ".lume"]
        for folder in vmFolders {
            for vm in fileManager.children(of: context.path(folder)) where fileManager.isDirectory(vm) || vm.pathExtension == "utm" {
                guard !vm.lastPathComponent.hasPrefix(".") else { continue }
                candidates.append(Candidate(item: CleanupItem(
                    title: vm.deletingPathExtension().lastPathComponent, detail: folder, paths: [vm],
                    category: .virtualMachines, owner: "VM", ruleID: "vm.image", safety: .review,
                    notes: [.managedSeparately], method: .trash, lastActivity: vm.modificationDate,
                    rebuild: .irreversible
                )))
            }
        }
        let docker = context.path("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        if fileManager.fileExists(atPath: docker.path) {
            candidates.append(Candidate(item: CleanupItem(
                title: "Docker.raw", detail: "Docker Desktop", paths: [docker], category: .virtualMachines,
                owner: "Docker", ruleID: "vm.docker", safety: .review, notes: [.managedSeparately],
                method: .manual, rebuild: .irreversible
            )))
        }
        return candidates
    }

    private func safariDownloadDirectory(at downloads: URL) -> FileFacts? {
        guard context.volume == nil,
              let expected = PathGuard.withResolvedParent(downloads),
              PathNormalizer.normalize(downloads.resolvingSymlinksInPath().path) == PathNormalizer.normalize(expected.path),
              let directory = localDirectory(downloads),
              let home = FileFacts.of(downloads.deletingLastPathComponent().resolvingSymlinksInPath().path),
              directory.device == home.device,
              (try? downloads.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true else { return nil }
        return directory
    }

    private func localDirectory(_ url: URL) -> FileFacts? {
        guard let facts = FileFacts.of(url.path), (facts.mode & S_IFMT) == S_IFDIR, !facts.isDataless,
              let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .isAliasFileKey]),
              values.isUbiquitousItem != true, values.isAliasFile != true else { return nil }
        return facts
    }

    /// Le nom de l'appareil, lu dans `Info.plist` de la sauvegarde.
    static func backupName(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return object["Device Name"] as? String
    }
}
