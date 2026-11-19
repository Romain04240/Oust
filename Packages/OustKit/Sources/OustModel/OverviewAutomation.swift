import Foundation
import OustCore
import OustBrowsers

struct BrowserAnalysisSnapshot: Sendable {
    var profiles: [BrowserProfile]
    var items: [CleanupItem]
}

struct BootAnalysisRequest: Sendable {
    let id = UUID()
    let volume: VolumeDescriptor?
    let preselect: Bool
    let selectionRevision: UInt64
}

extension AppModel {
    /// La tâche appartient au modèle : deux fenêtres rejoignent la même analyse.
    public func requestOverviewAnalysis() {
        guard analysisVolumeID == nil || analyzedVolume?.isBoot == true else { return }
        overviewAnalysisRequested = true
        drainOverviewAnalysisRequest()
    }

    func reserveBootAnalysis(_ volume: VolumeDescriptor?, preselect: Bool) -> BootAnalysisRequest? {
        guard !analysis.isRunning, overviewAnalysisTask == nil, bootAnalysisRequest == nil, volumeAnalysisAttempt == nil,
              let volume, volume.isBoot, volume.isInternal, !volume.isRemovable,
              volumes.contains(where: { $0.id == volume.id && $0.mountIdentity == volume.mountIdentity }) else { return nil }
        let request = BootAnalysisRequest(volume: volume, preselect: preselect, selectionRevision: cartSelectionRevision)
        bootAnalysisRequest = request
        analyzingVolumeID = volume.id
        overviewAnalysisInterrupted = false
        setOverviewAnalysisStopping(false)
        analysis = .running
        return request
    }

    func drainOverviewAnalysisRequest() {
        guard overviewAnalysisRequested, !overviewAnalysisStarted,
              let volume = analyzedVolume, volume.isBoot else { return }
        if volumeAnalysisDates[volume.id] != nil {
            overviewAnalysisStarted = true
            return
        }
        guard let request = reserveBootAnalysis(volume, preselect: false) else { return }
        overviewAnalysisStarted = true
        launchOverviewAnalysis(request)
    }

    private func launchOverviewAnalysis(_ request: BootAnalysisRequest) {
        overviewAnalysisTask = Self.backgroundStorageTask { [self] in
            defer { overviewAnalysisTask = nil }
            await runBootAnalysis(request)
        }
    }

    public func analyzeOverview() async {
        guard !analysis.isRunning else { return }
        if let volume = analyzedVolume, !volume.isBoot {
            await analyzeOtherVolume(volume)
            return
        }
        guard let request = reserveBootAnalysis(bootVolume, preselect: false) else { return }
        overviewAnalysisStarted = true
        launchOverviewAnalysis(request)
        await overviewAnalysisTask?.value
    }

    public func stopOverviewAnalysis() {
        // Une demande d'arrêt ne lance pas une autre analyse automatique.
        guard overviewAnalysisTask != nil, analysis.isRunning else { return }
        setOverviewAnalysisStopping(true)
        overviewAnalysisTask?.cancel()
    }

    public func canStopOverviewAnalysis(on volume: VolumeDescriptor) -> Bool {
        canStopOverviewAnalysis && bootAnalysisRequest?.volume?.id == volume.id
            && bootAnalysisRequest?.volume?.mountIdentity == volume.mountIdentity
    }

    public func stopOverviewAnalysis(on volume: VolumeDescriptor) {
        guard canStopOverviewAnalysis(on: volume) else { return }
        stopOverviewAnalysis()
    }

    public var canStopOverviewAnalysis: Bool { overviewAnalysisTask != nil && bootAnalysisRequest != nil && analysis.isRunning }

    func isCurrentBootAnalysis(_ request: BootAnalysisRequest, location: AnalysisReview.Location) async -> Bool {
        guard !Task.isCancelled, bootAnalysisRequest?.id == request.id,
              let volume = request.volume, let current = bootVolume,
              current.id == volume.id, current.mountIdentity == volume.mountIdentity,
              volumes.contains(where: { $0.id == volume.id && $0.mountIdentity == volume.mountIdentity }) else { return false }
        let matches = await checkStorageIO { location.matches(volume.scanRoot) }
        return matches == true && !Task.isCancelled && bootAnalysisRequest?.id == request.id
            && bootVolume?.id == volume.id && bootVolume?.mountIdentity == volume.mountIdentity
            && volumes.contains(where: { $0.id == volume.id && $0.mountIdentity == volume.mountIdentity })
    }
}
