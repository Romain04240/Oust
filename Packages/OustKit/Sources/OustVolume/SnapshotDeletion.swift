import Foundation
import OustCore
import OustHelperContract

/// La disparition vérifiée, date par date, et les raisons de l'échec.
public struct SnapshotDeletionReport: Sendable {
    public var deleted: Set<String>
    public var failures: [String: String]

    public init(deleted: Set<String> = [], failures: [String: String] = [:]) {
        self.deleted = deleted
        self.failures = failures
    }
}

extension VolumeService {
    public static func deleteSnapshotResults(_ snapshots: [LocalSnapshot],
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (CleanupPhase) -> Void = { _ in }) async -> SnapshotDeletionReport {
        await deleteSnapshotResults(snapshots, listing: { await readLocalSnapshots() },
            helper: { dates in
                await PrivilegedHelper.deleteSnapshots(dates: dates, timeout: 30 + 300 * Double(dates.count),
                    deletionStarted: { progress(.deletingSnapshots(count: dates.count)) }, isCancelled: isCancelled)
            }, administrator: { snapshots in
                guard let script = deletionScript(for: snapshots) else { return .notRun }
                return await Command.run("/usr/bin/osascript", ["-e", script], timeout: 30 + 300 * Double(snapshots.count))
            }, isCancelled: isCancelled, progress: progress)
    }

    /// Les tests remplacent les outils ; jamais un vrai snapshot n'est supprimé.
    static func deleteSnapshotResults(
        _ snapshots: [LocalSnapshot],
        listing: () async -> [LocalSnapshot]?,
        helper: ([String]) async -> PrivilegedHelper.Call<DeletionResponse>,
        administrator: ([LocalSnapshot]) async -> CommandResult,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (CleanupPhase) -> Void = { _ in }
    ) async -> SnapshotDeletionReport {
        let dates = snapshots.compactMap(\.date)
        guard deletionScript(for: snapshots) != nil else {
            return SnapshotDeletionReport(failures: Dictionary(dates.map { ($0, "snapshot.error.invalid") }, uniquingKeysWith: { a, _ in a }))
        }
        progress(.revalidating)
        guard let before = await listing() else {
            return SnapshotDeletionReport(failures: Dictionary(dates.map { ($0, "snapshot.error.listing") }, uniquingKeysWith: { a, _ in a }))
        }
        let listed = Set(before.compactMap(\.date))
        var report = SnapshotDeletionReport(deleted: Set(dates).subtracting(listed))
        var pending = snapshots.filter { listed.contains($0.date ?? "") }
        // Le démon accepte au plus 64 dates. Les listes longues sont découpées,
        // sans rejouer en administrateur une demande dont le délai a expiré.
        while !pending.isEmpty {
            if isCancelled() {
                for date in pending.compactMap(\.date) { report.failures[date] = "snapshot.error.cancelled" }
                break
            }
            let chunk = Array(pending.prefix(HelperContract.maximumSnapshotsPerRequest))
            pending.removeFirst(chunk.count)
            let requested = chunk.compactMap(\.date)
            var errors: [String: String] = [:]
            var useAdministrator = false
            progress(.checkingSnapshotComponent)
            switch await helper(requested) {
            case .unreachable: useAdministrator = true
            case .timedOut:
                for date in requested + pending.compactMap(\.date) { report.failures[date] = "snapshot.error.timeout" }
                return report
            case .answered(let response):
                for result in response.results where result.outcome == .failed {
                    errors[result.date] = result.message ?? "snapshot.error.unverified"
                }
                // Le démon peut ne pas avoir l'Accès complet au disque alors
                // qu'Oust! l'a : seul un refus d'autorisation permet ce repli.
                useAdministrator = response.refusal != nil || errors.values.contains { message in
                    let text = message.lowercased()
                    return text.contains("operation not permitted") || text.contains("full disk access")
                        || text.contains("permission denied")
                }
            }
            if useAdministrator {
                progress(.revalidating)
                guard let current = await listing() else {
                    for date in requested { report.failures[date] = "snapshot.error.listing" }
                    continue
                }
                let currentDates = Set(current.compactMap(\.date))
                report.deleted.formUnion(Set(requested).subtracting(currentDates))
                let retry = chunk.filter { currentDates.contains($0.date ?? "") }
                if isCancelled() {
                    for date in retry.compactMap(\.date) + pending.compactMap(\.date) { report.failures[date] = "snapshot.error.cancelled" }
                    return report
                }
                // L'invite et tmutil forment un appel macOS opaque : on ne peut
                // pas prétendre savoir à quel moment l'autorisation est validée.
                if !retry.isEmpty { progress(.authorizingSnapshots(count: retry.count)) }
                let result = retry.isEmpty ? CommandResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
                    : await administrator(retry)
                if !result.succeeded {
                    let message = result.timedOut ? "snapshot.error.timeout"
                        : result.errorOutput.contains("-128") ? "snapshot.error.cancelled"
                        : result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    for date in requested { errors[date] = message.isEmpty ? "snapshot.error.unverified" : String(message.prefix(500)) }
                    if result.timedOut {
                        for date in requested + pending.compactMap(\.date) { report.failures[date] = "snapshot.error.timeout" }
                        return report
                    }
                }
            }
            progress(.verifyingSnapshots)
            guard let after = await listing() else {
                for date in requested { report.failures[date] = errors[date] ?? "snapshot.error.listing" }
                continue
            }
            let remaining = Set(after.compactMap(\.date))
            for date in requested {
                if remaining.contains(date) { report.failures[date] = errors[date] ?? "snapshot.error.unverified" }
                else { report.deleted.insert(date) }
            }
            if errors.values.contains("snapshot.error.cancelled") { break }
        }
        return report
    }
}
