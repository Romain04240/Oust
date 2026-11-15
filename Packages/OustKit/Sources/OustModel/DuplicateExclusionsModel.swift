import AppKit
import Foundation
import QuickLookUI
import OustCore
import OustDuplicates

extension AppModel {
    /// Coup d'œil ouvre lui-même les URL, y compris celles des voisins.
    public var canUseDuplicateQuickLook: Bool {
        !changingDuplicateExclusions && preferences.duplicateExclusions == DuplicateExclusions()
    }

    public func setDuplicatePreviewRevoker(for window: UUID, _ revoke: (() -> Void)?) {
        duplicatePreviewRevokers[window] = revoke
    }

    @discardableResult
    public func excludeDuplicateFolder(_ url: URL) async -> Bool {
        guard cleaning != .running, preferences.duplicateExclusions.isReadable,
              !changingDuplicateExclusions, let entry = DuplicateExclusion(folder: url) else { return false }
        var folders = preferences.duplicateExclusions.folders
        folders.removeAll { $0.id == entry.id }
        folders.append(entry)
        return await applyDuplicateExclusions(DuplicateExclusions(folders: folders))
    }

    public func removeDuplicateExclusion(_ id: URL) async {
        guard cleaning != .running, preferences.duplicateExclusions.isReadable else { return }
        let remaining = preferences.duplicateExclusions.folders.filter { $0.id != id }
        _ = await applyDuplicateExclusions(DuplicateExclusions(folders: remaining))
    }

    public func resetUnreadableDuplicateExclusions() async {
        guard cleaning != .running, !preferences.duplicateExclusions.isReadable else { return }
        _ = await applyDuplicateExclusions(DuplicateExclusions())
    }

    private func applyDuplicateExclusions(_ exclusions: DuplicateExclusions) async -> Bool {
        guard !changingDuplicateExclusions else { return false }
        guard exclusions != preferences.duplicateExclusions else { return true }
        changingDuplicateExclusions = true
        defer {
            duplicateExclusionsWaitingForQuickLook = false
            changingDuplicateExclusions = false
        }
        let previous = duplicateReadSession
        previous.revoke()
        for revoke in Array(duplicatePreviewRevokers.values) { revoke() }
        invalidateDuplicateResults()
        duplicateExclusionsWaitingForQuickLook = !duplicateNativePanelClosed()
        await previous.drain()
        defer { duplicateReadSession = DuplicateReadSession() }
        // La révocation des URL ne prouve pas que le panneau de macOS a disparu.
        // Tant qu'il est visible, les anciennes exclusions restent en vigueur.
        while !duplicateNativePanelClosed() {
            duplicateExclusionsWaitingForQuickLook = true
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        guard !Task.isCancelled else { return false }
        persistDuplicateExclusions(exclusions)
        return true
    }

    static func isNativeDuplicatePreviewClosed() -> Bool {
        if NSApp?.windows.contains(where: { $0 is QLPreviewPanel && $0.isVisible }) == true {
            return false
        }
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return true }
        return QLPreviewPanel.shared()?.isVisible == false
    }

    func invalidateDuplicateResults() {
        duplicateExclusionRevision += 1
        duplicateExclusionBlocked = false
        duplicateProgress.cancel()
        duplicates = .idle
        duplicateGroups = []
        duplicatesVolumeID = nil
        similarImages.invalidateExclusionResults()
        let stale = items.values.filter { $0.category == .duplicates || $0.category == .similarImages }.map(\.id)
        remove(stale)
        for id in stale { items.removeValue(forKey: id) }
    }

    func canSearchDuplicates(_ roots: [URL]) -> Bool {
        guard !changingDuplicateExclusions else { return false }
        guard preferences.duplicateExclusions.canSearch(roots) else {
            invalidateDuplicateResults()
            duplicateExclusionBlocked = true
            return false
        }
        duplicateExclusionBlocked = false
        return true
    }

    private var requiresCurrentDuplicateResults: Bool {
        duplicateExclusionRevision != 0 || preferences.duplicateExclusions != DuplicateExclusions()
    }

    func isCurrentExactGroup(_ group: DuplicateGroup) -> Bool {
        !requiresCurrentDuplicateResults || duplicateGroups.contains { $0.id == group.id && $0.files == group.files }
    }

    func isCurrentSimilarGroup(_ group: SimilarImageGroup) -> Bool {
        !requiresCurrentDuplicateResults || similarImages.groups.contains { $0.images == group.images }
    }

    func isCurrentDuplicateSelection(_ item: CleanupItem) -> Bool {
        guard requiresCurrentDuplicateResults else { return true }
        switch item.category {
        case .duplicates:
            return items[item.id]?.category == .duplicates && items[item.id]?.paths == item.paths
                || duplicateGroups.contains { $0.files.contains { [$0.url] == item.paths } }
        case .similarImages:
            return similarImages.groups.contains { $0.images.contains { [$0.url] == item.paths } }
        default:
            return true
        }
    }
}
