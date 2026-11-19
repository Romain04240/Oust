import Darwin
import Foundation
import OustCore
import OustScan

public enum LoginDiagnostics {
    /// Une entrée du registre n'est jamais un objet de nettoyage. La vue reçoit
    /// uniquement le libellé, sans chemin exploitable par une action générique.
    public struct Finding: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
    }

    public enum Result: Equatable, Sendable {
        case unavailable
        case checked(volumeIndeterminate: [Finding])
    }

    public struct SessionSnapshot: Equatable, Sendable {
        public let diagnostic: Result
        public let inventory: LoginSessionInventory

        public init(diagnostic: Result, inventory: LoginSessionInventory) {
            self.diagnostic = diagnostic
            self.inventory = inventory
        }
    }

    public static func scan() async -> Result {
        await readSession().diagnostic
    }

    public static func readSession() async -> SessionSnapshot {
        await readSession(read: {
            await Command.run("/usr/bin/sfltool", ["dumpbtm"], timeout: 12)
        })
    }

    static func scan(read: @Sendable () async -> CommandResult) async -> Result {
        await readSession(read: read).diagnostic
    }

    static func readSession(read: @Sendable () async -> CommandResult,
                            readDiagnostic: (@Sendable (String, uid_t) async -> Result?)? = nil) async -> SessionSnapshot {
        let unavailable = SessionSnapshot(diagnostic: .unavailable, inventory: .unavailable)
        guard !Task.isCancelled else { return unavailable }
        // Seul le sous-processus de cette lecture appartient au diagnostic.
        let command = await CommandCancellationContext.$cancelsReadOnlyCommands.withValue(true) {
            await read()
        }
        guard command.succeeded, command.stderr.isEmpty, !Task.isCancelled else { return unavailable }
        let decoded = String(data: command.stdout, encoding: .utf8)
        let output = decoded ?? command.output
        let uid = getuid()
        // Le registre déclaré ne dépend d'aucun accès aux cibles. Une lecture
        // de métadonnées lente ne doit pas faire disparaître cet inventaire.
        let inventory: LoginSessionInventory
        if decoded != nil {
            inventory = await Task.detached(priority: .utility) {
                LoginSessionInventory.parse(output, uid: uid)
            }.value
        } else { inventory = .unavailable }
        guard !Task.isCancelled else { return unavailable }
        let diagnostic: Result?
        if let readDiagnostic { diagnostic = await readDiagnostic(output, uid) }
        else { diagnostic = await checkStorageIO { inspect(output, uid: uid) } }
        guard !Task.isCancelled else { return unavailable }
        return SessionSnapshot(diagnostic: diagnostic ?? .unavailable, inventory: inventory)
    }

    static func inspect(_ output: String, uid: uid_t) -> Result {
        guard let entries = userEntries(in: output, uid: uid) else { return .unavailable }
        let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(policy, scope)
        guard previous >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            return .unavailable
        }
        defer { _ = setiopolicy_np(policy, scope, previous) }
        let mounts = MountTable.mountPoints().subtracting(["/System/Volumes/Data"])
        guard !mounts.isEmpty else { return .unavailable }
        var boot = stat()
        guard stat("/", &boot) == 0 else { return .unavailable }
        let excluded = mounts.union(["/Volumes", "/Network", "/System/Volumes/Data/Volumes",
                                     "/System/Volumes/Data/Network"]).map { $0.lowercased() }
        var seen = Set<UUID>()
        let findings = entries.compactMap { entry -> Finding? in
            let foldedPath = entry.path.lowercased()
            guard seen.insert(entry.id).inserted,
                  !excluded.contains(where: { foldedPath == $0 || foldedPath.hasPrefix($0 + "/") }),
                  absentAtRecordedPath(entry.path, on: boot.st_dev) else { return nil }
            // Le registre donne un chemin sans identité du volume d’origine.
            // Après une éjection, ce même chemin peut désigner le disque interne.
            return Finding(id: entry.id, name: entry.name)
        }
        return .checked(volumeIndeterminate: findings.sorted {
            if $0.name == $1.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    private struct Entry {
        let id: UUID
        let name: String
        let path: String

        init?(_ fields: [String: String]) {
            guard fields["Type"] == "user item (0x1)",
                  fields["Disposition"]?.hasPrefix("[enabled, allowed, ") == true,
                  let uuid = fields["UUID"].flatMap(UUID.init(uuidString:)),
                  let name = fields["Name"], !name.isEmpty, name != "(null)",
                  let path = fields["URL"], let identifier = fields["Identifier"],
                  let url = URLComponents(string: identifier),
                  url.scheme == "file", (url.host ?? "").isEmpty,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.path == path || url.path == path + "/",
                  path.hasPrefix("/"), path.hasSuffix(".app"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            self.id = uuid
            self.name = name
            self.path = path
        }
    }

    private static func userEntries(in output: String, uid: uid_t) -> [Entry]? {
        var matchedUser = false
        var inUserSection = false
        var fields: [String: String]?
        var entries: [Entry] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID ") || (inUserSection && line.hasPrefix("#")) {
                if let fields, let entry = Entry(fields) { entries.append(entry) }
                fields = nil
            }
            if line.hasPrefix("Records for UID ") {
                inUserSection = line.hasPrefix("Records for UID \(uid) :")
                matchedUser = matchedUser || inUserSection
            } else if inUserSection, line.hasPrefix("#"), line.hasSuffix(":"),
                      Int(line.dropFirst().dropLast()) != nil {
                fields = [:]
            } else if fields != nil, let separator = line.firstIndex(of: ":") {
                let key = String(line[..<separator])
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                fields?[key] = value
            }
        }
        if let fields, let entry = Entry(fields) { entries.append(entry) }
        return matchedUser ? entries : nil
    }

    private static func absentAtRecordedPath(_ path: String, on device: dev_t) -> Bool {
        let components = path.dropFirst().components(separatedBy: "/")
        guard let leaf = components.last,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !components.contains(where: { ["mobile documents", "cloudstorage"].contains($0.lowercased()) }) else {
            return false
        }

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directory = open("/", flags)
        guard directory >= 0 else { return false }
        defer { close(directory) }
        for component in components.dropLast() {
            var info = stat()
            guard fstatat(directory, component, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_dev == device, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_flags & (UInt32(SF_DATALESS) | 0x0080_0000) == 0 else { return false }
            let child = openat(directory, component, flags)
            guard child >= 0 else { return false }
            close(directory)
            directory = child
            var opened = stat()
            guard fstat(directory, &opened) == 0, opened.st_dev == info.st_dev,
                  opened.st_ino == info.st_ino else { return false }
        }
        var target = stat()
        // ENOTDIR, EACCES et un lien pendant restent des cas indéterminés.
        return fstatat(directory, leaf, &target, AT_SYMLINK_NOFOLLOW) == -1 && errno == ENOENT
    }
}
