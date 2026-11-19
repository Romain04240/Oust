import Foundation
import OustCore

/// Un fil de navigation, pas une file d'opérations. Les outils gardent leurs
/// propres sélections et confirmations ; passer ne doit même pas les ouvrir.
public struct GuidedReviewSession: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case offering, examining, paused }

    public static let steps: [AppSection] = [
        .applications, .browsers, .system, .timeMachine, .explorer, .largeFiles,
        .duplicates, .photos, .clouds, .developer, .archive, .cart,
    ]

    public let id = UUID()
    /// Une action de l'ancienne étape (ou d'une autre fenêtre) ne peut pas
    /// faire avancer une seconde fois la nouvelle étape.
    public internal(set) var token = UUID()
    public internal(set) var index = 0
    public internal(set) var stage: Stage = .offering
    public var step: AppSection { Self.steps[index] }
    public var completedCount: Int { index }
    let volume: VolumeDescriptor
    let sourceDate: Date
}

extension AppModel {
    public var canStartGuidedReview: Bool {
        guidedReview == nil && section == .overview && !isSearching
            && guidedReviewSource() != nil
    }

    /// L'Explorateur a son propre sélecteur, indépendant de celui de la Vue
    /// d'ensemble. Le guide ne change ni ce choix ni son analyse à sa place.
    public var guidedReviewNeedsStartupExplorer: Bool {
        guard let session = guidedReview, [.explorer, .largeFiles].contains(session.step),
              let displayed = treeVolume else { return false }
        return !sameGuidedReviewVolume(displayed, session.volume)
    }

    /// Premier lot : le démarrage seulement. Les pages globales (Applications,
    /// Photos, navigateurs) ne doivent pas être présentées comme celles d'un
    /// disque externe sélectionné.
    public func startGuidedReview() {
        guard canStartGuidedReview, let (volume, date) = guidedReviewSource() else { return }
        guidedReview = GuidedReviewSession(volume: volume, sourceDate: date)
    }

    public func examineGuidedReview(token: UUID) {
        guard var session = currentGuidedReview(token), session.stage == .offering,
              !guidedReviewNeedsStartupExplorer else { return }
        session.stage = .examining
        session.token = UUID()
        guidedReview = session
        section = session.step
    }

    public func skipGuidedReview(token: UUID) {
        guard let session = currentGuidedReview(token), session.stage == .offering,
              session.index < GuidedReviewSession.steps.count - 1 else { return }
        advanceGuidedReview(session)
    }

    public func completeGuidedReviewStep(token: UUID) {
        guard let session = currentGuidedReview(token), session.stage == .examining,
              !guidedReviewNeedsStartupExplorer else { return }
        guard session.index < GuidedReviewSession.steps.count - 1 else {
            // Terminer ferme le guide, sans action sur le contenu du panier.
            guidedReview = nil
            return
        }
        advanceGuidedReview(session)
    }

    public func pauseGuidedReview(token: UUID) {
        guard currentGuidedReview(token) != nil else { return }
        pauseGuidedReviewForNavigation()
    }

    public func resumeGuidedReview(token: UUID) {
        guard var session = currentGuidedReview(token), session.stage == .paused else { return }
        // La reprise réaffiche le choix Examiner/Passer avant toute nouvelle
        // ouverture. Une recherche en cours reste une navigation libre.
        searchText = ""
        session.stage = .offering
        session.token = UUID()
        guidedReview = session
        section = .overview
    }

    public func endGuidedReview(token: UUID) {
        guard guidedReview?.token == token else { return }
        guidedReview = nil
    }

    func guidedReviewNavigationChanged() {
        guard let session = guidedReview else { return }
        let expected: AppSection = session.stage == .examining ? session.step : .overview
        if section != expected { pauseGuidedReviewForNavigation() }
    }

    func guidedReviewExplorerChanged() {
        guard guidedReview?.stage == .examining, guidedReviewNeedsStartupExplorer else { return }
        pauseGuidedReviewForNavigation()
    }

    func pauseGuidedReviewForNavigation() {
        guard var session = guidedReview, session.stage != .paused else { return }
        session.stage = .paused
        session.token = UUID()
        guidedReview = session
    }

    func invalidateStaleGuidedReview() {
        guard let session = guidedReview else { return }
        if !guidedReviewIsCurrent(session) { guidedReview = nil }
    }

    private func advanceGuidedReview(_ session: GuidedReviewSession) {
        var next = session
        next.index += 1
        next.stage = .offering
        next.token = UUID()
        guidedReview = next
        section = .overview
    }

    private func currentGuidedReview(_ token: UUID) -> GuidedReviewSession? {
        invalidateStaleGuidedReview()
        guard let session = guidedReview, session.token == token else { return nil }
        // Une recherche met en pause via son observateur ; aucune ancienne
        // commande Examiner/Passer n'est alors admise.
        if isSearching && session.stage != .paused { return nil }
        return session
    }

    private func guidedReviewSource() -> (VolumeDescriptor, Date)? {
        guard !analysis.isRunning, cleaning != .running,
              let volume = analyzedVolume, volume.isBoot, volume.isInternal, !volume.isRemovable,
              let date = volumeAnalysisDates[volume.id],
              volumes.contains(where: { sameGuidedReviewVolume($0, volume) }) else { return nil }
        return (volume, date)
    }

    private func guidedReviewIsCurrent(_ session: GuidedReviewSession) -> Bool {
        guard let (volume, date) = guidedReviewSource() else { return false }
        return date == session.sourceDate && sameGuidedReviewVolume(volume, session.volume)
    }

    private func sameGuidedReviewVolume(_ lhs: VolumeDescriptor, _ rhs: VolumeDescriptor) -> Bool {
        lhs.id == rhs.id && lhs.scanRoot == rhs.scanRoot && lhs.mountIdentity == rhs.mountIdentity
            && lhs.isBoot == rhs.isBoot && lhs.isInternal == rhs.isInternal && lhs.isRemovable == rhs.isRemovable
    }
}
