import Darwin
import Foundation
import OustCore
import SQLite3

/// Les méthodes confiées à un outil (SPEC §6.1).
enum ToolActions {

    static func deleteSimulator(udid: String) async -> String? {
        let result = await Command.run("/usr/bin/xcrun", ["simctl", "delete", udid], timeout: 300)
        return result.succeeded ? nil : (result.errorOutput.nilIfEmpty ?? "simctl delete")
    }

    static func deleteRuntime(identifier: String) async -> String? {
        let result = await Command.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier], timeout: 600)
        return result.succeeded ? nil : (result.errorOutput.nilIfEmpty ?? "simctl runtime delete")
    }

    // MARK: Versions d'outils, Homebrew, conteneurs

    /// `pyenv uninstall -f <version>` ou `rustup toolchain uninstall <toolchain>`.
    ///
    /// Rien n'est construit à partir d'une chaîne libre : l'exécutable doit
    /// porter le nom de l'outil, la version ne peut ni commencer par un tiret
    /// (une option) ni contenir de barre (un chemin), et le dossier de la version
    /// doit avoir disparu après coup.
    static func uninstallVersion(tool: VersionTool, executable: String, root: String, version: String,
                                 folder: URL?) async -> String? {
        guard (executable as NSString).lastPathComponent == tool.executableName,
              FileManager.default.isExecutableFile(atPath: executable) else { return "\(tool.rawValue): executable" }
        guard isPlainName(version) else { return "\(tool.rawValue): version" }
        let arguments: [String] = switch tool {
        case .pyenv: ["uninstall", "-f", version]
        case .rustup: ["toolchain", "uninstall", version]
        }
        let result = await Command.run(executable, arguments, timeout: 600, environment: [tool.rootVariable: root])
        guard result.succeeded else {
            return result.errorOutput.nilIfEmpty ?? "\(tool.rawValue) \(arguments.joined(separator: " "))"
        }
        if let folder, FileManager.default.fileExists(atPath: folder.path) { return "\(tool.rawValue): \(version)" }
        return nil
    }

    /// `brew cleanup`, sans mise à jour ni statistiques (RULES.md, règle 11).
    static func brewCleanup(executable: String) async -> String? {
        guard (executable as NSString).lastPathComponent == "brew",
              FileManager.default.isExecutableFile(atPath: executable) else { return "brew: executable" }
        // `HOMEBREW_NO_AUTOREMOVE` : sans lui, `brew cleanup` désinstalle aussi les
        // formules arrivées en dépendance et devenues orphelines, que l'essai à
        // blanc annonce sans chemin ni taille. On ne retire que ce qu'on a montré.
        let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                           "HOMEBREW_NO_GITHUB_API": "1", "HOMEBREW_NO_AUTOREMOVE": "1"]
        let result = await Command.run(executable, ["cleanup"], timeout: 900, environment: environment)
        return result.succeeded ? nil : (result.errorOutput.nilIfEmpty ?? "brew cleanup")
    }

    /// `docker builder prune -f`, `docker image rm …` ou `docker container rm …`,
    /// et ce que Docker dit avoir rendu quand il le dit.
    ///
    /// Le moteur est revérifié juste avant : local (`unix://`), jamais un démon
    /// distant que le contexte courant désignerait depuis l'analyse.
    static func containerPrune(executable: String, scope: PruneScope, ids: [String]) async -> Result<Int64?, PruneError> {
        guard (executable as NSString).lastPathComponent == "docker",
              FileManager.default.isExecutableFile(atPath: executable) else { return .failure(PruneError("docker: executable")) }
        let endpoint = await Command.run(executable, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout: 15)
        guard endpoint.succeeded, endpoint.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") else {
            return .failure(PruneError("docker: remote context"))
        }
        guard ids.allSatisfy(PruneScope.isPlainReference), scope == .buildCache || !ids.isEmpty else {
            return .failure(PruneError("docker: identifiers"))
        }
        let arguments = scope.arguments(ids: ids)
        let result = await Command.run(executable, arguments, timeout: 1_800)
        guard result.succeeded else {
            return .failure(PruneError(result.errorOutput.nilIfEmpty ?? "docker \(arguments.prefix(2).joined(separator: " "))"))
        }
        return .success(reclaimedSpace(in: result.output))
    }

    struct PruneError: Error, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// « Total reclaimed space: 1.2GB » → 1 200 000 000 (base 1000, comme Docker).
    static func reclaimedSpace(in output: String) -> Int64? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("reclaimed space") }),
              let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, scale) in units where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)) else { return nil }
            return Int64(number * scale)
        }
        return nil
    }

    /// Un nom de version ou de toolchain : lettres, chiffres, `.`, `_`, `+`, `-`,
    /// commençant par une lettre ou un chiffre (ni option, ni `.` ou `..`).
    static func isPlainName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber, name.count <= 128 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    /// Vide l'historique de Firefox sans toucher aux favoris, qui vivent dans le
    /// même fichier `places.sqlite`.
    static func clearFirefoxHistory(database: String) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            return "sqlite3_open"
        }
        defer { sqlite3_close(db) }
        let statements = [
            "BEGIN",
            "DELETE FROM moz_historyvisits",
            "DELETE FROM moz_inputhistory",
            // Une adresse sans favori ni annotation n'est que de l'historique.
            "DELETE FROM moz_places WHERE id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL)",
            "UPDATE moz_places SET visit_count = 0, last_visit_date = NULL",
            "COMMIT",
            "VACUUM",
        ]
        for statement in statements {
            if sqlite3_exec(db, statement, nil, nil, nil) != SQLITE_OK {
                let message = String(cString: sqlite3_errmsg(db))
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return message
            }
        }
        return nil
    }

    /// Remplace une copie par un clone APFS de l'original : l'espace est rendu,
    /// le fichier reste, ses métadonnées aussi.
    ///
    /// Procédure de dedup / fclones : vérifier le contenu, cloner dans un fichier
    /// temporaire à côté, y recopier les métadonnées de la cible, revérifier que
    /// la cible n'a pas bougé, puis remplacer d'un seul `rename`.
    static func replaceWithClone(_ target: URL, original: URL) -> String? {
        var before = stat()
        guard lstat(target.path, &before) == 0 else { return "lstat" }
        guard before.st_nlink <= 1 else { return "hard-linked" }
        guard before.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else { return "immutable" }
        guard FileManager.default.contentsEqual(atPath: target.path, andPath: original.path) else { return "content-differs" }

        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".~oust.\(UUID().uuidString).\(target.lastPathComponent)")
        guard clonefile(original.path, temporary.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            return String(cString: strerror(errno))
        }
        let copyState = copyfile_state_alloc()
        defer { copyfile_state_free(copyState) }
        _ = copyfile(target.path, temporary.path, copyState, copyfile_flags_t(COPYFILE_METADATA))

        var after = stat()
        guard lstat(target.path, &after) == 0, after.st_ino == before.st_ino,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_size == before.st_size else {
            unlink(temporary.path)
            return "changed"
        }
        guard rename(temporary.path, target.path) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary.path)
            return message
        }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
