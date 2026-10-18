import Foundation

/// Les éléments que l'aperçu fait défiler : une liste, ou un groupe, dans
/// l'ordre où l'écran les montre. On ne tourne pas en boucle : au bout, on
/// reste au bout.
public struct PhotoSequence: Sendable, Hashable {
    public let entries: [PhotoEntry]
    public private(set) var index: Int

    /// `nil` si la liste est vide. Un identifiant inconnu ouvre sur le premier.
    public init?(_ entries: [PhotoEntry], at id: String) {
        guard !entries.isEmpty else { return nil }
        self.entries = entries
        self.index = entries.firstIndex { $0.id == id } ?? 0
    }

    public var current: PhotoEntry { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count - 1 }

    /// Rend vrai si l'élément montré a changé.
    @discardableResult
    public mutating func step(_ delta: Int) -> Bool {
        let next = min(max(0, index + delta), entries.count - 1)
        guard next != index else { return false }
        index = next
        return true
    }

    public mutating func show(_ id: String) {
        if let found = entries.firstIndex(where: { $0.id == id }) { index = found }
    }
}
