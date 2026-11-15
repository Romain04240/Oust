import Darwin
import Foundation
import OustCore

/// La dernière barrière avant une suppression (SPEC §5).
///
/// Elle ne juge pas de l'intérêt de supprimer : elle refuse ce qui ne doit
/// jamais l'être, quoi qu'en dise une règle. Un bogue dans un chercheur qui
/// produirait `~/Library` au lieu de `~/Library/Caches/pip` s'arrête ici.
public struct PathGuard: Sendable {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case refused(String)
    }

    private let home: String
    private let exact: Set<String>
    private let userLogRoots: Set<String>
    private let prefixes: [String]
    /// Les pièces jointes, seule chose que l'on retire de Mail et de Messages.
    private let messagesAttachments: String
    private let mailStore: String
    /// Les racines des fichiers dans le nuage, pour l'éviction : `Mobile
    /// Documents/`, puis `CloudStorage/` (lue aussi par `fileProviderAccount`).
    let cloudRoots: [String]
    /// Les racines des autres volumes que le disque de démarrage. `nil` : tout
    /// ce qui est sous `/Volumes/` ; les tests passent leurs faux volumes.
    private let otherVolumeRoots: [String]?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, otherVolumeRoots: [URL]? = nil) {
        let home = home.standardizedFileURL.path
        self.home = home
        let logs = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs")
        self.userLogRoots = Set([logs.path, logs.resolvingSymlinksInPath().path].map(PathNormalizer.normalize))
        self.otherVolumeRoots = otherVolumeRoots.map { $0.map { PathNormalizer.normalize($0.standardizedFileURL.path) } }

        let systemExact = [
            "/", "/System", "/Library", "/Applications", "/Users", "/private", "/private/var",
            "/private/tmp", "/tmp", "/var", "/usr", "/usr/local", "/bin", "/sbin", "/opt", "/opt/homebrew",
            "/Volumes", "/cores", "/etc", "/dev",
        ]
        // Les racines du dossier personnel : on supprime ce qu'elles contiennent,
        // jamais elles-mêmes.
        let homeExact = [
            "", "/Library", "/Library/Caches", "/Library/Application Support", "/Library/Containers",
            "/Library/Group Containers", "/Library/Preferences", "/Library/Developer", "/Library/Logs",
            "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Movies", "/Music", "/Public",
            "/Applications", "/.Trash", "/.claude", "/.codex", "/.cache", "/.config", "/.local",
            "/.npm", "/.gradle", "/.cargo", "/.ssh", "/.gnupg", "/Library/CloudStorage",
            "/.claude.json", "/.codex/auth.json", "/.codex/config.toml",
        ].map { home + $0 }
        self.exact = Set(systemExact + homeExact)

        self.prefixes = [
            "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/lib/", "/usr/libexec/", "/usr/sbin/",
            "/usr/share/", "/private/var/db/", "/private/etc/", "/Library/",
            home + "/Library/Keychains/",
            home + "/Library/Mobile Documents/",
            home + "/Library/Mail/",
            home + "/Library/Messages/",
            home + "/Library/Accounts/",
            home + "/Library/Calendars/",
            home + "/Library/Contacts/",
            home + "/Pictures/Photos Library.photoslibrary/",
            home + "/Music/Music/",
            home + "/.ssh/",
            home + "/.gnupg/",
        ]
        // Comparés à des chemins normalisés : normalisés eux aussi.
        let base = PathNormalizer.normalize(home)
        self.messagesAttachments = base + "/Library/Messages/Attachments/"
        self.mailStore = base + "/Library/Mail/"
        self.cloudRoots = [base + "/Library/Mobile Documents/", base + "/Library/CloudStorage/"]
    }

    public func check(_ url: URL) -> Verdict {
        check(url, protectUserLogs: true)
    }

    /// L’inventaire des restes peut signaler une préférence protégée.
    package func checkLeftoverForInspection(_ url: URL) -> Verdict {
        check(url, protectUserLogs: true, protectPreferences: false)
    }

    private func check(_ url: URL, protectUserLogs: Bool, protectPreferences: Bool = true) -> Verdict {
        let raw = url.path
        guard raw.hasPrefix("/") else { return .refused("relative") }
        guard !raw.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return .refused("dot-components") }
        guard !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .refused("control-characters")
        }

        // Le parent est résolu (un lien symbolique au milieu du chemin pourrait
        // mener ailleurs) ; le dernier élément ne l'est pas : supprimer un lien
        // supprime le lien, pas sa cible.
        guard let resolvedURL = Self.withResolvedParent(url) else { return .refused("unresolved-parent") }
        let resolved = Self.normalize(resolvedURL.path)
        let literal = Self.normalize(raw)
        let candidates = Set([resolved, literal])
        if !exact.isDisjoint(with: candidates) { return .refused("protected-root") }
        if protectUserLogs && protectsUserLogs(url, resolved: resolvedURL) { return .refused("user-logs") }
        if protectPreferences && protectsPreferences(url, resolved: resolvedURL) { return .refused("user-preferences") }
        if protectsSafariDownload(url, resolved: resolvedURL) { return .refused("safari-incomplete-download") }

        for candidate in candidates {
            if prefixes.contains(where: { candidate.hasPrefix($0) }), !isAttachment(candidate) {
                return .refused("protected-area")
            }
            if candidate.split(separator: "/").count < 2 { return .refused("too-shallow") }
            if let reason = volumeRefusal(candidate) { return .refused(reason) }
        }
        return .allowed
    }

    /// Ce qu'un volume porte et qui ne part jamais (`VolumeProtection`) : un
    /// point de montage, les dossiers de service, les sauvegardes Time Machine,
    /// les photothèques ; sur un autre disque que celui de démarrage, sa racine,
    /// son dossier Applications, sa corbeille elle-même (son contenu, oui) et
    /// les machines virtuelles.
    ///
    /// Ce qui est déjà dans une corbeille (`~/.Trash`, `.Trashes/<uid>`) a été
    /// jeté par l'utilisateur : une photothèque ou une machine virtuelle n'y
    /// empêche pas de la vider. Une sauvegarde Time Machine, si.
    func volumeRefusal(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        var prefix = ""
        var inTrash = false
        for component in components {
            prefix += "/" + component
            if VolumeProtection.serviceFolders.contains(component) { return "volume-service" }
            if VolumeProtection.isTimeMachineName(component) { return "time-machine" }
            if VolumeProtection.isTimeMachineSparseBundle(URL(fileURLWithPath: prefix)) { return "time-machine" }
            if !inTrash, VolumeProtection.isPhotoLibrary(component) { return "photo-library" }
            if component == ".Trash" || component == VolumeProtection.volumeTrashFolder { inTrash = true }
        }
        if components.count >= 2, components[0] == "Volumes", components[1] == ".timemachine" { return "time-machine" }
        if Self.isMountPoint(path) { return "mount-point" }
        guard let root = otherVolumeRoot(of: path) else { return nil }
        if path == root { return "volume-root" }
        let relative = path.dropFirst(root.count).split(separator: "/").map(String.init)
        if relative == ["Applications"] { return "protected-root" }
        if relative.first == VolumeProtection.volumeTrashFolder, relative.count <= 2 { return "volume-trash" }
        if !inTrash, relative.contains(where: VolumeProtection.isVirtualMachine) { return "virtual-machine" }
        return nil
    }

    /// La racine de l'autre volume qui contient ce chemin, s'il y en a une.
    func otherVolumeRoot(of path: String) -> String? {
        if let otherVolumeRoots {
            return otherVolumeRoots.first { path == $0 || path.hasPrefix($0 + "/") }
        }
        let components = path.split(separator: "/", maxSplits: 2)
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        return "/Volumes/" + components[1]
    }

    /// Un point de montage, d'après le noyau : `statfs` le nomme comme racine
    /// de son volume. Un chemin qui n'existe pas n'en est pas un.
    static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return PathNormalizer.normalize(mountPoint) == path && path != "/"
    }

    /// Une pièce jointe de Messages ou de Mail : la seule brèche, étroite, dans
    /// les zones protégées de ces deux applications.
    ///
    /// - Messages : un dossier *sous* `~/Library/Messages/Attachments/`, jamais
    ///   ce dossier lui-même ni la base `chat.db` à côté.
    /// - Mail : un dossier sous un dossier `Attachments` d'une boîte de
    ///   `~/Library/Mail/V<n>/`, jamais un message (`.emlx`) ni l'index.
    func isAttachment(_ path: String) -> Bool {
        if path.hasPrefix(messagesAttachments) {
            return !path.dropFirst(messagesAttachments.count).isEmpty
        }
        guard path.hasPrefix(mailStore) else { return false }
        let components = path.dropFirst(mailStore.count).split(separator: "/").map(String.init)
        guard let version = components.first, version.hasPrefix("V"), Int(version.dropFirst()) != nil,
              let marker = components.lastIndex(of: "Attachments"), marker >= 2, marker < components.count - 1 else {
            return false
        }
        return !components.contains { $0.hasSuffix(".emlx") }
    }

    /// L'éviction n'efface rien : le fichier reste dans le nuage. Elle ne vaut
    /// pourtant que pour ce qui est dans le nuage, et nulle part ailleurs.
    public func allowsEviction(_ url: URL) -> Bool {
        let raw = url.path
        guard raw.hasPrefix("/"), !raw.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            return false
        }
        guard !CloudFile.isSafariDownload(url),
              let resolved = Self.withResolvedParent(url),
              !protectsPreferences(url, resolved: resolved),
              !protectsSafariDownload(url, resolved: resolved, protectAncestors: false) else { return false }
        let path = Self.normalize(raw)
        return cloudRoots.contains { root in
            path.hasPrefix(root) && !path.dropFirst(root.count).split(separator: "/").isEmpty
        }
    }

    public func allows(_ url: URL) -> Bool { check(url) == .allowed }

    package func protectsUserPreferences(_ url: URL) -> Bool {
        guard let resolved = Self.withResolvedParent(url) else { return true }
        return protectsPreferences(url, resolved: resolved)
    }

    package func protectsPreferences(_ url: URL, resolved: URL) -> Bool {
        let directory = PreferenceDirectory.url(in: URL(fileURLWithPath: home))
        let identity = PreferenceDirectory(directory.path)
        // Sans accès à Library, une redirection peut encore désigner ce chemin.
        guard !identity.isUncertain else { return true }
        let canonical = directory.resolvingSymlinksInPath()
        let candidates = [url, resolved]
        if candidates.contains(where: {
            PathNormalizer.isWithin(directory.path, $0.path) || PathNormalizer.isWithin(canonical.path, $0.path)
        }) { return true }

        if candidates.contains(where: {
            let parent = $0.deletingLastPathComponent().path
            return Self.normalize(parent) == Self.normalize(directory.path)
                || Self.normalize(parent) == Self.normalize(canonical.path) || identity.matches(parent)
        }) {
            if PreferenceDirectory.isPlist(resolved.lastPathComponent) { return true }
            // APFS peut accepter un autre suffixe pour la même entrée, par
            // exemple « pliſt ». Le noyau connaît le nom enregistré du fichier.
            return Self.canonicalEntryName(at: resolved).map(PreferenceDirectory.isPlist) ?? true
        }

        guard let entry = FileFacts.of(resolved.path),
              (entry.mode & S_IFMT) == S_IFDIR || (entry.mode & S_IFMT) == S_IFLNK else { return false }
        let target = (entry.mode & S_IFMT) == S_IFLNK
            ? FileFacts.of(resolved.resolvingSymlinksInPath().path) : nil
        // Un répertoire qui emporte les préférences doit être refusé même
        // quand le dernier composant a une autre casse sur APFS.
        for root in [directory, canonical] {
            var ancestor = root
            while ancestor.path != "/" {
                if let current = FileFacts.of(ancestor.path),
                   (current.device == entry.device && current.inode == entry.inode)
                    || (current.device == target?.device && current.inode == target?.inode) { return true }
                ancestor.deleteLastPathComponent()
            }
        }
        return false
    }

    private static func canonicalEntryName(at url: URL) -> String? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_NAME)
        let recordSize = 12
        var buffer = [UInt8](repeating: 0, count: recordSize + Int(NAME_MAX) + 4)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(url.path, &attributes, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let end = Int(raw.loadUnaligned(as: UInt32.self))
            let start = 4 + Int(raw.loadUnaligned(fromByteOffset: 4, as: Int32.self))
            let length = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            guard end <= raw.count, start >= recordSize, start <= end, length > 1, length <= end - start,
                  raw[start + length - 1] == 0 else { return nil }
            return String(bytes: raw[start..<(start + length - 1)], encoding: .utf8)
        }
    }

    /// Protège Téléchargements, ses ancêtres et les paquets, même via un lien.
    package func protectsSafariDownload(_ url: URL, resolved: URL, protectAncestors: Bool = true) -> Bool {
        let downloads = URL(fileURLWithPath: home).appendingPathComponent("Downloads")
        let physicalDownloads = downloads.resolvingSymlinksInPath()
        let roots = [downloads.path, physicalDownloads.path].map { Self.normalize($0).lowercased() }
        func isDownload(_ raw: String) -> Bool {
            let path = Self.normalize(raw).lowercased()
            return roots.contains { root in
                if path == root || (protectAncestors && PathNormalizer.isWithin(root, path)) { return true }
                let prefix = root + "/"
                return path.hasPrefix(prefix) && SafariDownloadPath.containsPackage(String(path.dropFirst(prefix.count)))
            }
        }
        if isDownload(url.path) || isDownload(resolved.path) { return true }
        // APFS accepte des équivalences de casse qui ne survivent pas à lowercased().
        guard let facts = FileFacts.of(resolved.path) else { return false }
        func matchesIdentity(_ candidate: FileFacts, _ url: URL) -> Bool {
            guard let facts = FileFacts.of(url.path) else { return false }
            return candidate.device == facts.device && candidate.inode == facts.inode
        }
        func identifiesDownloads(_ candidate: FileFacts) -> Bool {
            if matchesIdentity(candidate, downloads) || matchesIdentity(candidate, physicalDownloads) { return true }
            // Un ancêtre de la destination redirigée peut aussi avoir un autre
            // nom accepté par APFS (p. ex. un worktree écrit avec une autre casse).
            guard protectAncestors, roots[0] != roots[1] else { return false }
            var ancestor = physicalDownloads.deletingLastPathComponent()
            while ancestor.path.count > 1 {
                if matchesIdentity(candidate, ancestor) { return true }
                ancestor.deleteLastPathComponent()
            }
            return false
        }
        if (facts.mode & S_IFMT) == S_IFDIR { return identifiesDownloads(facts) }
        guard (facts.mode & S_IFMT) == S_IFLNK else { return false }
        if identifiesDownloads(facts) { return true }
        let target = resolved.resolvingSymlinksInPath()
        return isDownload(target.path) || FileFacts.of(target.path).map(identifiesDownloads) == true
    }

    /// Résout le plus proche ancêtre existant, puis rattache les composants absents.
    /// Le dernier composant reste le nom de l'entrée que l'appelant va déplacer.
    public static func withResolvedParent(_ url: URL) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !url.path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        if url.path == "/" { return url }
        var parent = url.deletingLastPathComponent()
        var suffix = [url.lastPathComponent]
        while true {
            if let resolved = realpath(parent.path, nil) {
                defer { free(resolved) }
                return suffix.reversed().reduce(URL(fileURLWithPath: String(cString: resolved), isDirectory: true)) {
                    $0.appendingPathComponent($1)
                }
            }
            guard errno == ENOENT, parent.path != "/" else { return nil }
            var info = stat()
            guard lstat(parent.path, &info) != 0, errno == ENOENT else { return nil }
            suffix.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
    }

    /// Protège la racine, ses ancêtres et les journaux, indépendamment de leur règle.
    public func protectsUserLogs(_ url: URL) -> Bool {
        guard let resolved = Self.withResolvedParent(url) else { return true }
        return protectsUserLogs(url, resolved: resolved)
    }

    private func protectsUserLogs(_ url: URL, resolved: URL) -> Bool {
        let logs = URL(fileURLWithPath: home).appendingPathComponent("Library/Logs")
        let roots = userLogRoots.union([PathNormalizer.normalize(logs.resolvingSymlinksInPath().path)])
        var paths = [url.path, resolved.path]
        var info = stat()
        if lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            // Le Finder peut suivre aussi le dernier lien au moment de déplacer.
            guard let target = realpath(resolved.path, nil) else { return true }
            defer { free(target) }
            paths.append(String(cString: target))
        }
        return paths.contains { raw in
            let path = PathNormalizer.normalize(raw)
            return roots.contains { root in
                let candidate = path.lowercased()
                let base = root.lowercased()
                // L'exception Roblox ne vaut que dans son propre sous-arbre.
                return candidate == "/" || PathNormalizer.isWithin(base, candidate)
                    || (PathNormalizer.isWithin(candidate, base) && !PathNormalizer.isWithin(path, root + "/Roblox"))
            }
        }
    }

    /// Un journal utilisateur reste sous sa racine réelle, même après l'analyse.
    public func allowsUserLog(_ url: URL) -> Bool {
        userLogParent(url) != nil
    }

    public func userLogParent(_ url: URL) -> URL? {
        userLogLocation(url)?.parent
    }

    /// Le dossier de premier niveau peut porter l'identifiant exact du bundle.
    public func userLogLocation(_ url: URL) -> (parent: URL, bundleDirectory: String?)? {
        let root = PathNormalizer.normalize(URL(fileURLWithPath: home).appendingPathComponent("Library/Logs").path)
        let literal = PathNormalizer.normalize(url.path)
        guard literal.hasPrefix(root + "/"), check(url, protectUserLogs: false) == .allowed else { return nil }
        let homeURL = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        let expected = PathNormalizer.normalize(homeURL.appendingPathComponent("Library/Logs").path)
        let parent = url.deletingLastPathComponent()
        let relativeParent = PathNormalizer.normalize(parent.path).dropFirst(root.count)
        let resolved = parent.resolvingSymlinksInPath()
        guard PathNormalizer.normalize(resolved.path) == expected + relativeParent else { return nil }
        let folder = relativeParent.split(separator: "/").first
        let bundleDirectory = folder.flatMap { $0.contains(".") ? String($0) : nil }
        return (resolved, bundleDirectory)
    }

    // MARK: Nuages

    /// Les gestionnaires de mots de passe : leur coffre reste où il est, même
    /// dans le nuage (la même liste que celle des caches d'applications).
    public static let passwordManagerMarkers = [
        "1password", "onepassword", "agilebits", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "sinew",
        "keeper", "nordpass", "roboform", "strongbox", "proton.pass", "protonpass", "passwords", "secrets",
        "keychain", "authenticator", "passbolt", "psono", "minimalist.pass",
    ]

    /// Les dossiers que Google Drive intercale avant ceux de l'utilisateur : on
    /// n'en jette jamais un entier.
    public static let cloudContainerFolders: Set<String> = [
        "My Drive", "Mon Drive", "Mi unidad", "Meine Ablage", "Il mio Drive", "Shared drives", "Drive partagés",
        "Other computers", "Autres ordinateurs",
    ]

    /// Mettre à la corbeille du Mac un fichier d'un nuage, que le service
    /// supprime alors partout (section Nuages, accord de Romain du 18/10/2026).
    ///
    /// La seule brèche dans `Mobile Documents`, étroite : un élément *dans*
    /// iCloud Drive (`com~apple~CloudDocs`) ou *dans* le dossier `Documents`
    /// d'une application, ce que le Finder montre sous iCloud Drive ; jamais le
    /// dossier d'un service lui-même, ni ce qu'une application garde pour elle
    /// (`Data`), ni un coffre de mots de passe, ni un élément caché (`.Trash`).
    /// Sous `CloudStorage`, de même : jamais la racine d'un compte ni « Mon
    /// Drive » entier. Ailleurs (le Bureau et les Documents synchronisés par
    /// iCloud Drive), la garde ordinaire.
    public func allowsCloudTrash(_ url: URL) -> Bool {
        let raw = url.path
        guard raw.hasPrefix("/"), !raw.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        guard !CloudFile.isSafariDownload(url),
              let real = Self.withResolvedParent(url), !protectsPreferences(url, resolved: real),
              !protectsSafariDownload(url, resolved: real) else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = Self.normalize((parent as NSString).appendingPathComponent(url.lastPathComponent))
        let literal = Self.normalize(raw)
        // Le dossier des nuages lui-même compte comme dedans : il n'est pas un document.
        let inClouds = [resolved, literal].map { path in cloudRoots.contains { path.hasPrefix($0) || path + "/" == $0 } }
        // Un lien au milieu du chemin ne fait pas passer un fichier d'un côté à l'autre.
        guard inClouds[0] == inClouds[1] else { return false }
        guard inClouds[0] else { return allows(url) }
        return isCloudDocument(resolved) && isCloudDocument(literal)
    }

    /// Un document de l'utilisateur dans un nuage, d'après son seul chemin.
    func isCloudDocument(_ path: String) -> Bool {
        guard let root = cloudRoots.first(where: { path.hasPrefix($0) }) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/").map(String.init)
        guard let container = components.first, !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        let lower = container.lowercased()
        if Self.passwordManagerMarkers.contains(where: lower.contains) { return false }
        let rest = components.dropFirst()
        if root == cloudRoots[0] {
            // `Mobile Documents/`
            if container == "com~apple~CloudDocs" { return !rest.isEmpty }
            return rest.count >= 2 && rest.first == "Documents"
        }
        // `CloudStorage/` : un compte, puis au moins un élément, deux sous « Mon Drive ».
        guard let first = rest.first else { return false }
        return Self.cloudContainerFolders.contains(first) ? rest.count >= 2 : true
    }

    /// La garde raisonne sur un seul nom par dossier (voir `PathNormalizer`).
    static func normalize(_ path: String) -> String {
        PathNormalizer.normalize(path)
    }
}
