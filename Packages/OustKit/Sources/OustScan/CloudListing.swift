import Darwin
import Foundation
import Synchronization

/// Un fichier d'un nuage tel que le Mac le connaît, sans que son contenu ait été lu.
///
/// iCloud Drive et les File Providers (Google Drive, OneDrive, Dropbox…) laissent
/// sur le disque un fichier « fantôme » (`SF_DATALESS`) quand le contenu reste en
/// ligne : il porte son nom, sa date et sa taille logique, et n'occupe presque
/// rien. La taille logique est celle du nuage ; la taille allouée, ce que le
/// fichier occupe sur ce Mac.
public struct CloudListedFile: Sendable, Hashable {
    public let path: String
    /// La taille du fichier, celle que compte le nuage.
    public let logicalSize: Int64
    /// Ce qu'il occupe sur ce Mac : rien pour un fantôme.
    public let allocatedSize: Int64
    /// Ce que sa suppression rendrait ici quand des blocs sont partagés avec un
    /// clone ; nil sinon (la taille allouée fait foi).
    public let privateSize: Int64?
    public let modified: Date?
    public let fileID: UInt64
    /// Le contenu est resté dans le nuage.
    public let isDataless: Bool
    /// Un document en paquet (`.pages`, `.rtfd`, `.logicx`), compté comme un fichier.
    public let isPackage: Bool

    public init(path: String, logicalSize: Int64, allocatedSize: Int64, privateSize: Int64? = nil, modified: Date?,
                fileID: UInt64, isDataless: Bool, isPackage: Bool = false) {
        self.path = path
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.privateSize = privateSize
        self.modified = modified
        self.fileID = fileID
        self.isDataless = isDataless
        self.isPackage = isPackage
    }
}

/// Ce qu'un dossier de nuage laisse voir sur ce Mac.
public struct CloudListing: Sendable {
    public var files: [CloudListedFile] = []
    /// Les dossiers restés dans le nuage (`SF_DATALESS`) : jamais ouverts, leur
    /// contenu n'est pas compté.
    public var unlistedFolders: [String] = []
    /// Les dossiers que macOS a refusé de lire (droits, erreur).
    public var unreadableFolders: [String] = []

    public init() {}
}

/// Parcourt un dossier de nuage sans jamais rien télécharger.
///
/// Trois précautions, dans cet ordre :
/// - la matérialisation des fichiers fantômes est coupée pour tout le processus
///   (`setiopolicy_np`, la même que celle de l'analyse) : même une erreur de
///   parcours ne peut pas déclencher de téléchargement ;
/// - un dossier fantôme n'est jamais ouvert : l'ouvrir demanderait sa liste au
///   service ;
/// - aucun contenu n'est lu : `getattrlistbulk` rend les tailles et les dates
///   que le service a déjà posées sur le disque.
///
/// Le parcours ne quitte pas le volume (RULES.md, règle 10), ne suit aucun
/// lien symbolique (le dossier iCloud Drive en contient deux, vers le Bureau et
/// les Documents) et saute ce que le Finder cache : `.Trash`, `.tmp`,
/// `.DS_Store`, fichiers marqués invisibles.
public enum CloudLister {

    /// Les documents en paquet : un seul fichier pour l'utilisateur, un dossier
    /// pour le disque. Les compter fichier par fichier ferait proposer d'en
    /// jeter un morceau.
    public static let packageExtensions: Set<String> = [
        "pages", "numbers", "key", "rtfd", "logicx", "band", "fcpbundle", "imovielibrary", "photoslibrary",
        "musiclibrary", "tvlibrary", "aplibrary", "lrlibrary", "sparsebundle", "app", "bundle", "framework",
        "xcodeproj", "xcworkspace", "playground", "scriv", "sketch", "graffle", "oo3", "mindnode", "ulysses",
        "nb", "dtBase2", "dtSparse", "pkg", "mpkg", "dmgpart", "mlpackage", "xcarchive", "playgroundbook",
        // Apple Books range ses livres en dossiers : 98 600 fichiers dans le nuage
        // de Romain, quand sa bibliothèque compte quelques centaines de livres
        // (vérification du 18/10/2026).
        "epub", "ibooks",
    ]

    /// `UF_HIDDEN` : caché dans le Finder.
    static let hiddenFlag: UInt32 = 0x0000_8000

    /// Liste `root` et ce qu'il contient. `progress` reçoit, de temps en temps,
    /// le nombre de fichiers vus depuis son dernier appel.
    public static func list(
        _ root: URL,
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (Int) -> Void = { _ in }
    ) -> CloudListing {
        Scanner.configureProcessIOPolicy()
        var listing = CloudListing()
        var info = stat()
        let rootPath = root.standardizedFileURL.path
        guard lstat(rootPath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return listing }
        if info.st_flags & Attr.sfDataless != 0 {
            listing.unlistedFolders.append(rootPath)
            return listing
        }
        let device = info.st_dev
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 128 * 1024, alignment: 16)
        defer { buffer.deallocate() }
        var stack = [rootPath]
        var seen = 0
        while let directory = stack.popLast() {
            if isCancelled() { break }
            let entries = read(directory, buffer: buffer)
            guard let entries else {
                listing.unreadableFolders.append(directory)
                continue
            }
            for entry in entries {
                let path = directory + "/" + entry.name
                switch classify(entry, device: device) {
                case .skip:
                    continue
                case .unlisted:
                    listing.unlistedFolders.append(path)
                case .folder:
                    stack.append(path)
                case .package:
                    if let package = measurePackage(path, entry: entry, device: device, buffer: buffer) {
                        listing.files.append(package)
                        seen += 1
                    } else {
                        // Une partie du paquet est restée dans le nuage : sa taille
                        // n'est pas connue, on ne l'invente pas.
                        listing.unlistedFolders.append(path)
                    }
                case .file:
                    listing.files.append(file(entry, path: path, directory: directory))
                    seen += 1
                }
                if seen >= 2_000 {
                    progress(seen)
                    seen = 0
                }
            }
        }
        progress(seen)
        return listing
    }

    // MARK: Lecture d'un dossier

    enum Kind: Equatable {
        case skip, unlisted, folder, package, file
    }

    /// Ce qu'on fait d'une entrée. Pur : testé sans disque.
    static func classify(_ entry: RawEntry, device: Int32) -> Kind {
        guard entry.error == 0, !entry.name.isEmpty else { return .skip }
        // Ce que le Finder cache, et ce que les services y rangent pour eux.
        if entry.name.hasPrefix(".") || entry.flags & hiddenFlag != 0 { return .skip }
        switch entry.type {
        case Attr.typeDirectory:
            // Un autre volume, un firmlink : on ne le parcourt pas (règle 10).
            if entry.isMountPoint || entry.isFirmlink || entry.device != device { return .skip }
            if entry.isDataless { return .unlisted }
            let ext = (entry.name as NSString).pathExtension
            return packageExtensions.contains(ext) || packageExtensions.contains(ext.lowercased()) ? .package : .folder
        case Attr.typeRegular:
            return entry.device == device ? .file : .skip
        default:
            // Liens symboliques et le reste : jamais suivis.
            return .skip
        }
    }

    static func file(_ entry: RawEntry, path: String, directory: String) -> CloudListedFile {
        // La part privée n'est demandée que si des blocs peuvent être partagés.
        var privateSize: Int64?
        if entry.mayShareBlocks, !entry.isDataless {
            privateSize = BulkReader.privateSize(path: path)
        }
        return CloudListedFile(
            path: path, logicalSize: entry.logicalSize, allocatedSize: entry.allocated, privateSize: privateSize,
            modified: entry.modified, fileID: entry.fileID, isDataless: entry.isDataless
        )
    }

    /// Les entrées d'un dossier, ou nil s'il n'a pas pu être lu.
    static func read(_ directory: String, buffer: UnsafeMutableRawBufferPointer) -> [RawEntry]? {
        // `O_NOFOLLOW` : un dossier remplacé par un lien depuis la liste ne nous
        // emmène pas ailleurs.
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var entries: [RawEntry] = []
        var status = BulkReader.read(directoryFD: fd, extended: true, buffer: buffer) { entries.append($0) }
        if status == EINVAL {
            // Un volume qui refuse les attributs étendus : on recommence sans.
            entries.removeAll()
            lseek(fd, 0, SEEK_SET)
            status = BulkReader.read(directoryFD: fd, extended: false, buffer: buffer) { entries.append($0) }
        }
        return status == 0 ? entries : nil
    }

    /// Un paquet compté comme un seul fichier : la somme de ce qu'il contient.
    ///
    /// Ses fichiers fantômes comptent pour leur taille dans le nuage et pour
    /// rien ici ; le paquet n'est « en ligne seulement » que si tous le sont.
    /// Nil si un de ses dossiers est resté dans le nuage (sa taille n'est pas
    /// connue) ou n'a pas pu être lu.
    static func measurePackage(_ path: String, entry: RawEntry, device: Int32,
                               buffer: UnsafeMutableRawBufferPointer) -> CloudListedFile? {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var files = 0
        var ghosts = 0
        var stack = [path]
        while let directory = stack.popLast() {
            guard let entries = read(directory, buffer: buffer) else { return nil }
            for child in entries where child.error == 0 {
                if child.type == Attr.typeDirectory {
                    if child.isMountPoint || child.device != device { continue }
                    if child.isDataless { return nil }
                    stack.append(directory + "/" + child.name)
                } else if child.type == Attr.typeRegular {
                    files += 1
                    logical += child.logicalSize
                    if child.isDataless { ghosts += 1 } else { allocated += child.allocated }
                }
            }
        }
        // La date du paquet lui-même : c'est elle que la revalidation relira
        // avant de le jeter (RULES.md, règle 2).
        return CloudListedFile(path: path, logicalSize: logical, allocatedSize: allocated, modified: entry.modified,
                               fileID: entry.fileID, isDataless: files > 0 && ghosts == files, isPackage: true)
    }
}

/// Un compteur partagé entre le parcours et l'interface.
public final class CloudListingProgress: Sendable {
    private let count = Atomic<Int>(0)

    public init() {}

    public var files: Int { count.load(ordering: .relaxed) }
    public func set(_ value: Int) { count.store(value, ordering: .relaxed) }
    public func add(_ value: Int) { count.add(value, ordering: .relaxed) }
}
