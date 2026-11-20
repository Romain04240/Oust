import Darwin
import Foundation
import OustCore
import OustSafety

/// La revue permet de relire un scan, sans constituer une file de nettoyage.
/// Les outils externes et le Finder ne lient pas leur mutation à l'identité contrôlée.
package struct AnalysisReview: Identifiable, Sendable {
    package let id = UUID()
    package let volume: VolumeDescriptor
    let location: Location
    package private(set) var rows: [CleanupItem]
    package private(set) var selection: Set<String> = []

    package static var estimatedGain: Int64 { 0 }

    package var selectedRows: [CleanupItem] { rows.filter { selection.contains($0.id) } }

    package mutating func setSelected(_ id: String, _ selected: Bool) {
        guard rows.contains(where: { $0.id == id }) else { return }
        if selected { selection.insert(id) } else { selection.remove(id) }
    }

    package mutating func toggleGroup(_ category: ItemCategory) {
        let ids = Set(rows.lazy.filter { $0.category == category }.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    package mutating func keepCurrentRows(_ ids: Set<String>) {
        rows.removeAll { !ids.contains($0.id) }
        selection.formIntersection(ids)
    }

    /// Une capacité lue par descripteur est celle du volume identifié, même si
    /// un autre disque occupe le point de montage pendant la lecture.
    struct Location: Sendable {
        let url: URL
        let facts: FileFacts
        let filesystemID: [Int32]

        var mountIdentity: VolumeMountIdentity {
            VolumeMountIdentity(device: facts.device, inode: facts.inode,
                createdSeconds: facts.created.tv_sec, createdNanoseconds: facts.created.tv_nsec,
                filesystemID: filesystemID)
        }

        init?(_ url: URL) {
            guard let resolved = PathGuard.withResolvedParent(url),
                  let facts = FileFacts.of(resolved.path),
                  facts.mode & S_IFMT == S_IFDIR, !facts.isDataless else { return nil }
            var info = statfs()
            guard statfs(resolved.path, &info) == 0 else { return nil }
            self.url = resolved
            self.facts = facts
            self.filesystemID = MountedFileSystems.identity(of: info)
            guard let after = FileFacts.of(resolved.path), identifies(after) else { return nil }
        }

        func matches(_ url: URL) -> Bool {
            guard let current = Location(url), current.url == self.url,
                  current.filesystemID == filesystemID else { return false }
            return identifies(current.facts)
        }

        private func identifies(_ current: FileFacts) -> Bool {
            current.device == facts.device && current.inode == facts.inode
                && current.created.tv_sec == facts.created.tv_sec && current.created.tv_nsec == facts.created.tv_nsec
        }

        func readCapacity(at root: URL) -> CapacityReading? {
            let fd = open(url.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            guard let current = FileFacts.openFile(fd), identifies(current) else { return nil }
            var info = statfs()
            let available = fstatfs(fd, &info) == 0 ? Int64(info.f_bavail) * Int64(info.f_bsize) : nil
            guard matches(root) else { return nil }
            return CapacityReading(available: available)
        }
    }

    package struct CapacityReading: Sendable {
        package let available: Int64?
        // La revue ne lance aucune opération susceptible de libérer des octets.
        package var reclaimed: Int64 { 0 }
    }
}

extension AppModel {
    func saveAnalysisReview(for volume: VolumeDescriptor, location: AnalysisReview.Location?, ids: Set<String>,
                            locationWasVerified: Bool = false) {
        guard let location, analyzingVolumeID == volume.id,
              volumes.contains(where: { $0.id == volume.id }),
              (locationWasVerified || location.matches(volume.scanRoot)), canAnalyzeVolume(volume) else { return }
        let rows = ids.compactMap { items[$0] }.filter { isInReviewVolume($0, volume: volume) }
            .sorted { ($0.category.rawValue, $0.title, $0.id) < ($1.category.rawValue, $1.title, $1.id) }
        analysisReviews[volume.id] = AnalysisReview(volume: volume, location: location, rows: rows)
    }

    private func isInReviewVolume(_ item: CleanupItem, volume: VolumeDescriptor) -> Bool {
        let externalRoots = volumes.lazy.filter { !$0.isBoot }.map { $0.scanRoot.path }
        if volume.isBoot {
            return item.paths.allSatisfy { path in
                !externalRoots.contains { PathNormalizer.isWithin(path.path, $0) }
            }
        }
        return !item.paths.isEmpty && item.paths.allSatisfy {
            PathNormalizer.isWithin($0.path, volume.scanRoot.path)
        }
    }

    package func analysisReview(for volume: VolumeDescriptor) -> AnalysisReview? {
        guard case .done = analysisPhase(for: volume),
              volumes.contains(where: { $0.id == volume.id }),
              canAnalyzeVolume(volume) else { return nil }
        return analysisReviews[volume.id]
    }

    package enum ReviewValidation {
        case confirmed(AnalysisReview.CapacityReading)
        case changed(Set<String>)
        case unavailable
    }

    package func currentAnalysisReviewIDs(for draft: AnalysisReview) -> Set<String> {
        guard analysisReview(for: draft.volume)?.id == draft.id else { return [] }
        return Set(draft.rows.filter {
            items[$0.id] == $0 && isInReviewVolume($0, volume: draft.volume)
        }.map(\.id))
    }

    package func validateAnalysisReview(_ draft: AnalysisReview) async -> ReviewValidation {
        await validateAnalysisReview(draft) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: draft.location.readCapacity(at: draft.volume.scanRoot))
                }
            }
        }
    }

    func validateAnalysisReview(_ draft: AnalysisReview,
                                measure: () async -> AnalysisReview.CapacityReading?) async -> ReviewValidation {
        guard !Task.isCancelled, analysisReview(for: draft.volume)?.id == draft.id,
              !draft.selection.isEmpty else { return .unavailable }
        let before = currentAnalysisReviewIDs(for: draft)
        guard draft.selection.isSubset(of: before) else { return .changed(before) }

        let reading = await measure()
        guard !Task.isCancelled, analysisReview(for: draft.volume)?.id == draft.id,
              let reading else { return .unavailable }
        let after = currentAnalysisReviewIDs(for: draft)
        guard draft.selection.isSubset(of: after) else { return .changed(after) }
        return .confirmed(reading)
    }
}
