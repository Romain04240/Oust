import Foundation
import OustCore
import OustScan

public enum StorageCategory: String, Sendable, CaseIterable, Identifiable {
    case applications, documents, images, videos, audio, development, archives, other, system, purgeable, free
    public var id: String { rawValue }
    public var localizationKey: String { "storage.category." + rawValue }
}

public struct StoragePart: Sendable, Identifiable {
    public let category: StorageCategory
    public let bytes: Int64
    public var id: StorageCategory { category }
}

/// L'analyse donne les catégories de fichiers ; la capacité en direct borne
/// leur représentation. Le purgeable est séparé, jamais additionné à l'occupé.
public struct StorageBreakdown: Sendable {
    public let observed: [StorageCategory: Int64]
    public init(observed: [StorageCategory: Int64] = [:]) { self.observed = observed }

    public func parts(capacity: Capacity) -> [StoragePart] {
        let kinds = StorageCategory.allCases.filter { $0 != .system && $0 != .purgeable && $0 != .free }
        let sum = kinds.reduce(Int64(0)) { $0 + max(0, observed[$1] ?? 0) }
        let ratio = sum > capacity.occupied && sum > 0 ? Double(capacity.occupied) / Double(sum) : 1
        var result = kinds.compactMap { category -> StoragePart? in
            let bytes = Int64(Double(max(0, observed[category] ?? 0)) * ratio)
            return bytes > 0 ? StoragePart(category: category, bytes: bytes) : nil
        }.sorted { $0.bytes > $1.bytes }
        let attributed = result.reduce(Int64(0)) { $0 + $1.bytes }
        if capacity.occupied > attributed { result.append(StoragePart(category: .system, bytes: capacity.occupied - attributed)) }
        if capacity.purgeable > 0 { result.append(StoragePart(category: .purgeable, bytes: capacity.purgeable)) }
        if capacity.available > 0 { result.append(StoragePart(category: .free, bytes: capacity.available)) }
        return result
    }
}

extension AppModel {
    public func storageTreeIdentifier(for volume: VolumeDescriptor) -> ObjectIdentifier? {
        analyzedTree(for: volume).map(ObjectIdentifier.init)
    }

    public func storageBreakdown(for volume: VolumeDescriptor) async -> StorageBreakdown {
        guard let root = analyzedTree(for: volume) else { return StorageBreakdown() }
        return await Task.detached(priority: .utility) {
            let analytics = TreeAnalytics.compute(root, largestLimit: 0)
            var totals: [StorageCategory: Int64] = [:]
            for entry in analytics.kinds {
                let category: StorageCategory = switch entry.kind {
                case .application: .applications
                case .document: .documents
                case .image: .images
                case .video: .videos
                case .audio: .audio
                case .model, .code: .development
                case .archive, .diskImage: .archives
                case .data, .other: .other
                }
                totals[category, default: 0] += entry.tally.bytes
            }
            totals[.other, default: 0] += analytics.smallFiles.bytes
            return StorageBreakdown(observed: totals)
        }.value
    }
}
