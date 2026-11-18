import Foundation
import OustDuplicates

extension AppModel {
    struct DuplicatePreviewRoots {
        let requested: [URL]
        let stamp: AnalysisRoots.Stamp
        let id = UUID()

        init(_ requested: [URL], _ validated: AnalysisRoots) {
            self.requested = requested
            self.stamp = validated.stamp
        }
    }

    package func prepareDuplicatePreview(_ selected: URL, similar: Bool) async -> DuplicatePreviewCopies? {
        guard canUseDuplicateQuickLook,
              let origin = similar ? similarImages.sourceRoots : duplicatePreviewRoots else { return nil }
        let files: [DuplicatePreviewCopies.Source]?
        if similar {
            files = similarImages.groups.first(where: { $0.images.contains(where: { $0.url == selected }) })?
                .images.map(DuplicatePreviewCopies.Source.init)
        } else {
            files = duplicateGroups.first(where: { $0.files.contains(where: { $0.url == selected }) })?
                .files.map(DuplicatePreviewCopies.Source.init)
        }
        guard let files else { return nil }
        let revision = duplicateExclusionRevision
        guard let reader = beginDuplicateRead() else { return nil }
        defer { withExtendedLifetime(reader) {} }
        guard let roots = await resolveAnalysisRoots(origin.requested, reader: reader), roots.stamp == origin.stamp,
              revision == duplicateExclusionRevision, canUseDuplicateQuickLook else { return nil }
        var policy = preferences.duplicateExclusions
        policy.analysisRoots = roots.directories
        let exclusions = policy
        let work = Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(reader) {} }
            return DuplicatePreviewCopies.prepare(selected, sources: files, exclusions: exclusions)
        }
        let prepared = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard let prepared,
              await resolveAnalysisRoots(origin.requested, reader: reader) == roots,
              revision == duplicateExclusionRevision, canUseDuplicateQuickLook,
              origin.id == (similar ? similarImages.sourceRoots : duplicatePreviewRoots)?.id,
              !Task.isCancelled else { return nil }
        return prepared
    }
}
