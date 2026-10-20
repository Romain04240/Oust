import Foundation
import OustCore
import OustLocalization
import OustLargeFiles
import OustSafety

public struct StorageAdvice: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let bytes: Int64
    public let destination: AppSection
    public let url: URL?
    public var itemIDs: Set<String> = []
}

extension AppModel {
    /// Conseils locaux, à revoir : ni sélection ni déplacement automatique.
    public func refreshAdvice() async {
        guard !adviceSearch.isRunning, !archive.search.isRunning else { return }
        adviceSearch = .running
        await archive.find()
        let inactiveCutoff = Calendar.current.date(byAdding: .month, value: -max(3, archive.inactiveMonths), to: Date()) ?? Date()
        var advice: [StorageAdvice] = archive.candidates.filter { ($0.lastModified ?? .distantFuture) < inactiveCutoff }.prefix(5).map { project in
            StorageAdvice(id: project.id, title: project.name,
                detail: project.isArchivable ? L10n.string("advice.archive", project.lastModified.map { Formatters.relative($0) } ?? "")
                    : L10n.string("advice.project_blocked"),
                bytes: project.sizes.allocated, destination: .archive, url: project.url)
        }
        if let tree = disk.currentTree {
            let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
            let result = await Task.detached(priority: .utility) {
                LargeFileFinder.find(in: tree, filter: LargeFileFilter(minimumSize: 1_000_000_000,
                    unusedSince: cutoff, kinds: [.video, .audio, .archive, .diskImage]))
            }.value
            let guardForAdvice = PathGuard(home: home)
            let projectRoots = preferences.projectRoots
            for file in result.files.filter({ file in
                file.package == nil && guardForAdvice.allows(file.url)
                    && !projectRoots.contains(where: { PathNormalizer.isWithin(file.url.path, $0.path) })
            }).prefix(5) {
                advice.append(StorageAdvice(id: file.id, title: file.url.lastPathComponent,
                    detail: L10n.string("advice.move", file.lastUse.map { Formatters.relative($0) } ?? ""),
                    bytes: file.sizes.allocated, destination: .largeFiles, url: file.url))
            }
        }
        for (id, categories, section) in [
            ("builds", Set<ItemCategory>([.projectArtifacts, .packageCaches, .xcode]), AppSection.developer),
            ("cloud", Set<ItemCategory>([.cloudFiles]), AppSection.system)
        ] {
            let matching = items.values.filter { categories.contains($0.category) && $0.isSelectable && isOnBootVolume($0) }
            let bytes = matching.reduce(Int64(0)) { $0 + $1.sizes.freeable }
            if bytes > 100_000_000 {
                advice.append(StorageAdvice(id: id, title: L10n.string("advice.\(id).title"),
                    detail: L10n.string("advice.\(id).detail"), bytes: bytes, destination: section, url: nil,
                    itemIDs: Set(matching.map(\.id))))
            }
        }
        storageAdvice = advice.sorted { $0.bytes > $1.bytes }
        adviceSearch = .done(Date())
    }

    public func items(for advice: StorageAdvice) -> [CleanupItem] {
        advice.itemIDs.compactMap { items[$0] }.filter(\.isSelectable)
            .sorted { $0.sizes.freeable == $1.sizes.freeable ? $0.id < $1.id : $0.sizes.freeable > $1.sizes.freeable }
    }
}
