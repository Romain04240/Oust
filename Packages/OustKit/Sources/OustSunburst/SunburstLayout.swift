import Foundation
import OustScan

/// Un segment de la vue soleil : un dossier, un gros fichier, les petits
/// fichiers d'un dossier, ou ce qui était trop fin pour être dessiné seul.
public struct SunburstSegment: Sendable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case directory
        case file
        /// Les fichiers de moins de 1 Mo du dossier parent, regroupés par l'analyse.
        case smallFiles(count: Int)
        /// Les éléments trop fins pour un trait à eux, réunis (« Autres »).
        case others(count: Int)
    }

    public let id: String
    public let name: String
    /// Le chemin du dossier ou du fichier ; celui du parent pour un regroupement.
    public let path: String
    public let kind: Kind
    /// 1 pour l'anneau intérieur.
    public let depth: Int
    /// En fraction de tour, à partir de midi dans le sens horaire.
    public let start: Double
    public let end: Double
    public let bytes: Int64
    /// Le rang de l'ancêtre de premier niveau : il donne la couleur. `nil` pour
    /// les regroupements, qui prennent la couleur neutre « Autres ».
    public let branch: Int?
    /// Le dossier, pour y entrer d'un clic.
    public let node: TreeNode?

    public var span: Double { end - start }
    public var middle: Double { (start + end) / 2 }
}

/// La vue soleil d'une arborescence (SPEC §10, phase 2) : chaque anneau est un
/// niveau, chaque segment occupe la part de son parent qu'il occupe sur le disque.
///
/// Le calcul est fait une fois par racine, hors de la vue : le dessin ne fait que
/// lire des angles, et le test de survol aussi.
public struct SunburstLayout: Sendable {
    public let root: TreeNode
    public let rings: Int
    public let segments: [SunburstSegment]

    /// `minimumSpan` : en dessous (en fraction de tour), un élément rejoint les
    /// « Autres » de son parent. 0,4 % ≈ 1,4° : sous ce seuil, un segment n'est
    /// plus qu'un trait que la souris ne peut pas viser.
    public init(root: TreeNode, rings: Int = 4, minimumSpan: Double = 0.004) {
        self.root = root
        self.rings = max(1, rings)
        self.segments = Self.compute(root: root, rings: max(1, rings), minimumSpan: minimumSpan)
    }

    private struct Pending {
        let node: TreeNode
        let depth: Int
        let start: Double
        let end: Double
        let branch: Int?
    }

    private static func compute(root: TreeNode, rings: Int, minimumSpan: Double) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []
        var pending = [Pending(node: root, depth: 1, start: 0, end: 1, branch: nil)]

        while let job = pending.popLast() {
            let node = job.node
            let total = Double(node.total.allocated)
            guard total > 0, job.depth <= rings else { continue }
            let width = job.end - job.start

            // Les dossiers, les gros fichiers et les petits fichiers, du plus gros au
            // plus petit : ce que TreeSize appelle le contenu d'un dossier.
            var parts: [(name: String, path: String, kind: SunburstSegment.Kind, bytes: Int64, node: TreeNode?)] = []
            for child in node.children where child.total.allocated > 0 {
                parts.append((child.name, child.path, .directory, child.total.allocated, child))
            }
            let base = node.path.hasSuffix("/") ? node.path : node.path + "/"
            for file in node.files where file.sizes.allocated > 0 {
                parts.append((file.name, base + file.name, .file, file.sizes.allocated, nil))
            }
            if node.smallFiles.allocated > 0 {
                parts.append(("", node.path, .smallFiles(count: node.smallFileCount), node.smallFiles.allocated, nil))
            }
            parts.sort { $0.bytes > $1.bytes }

            var cursor = job.start
            var othersBytes: Int64 = 0
            var othersCount = 0
            var drawn = 0
            for part in parts {
                let span = width * Double(part.bytes) / total
                guard span >= minimumSpan else {
                    othersBytes += part.bytes
                    othersCount += 1
                    continue
                }
                let isGroup: Bool = if case .smallFiles = part.kind { true } else { false }
                let branch = job.depth == 1 ? (isGroup ? nil : drawn) : job.branch
                if !isGroup { drawn += 1 }
                let segment = SunburstSegment(
                    id: isGroup ? part.path + "#small" : part.path, name: part.name, path: part.path, kind: part.kind,
                    depth: job.depth, start: cursor, end: cursor + span, bytes: part.bytes,
                    branch: isGroup ? nil : branch, node: part.node
                )
                segments.append(segment)
                if let child = part.node, job.depth < rings {
                    pending.append(Pending(node: child, depth: job.depth + 1, start: segment.start, end: segment.end,
                                           branch: branch))
                }
                cursor += span
            }
            if othersBytes > 0 {
                let span = width * Double(othersBytes) / total
                segments.append(SunburstSegment(
                    id: node.path + "#others", name: "", path: node.path, kind: .others(count: othersCount),
                    depth: job.depth, start: cursor, end: min(job.end, cursor + span), bytes: othersBytes,
                    branch: nil, node: nil
                ))
            }
        }
        return segments.sorted { $0.depth == $1.depth ? $0.start < $1.start : $0.depth < $1.depth }
    }

    // MARK: Survol

    /// Le segment sous un point exprimé en coordonnées polaires.
    public func segment(atTurn turn: Double, ring: Int) -> SunburstSegment? {
        let turn = turn - turn.rounded(.down)
        return segments.first { $0.depth == ring && $0.start <= turn && turn < $0.end }
    }

    /// Le segment sous un point de la vue, `nil` au centre ou hors des anneaux.
    public func segment(at point: CGPoint, center: CGPoint, holeRadius: CGFloat, ringWidth: CGFloat) -> SunburstSegment? {
        guard let (turn, ring) = Self.polar(point, center: center, holeRadius: holeRadius, ringWidth: ringWidth),
              ring <= rings else { return nil }
        return segment(atTurn: turn, ring: ring)
    }

    /// Fraction de tour (0 à midi, sens horaire) et anneau (1 au centre) d'un point,
    /// ou `nil` dans le trou central. Axe vertical vers le bas, comme SwiftUI.
    public static func polar(_ point: CGPoint, center: CGPoint, holeRadius: CGFloat,
                             ringWidth: CGFloat) -> (turn: Double, ring: Int)? {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= Double(holeRadius), ringWidth > 0 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let ring = Int((radius - Double(holeRadius)) / Double(ringWidth)) + 1
        return (angle / (2 * .pi), ring)
    }
}
