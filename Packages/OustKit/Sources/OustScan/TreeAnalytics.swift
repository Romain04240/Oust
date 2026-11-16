import Foundation
import OustCore

/// La famille d'un fichier, d'après son extension : ce que TreeSize appelle
/// « types de fichiers ».
public enum FileKind: String, Sendable, CaseIterable, Identifiable {
    case video, image, audio, archive, diskImage, application, model, code, document, data, other

    public var id: String { rawValue }
    public var localizationKey: String { "filekind.\(rawValue)" }

    public var symbol: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .diskImage: "opticaldisc"
        case .application: "app.dashed"
        case .model: "brain"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        case .data: "cylinder.split.1x2"
        case .other: "questionmark.square.dashed"
        }
    }

    static let table: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: String) {
            for ext in extensions.split(separator: " ") { table[String(ext)] = kind }
        }
        // Complétée le 18/10/2026 d'après une vraie analyse : 287 Go tombaient
        // dans « Autres », surtout des données cartographiques (.pbf, .bil,
        // .pmtiles, .hrg) et des modèles d'Apple (.bnnsir, .weights).
        add(.video, "mp4 mov mkv avi m4v webm wmv flv mpg mpeg mts m2ts braw r3d prores insv")
        add(.image, "jpg jpeg png heic heif gif tiff tif bmp webp raw cr2 cr3 nef arw dng psd psb afphoto svg exr")
        add(.audio, "mp3 wav aiff aif flac m4a aac ogg caf logicx alac pcm aifc band")
        add(.archive, "zip gz tgz bz2 xz 7z rar tar zst lz4 xip jar war")
        add(.diskImage, "dmg iso img sparseimage sparsebundle vmdk vdi qcow2 vhd vhdx raw ipsw hdd vmem utm")
        add(.application, "app pkg mpkg dylib framework so a o appex bundle pak node car asar ttf otf ttc")
        add(.model, "safetensors gguf ggml onnx pt pth ckpt mlmodel mlpackage mlmodelc tflite npz npy weights bnnsir atx espresso")
        add(.code, "swift m h c cc cpp hpp js mjs cjs ts tsx jsx py rb go rs java kt dart php cs json yaml yml toml xml html css scss map wasm")
        add(.document, "pdf doc docx pages key keynote ppt pptx xls xlsx numbers txt md rtf epub csv emlx eml")
        add(.data, "sqlite sqlite3 db realm parquet arrow log jsonl ndjson dat bin pack idx tracev3 pbf osm bil hgt pmtiles mbtiles hrg geojson gpkg shp dem fst")
        return table
    }()

    public static func of(_ name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        return table[ext] ?? .other
    }
}

/// L'ancienneté d'un fichier, d'après sa dernière modification.
public enum AgeRange: Int, Sendable, CaseIterable, Identifiable {
    case month, halfYear, year, twoYears, older, unknown

    public var id: Int { rawValue }
    public var localizationKey: String {
        switch self {
        case .month: "age.month"
        case .halfYear: "age.half_year"
        case .year: "age.year"
        case .twoYears: "age.two_years"
        case .older: "age.older"
        case .unknown: "age.unknown"
        }
    }

    static func of(_ date: Date?, now: Date) -> AgeRange {
        guard let date else { return .unknown }
        let days = now.timeIntervalSince(date) / 86_400
        switch days {
        case ..<31: return .month
        case ..<183: return .halfYear
        case ..<366: return .year
        case ..<731: return .twoYears
        default: return .older
        }
    }
}

/// Un total : octets et nombre de fichiers.
public struct Tally: Sendable, Hashable {
    public var bytes: Int64 = 0
    public var count: Int = 0

    mutating func add(_ size: Int64, count: Int = 1) {
        bytes += size
        self.count += count
    }
}

/// Un gros fichier, pour la liste des plus gros.
public struct LargeFile: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let folder: String
    public let sizes: Sizes
    public let modified: Date?
    /// Le fichier et son dossier dans l'arbre, pour le mettre à la corbeille.
    public let leaf: FileLeaf
    public let parent: TreeNode
}

/// Ce que TreeSize montre à côté de l'arborescence : types, âges, plus gros
/// fichiers, nombre de dossiers (SPEC §3.3).
///
/// Calculé d'une traversée de l'arbre déjà construit, sans relire le disque.
/// Seuls les fichiers assez gros pour être des feuilles sont classés un à un ;
/// les petits sont comptés à part, et on le dit, plutôt que de les attribuer à
/// une famille au hasard.
public struct TreeAnalytics: Sendable {
    public let kinds: [(kind: FileKind, tally: Tally)]
    public let extensions: [(ext: String, kind: FileKind, tally: Tally)]
    public let ages: [(range: AgeRange, tally: Tally)]
    public let largest: [LargeFile]
    public let smallFiles: Tally
    /// Nombre de sous-dossiers de chaque nœud, descendants compris.
    public let folderCounts: [ObjectIdentifier: Int]

    public func folders(in node: TreeNode) -> Int {
        folderCounts[ObjectIdentifier(node)] ?? 0
    }

    public static func compute(_ root: TreeNode, largestLimit: Int = 200, now: Date = Date()) -> TreeAnalytics {
        var kinds: [FileKind: Tally] = [:]
        var extensions: [String: Tally] = [:]
        var ages: [AgeRange: Tally] = [:]
        var small = Tally()
        var largest: [LargeFile] = []
        var folderCounts: [ObjectIdentifier: Int] = [:]
        var threshold: Int64 = 0

        // Post-ordre itératif : le nombre de dossiers d'un nœud s'obtient de ceux
        // de ses enfants, et la pile d'un thread n'aime pas la récursion profonde.
        var stack: [(TreeNode, Bool)] = [(root, false)]
        while let (node, visited) = stack.popLast() {
            if visited {
                folderCounts[ObjectIdentifier(node)] = node.children.reduce(node.children.count) {
                    $0 + (folderCounts[ObjectIdentifier($1)] ?? 0)
                }
                continue
            }
            stack.append((node, true))
            for child in node.children { stack.append((child, false)) }

            let base = node.path
            for file in node.files {
                let kind = FileKind.of(file.name)
                let ext = (file.name as NSString).pathExtension.lowercased()
                kinds[kind, default: Tally()].add(file.sizes.allocated)
                extensions[ext.isEmpty ? "—" : ext, default: Tally()].add(file.sizes.allocated)
                ages[AgeRange.of(file.modified, now: now), default: Tally()].add(file.sizes.allocated)
                if largest.count < largestLimit || file.sizes.allocated > threshold {
                    largest.append(LargeFile(path: base + "/" + file.name, name: file.name, folder: base,
                                             sizes: file.sizes, modified: file.modified, leaf: file, parent: node))
                    if largest.count > largestLimit * 2 {
                        largest.sort { $0.sizes.allocated > $1.sizes.allocated }
                        largest.removeLast(largest.count - largestLimit)
                        threshold = largest.last?.sizes.allocated ?? 0
                    }
                }
            }
            if node.smallFileCount > 0 {
                small.add(node.smallFiles.allocated, count: node.smallFileCount)
            }
        }
        largest.sort { $0.sizes.allocated > $1.sizes.allocated }

        return TreeAnalytics(
            kinds: kinds.map { ($0.key, $0.value) }.sorted { $0.1.bytes > $1.1.bytes },
            extensions: extensions.map { ($0.key, FileKind.of("x." + $0.key), $0.value) }
                .sorted { $0.2.bytes > $1.2.bytes }.prefix(60).map { $0 },
            ages: AgeRange.allCases.compactMap { range in ages[range].map { (range, $0) } },
            largest: Array(largest.prefix(largestLimit)),
            smallFiles: small,
            folderCounts: folderCounts
        )
    }

    /// Les dossiers et fichiers dont le nom contient `query`, du plus gros au
    /// plus petit — la recherche de TreeSize.
    public static func search(_ root: TreeNode, query: String, limit: Int = 300) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        var stack: [TreeNode] = [root]
        while let node = stack.popLast() {
            if node !== root, node.name.localizedCaseInsensitiveContains(needle) {
                hits.append(.folder(node))
            }
            for file in node.files where file.name.localizedCaseInsensitiveContains(needle) {
                hits.append(.file(file, node))
            }
            stack.append(contentsOf: node.children)
        }
        return Array(hits.sorted { $0.allocated > $1.allocated }.prefix(limit))
    }

    /// Le contenu d'un dossier en CSV : une ligne par sous-dossier et gros
    /// fichier, séparateur point-virgule pour qu'Excel et Numbers en français
    /// l'ouvrent sans réglage.
    public func csv(for node: TreeNode, includeGains: Bool = true) -> String {
        func field(_ path: String) -> String {
            // Le nom habituel (`/Users/…`), pas celui du volume de données.
            let text = path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        var lines = ["Chemin;Type;Octets alloués;Octets libérables;Part du parent;Fichiers;Dossiers;Modifié"]
        let total = Double(max(1, node.total.allocated))
        for child in node.children {
            lines.append([
                field(child.path), "dossier", String(child.total.allocated), String(includeGains ? child.total.freeable : 0),
                String(format: "%.4f", Double(child.total.allocated) / total), String(child.fileCount),
                String(folders(in: child)), child.latestModification.map(formatter.string(from:)) ?? "",
            ].joined(separator: ";"))
        }
        for file in node.files {
            lines.append([
                field(node.path + "/" + file.name), "fichier", String(file.sizes.allocated), String(includeGains ? file.sizes.freeable : 0),
                String(format: "%.4f", Double(file.sizes.allocated) / total), "1", "0",
                file.modified.map(formatter.string(from:)) ?? "",
            ].joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Un résultat de recherche dans l'arborescence.
public enum SearchHit: Sendable, Identifiable {
    case folder(TreeNode)
    case file(FileLeaf, TreeNode)

    public var id: String { path }

    public var path: String {
        switch self {
        case .folder(let node): node.path
        case .file(let file, let parent): parent.path + "/" + file.name
        }
    }

    public var name: String {
        switch self {
        case .folder(let node): node.name
        case .file(let file, _): file.name
        }
    }

    public var allocated: Int64 {
        switch self {
        case .folder(let node): node.total.allocated
        case .file(let file, _): file.sizes.allocated
        }
    }
}
