import Foundation
import OustCore
import OustLocalization

/// Les phrases que l'interface compose à partir du domaine.
public enum Describe {

    public static func rebuild(_ cost: RebuildCost) -> String {
        switch cost {
        case .nothing: L10n.string("rebuild.nothing")
        case .automatic: L10n.string("rebuild.automatic")
        case .command(let command, let minutes):
            if let minutes { L10n.string("rebuild.command_minutes", command, String(minutes)) }
            else { L10n.string("rebuild.command", command) }
        case .download: L10n.string("rebuild.download")
        case .irreversible: L10n.string("rebuild.irreversible")
        case .photosRecentlyDeleted: L10n.string("rebuild.photosRecentlyDeleted")
        case .cloudTrash: L10n.string("rebuild.cloudTrash")
        }
    }

    public static func protection(_ reason: ProtectionReason) -> String {
        if let argument = reason.argument { return L10n.string(reason.localizationKey, argument) }
        return L10n.string(reason.localizationKey)
    }

    public static func note(_ note: ItemNote) -> String {
        if let argument = note.argument { return L10n.string(note.localizationKey, argument) }
        return L10n.string(note.localizationKey)
    }

    public static func method(_ method: CleanupMethod) -> String {
        L10n.string(method.localizationKey)
    }

    public static func skip(_ reason: SkipReason) -> String {
        if case .nowProtected(let reason) = reason {
            return L10n.string("skip.nowProtected", Describe.protection(reason))
        }
        return L10n.string(reason.localizationKey)
    }

    public static func outcome(_ result: OutcomeResult) -> String {
        switch result {
        case .removed: L10n.string("outcome.removed")
        case .trashed: L10n.string("outcome.trashed")
        case .delegated: L10n.string("outcome.delegated")
        case .cloned: L10n.string("outcome.cloned")
        case .evicted: L10n.string("outcome.evicted")
        case .compressed: L10n.string("outcome.compressed")
        case .recentlyDeleted: L10n.string("outcome.recentlyDeleted")
        case .skipped(let reason): skip(reason)
        case .failed(let message): L10n.string("outcome.failed",
            message.hasPrefix("snapshot.error.") || message == "logs.user.error.restore_conflict"
                ? L10n.string(message) : message)
        }
    }

    public static func ruleTitle(_ id: String) -> String { L10n.string("rule.\(id).title") }
    public static func ruleWhat(_ id: String) -> String { L10n.string("rule.\(id).what") }
    public static func ruleBack(_ id: String) -> String { L10n.string("rule.\(id).back") }

    /// Le symbole d'une méthode.
    public static func symbol(_ method: CleanupMethod) -> String {
        switch method {
        case .removeNow: "bolt.fill"
        case .trash: "trash.square"
        case .gitWorktreeRemove: "arrow.triangle.branch"
        case .simulatorDevice, .simulatorRuntime: "iphone.gen3"
        case .localSnapshot: "clock.arrow.circlepath"
        case .timeMachineBackup: "externaldrive.badge.timemachine"
        case .firefoxHistory: "flame"
        case .cloneOf: "square.on.square.dashed"
        case .evictLocalCopy: "icloud.and.arrow.up"
        case .compressInPlace: "arrow.down.right.and.arrow.up.left"
        case .uninstallVersion: "square.stack.3d.down.right"
        case .brewCleanup: "mug"
        case .containerPrune: "shippingbox.circle"
        case .manual: "hand.raised"
        case .archive: "externaldrive.badge.checkmark"
        case .photoAsset: "photo.on.rectangle.angled"
        case .trashFromCloud: "icloud.slash"
        }
    }
}
