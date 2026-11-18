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

    func beginDuplicateRead() -> DuplicateReadSession.Reader? {
        guard !changingDuplicateExclusions, !Task.isCancelled else { return nil }
        if duplicateReadSession.isRevoked {
            guard duplicateReadSession.isIdle, duplicateNativePanelClosed() else { return nil }
            duplicateReadSession = DuplicateReadSession()
        }
        return duplicateReadSession.reader()
    }

    @discardableResult
    public func excludeDuplicateFolder(_ url: URL) async -> Bool {
        guard cleaning != .running, preferences.duplicateExclusions.isReadable,
              !changingDuplicateExclusions else { return false }
        let revision = duplicateExclusionRevision
        guard let entry = await readDuplicateExclusion(url), revision == duplicateExclusionRevision,
              cleaning != .running else { return false }
        var folders = preferences.duplicateExclusions.folders
        folders.removeAll { $0.id == entry.id }
        folders.append(entry)
        return await applyDuplicateExclusions(DuplicateExclusions(folders: folders))
    }

    private func readDuplicateExclusion(_ url: URL) async -> DuplicateExclusion? {
        guard let reader = beginDuplicateRead() else { return nil }
        return await checkStorageIO {
            defer { withExtendedLifetime(reader) {} }
            return DuplicateExclusion(folder: url)
        } ?? nil
    }

    package func checkDuplicateExclusion(_ entry: DuplicateExclusion) async -> Bool? {
        guard let reader = beginDuplicateRead() else { return nil }
        return await checkStorageIO {
            defer { withExtendedLifetime(reader) {} }
            return entry.isCurrent
        }
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
        duplicateExclusionsTimedOut = false
        changingDuplicateExclusions = true
        defer {
            duplicateExclusionsWaitingForQuickLook = false
            changingDuplicateExclusions = false
        }
        let previous = duplicateReadSession
        previous.revoke()
        for revoke in Array(duplicatePreviewRevokers.values) { revoke() }
        invalidateDuplicateResults()
        let deadline = ContinuousClock.now + duplicateExclusionWaitBudget
        while !Task.isCancelled {
            let panelClosed = duplicateNativePanelClosed()
            duplicateExclusionsWaitingForQuickLook = !panelClosed
            if previous.isIdle, panelClosed {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { break }
                persistDuplicateExclusions(exclusions)
                duplicateReadSession = DuplicateReadSession()
                return true
            }
            guard ContinuousClock.now < deadline else {
                duplicateExclusionsTimedOut = true
                return false
            }
            do { try await Task.sleep(until: min(deadline, .now + .milliseconds(50)), clock: .continuous) }
            catch { return false }
        }
        return false
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
        duplicatePreviewRoots = nil
        duplicatesVolumeID = nil
        similarImages.invalidateExclusionResults()
        let stale = items.values.filter { $0.category == .duplicates || $0.category == .similarImages }.map(\.id)
        remove(stale)
        for id in stale { items.removeValue(forKey: id) }
    }

    func canSearchDuplicates(_ roots: [URL], reader: DuplicateReadSession.Reader) async -> Bool {
        guard !changingDuplicateExclusions else { return false }
        let revision = duplicateExclusionRevision
        let exclusions = preferences.duplicateExclusions
        let allowed = await checkStorageIO {
            defer { withExtendedLifetime(reader) {} }
            return exclusions.canSearch(roots)
        }
        guard !changingDuplicateExclusions, revision == duplicateExclusionRevision, !Task.isCancelled else { return false }
        guard allowed == true else {
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
