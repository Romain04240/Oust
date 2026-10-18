import Foundation

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
        let raw = url.path
        guard raw.hasPrefix("/") else { return .refused("relative") }
        guard !raw.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return .refused("dot-components") }
        guard !raw.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .refused("control-characters")
        }

        // Le parent est résolu (un lien symbolique au milieu du chemin pourrait
        // mener ailleurs) ; le dernier élément ne l'est pas : supprimer un lien
        // supprime le lien, pas sa cible.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = Self.normalize((parent as NSString).appendingPathComponent(url.lastPathComponent))
        let literal = Self.normalize(raw)


        for candidate in Set([resolved, literal]) {
            if exact.contains(candidate) { return .refused("protected-root") }
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
        let path = Self.normalize(raw)
        return cloudRoots.contains { root in
            path.hasPrefix(root) && !path.dropFirst(root.count).split(separator: "/").isEmpty
        }
    }

    public func allows(_ url: URL) -> Bool { check(url) == .allowed }

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
