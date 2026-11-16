import Darwin
import Foundation

package enum DeviceBackupPath {
    package static let components = ["Library", "Application Support", "MobileSync", "Backup"]

    package static func root(in home: URL) -> URL {
        home.appendingPathComponent(components.joined(separator: "/"), isDirectory: true)
    }

    package struct Snapshot: Sendable, Equatable {
        package let directory: PreferenceDirectory
        package let redirects: [String: PreferenceDirectory]
        package let uncertain: Bool

        package init(directory: PreferenceDirectory, redirects: [String: PreferenceDirectory], uncertain: Bool) {
            self.directory = directory
            self.redirects = redirects
            self.uncertain = uncertain
        }

        package var locations: [PreferenceDirectory] { [directory] + Array(redirects.values) }

        package static let unknown = Self(directory: PreferenceDirectory(nil), redirects: [:], uncertain: true)

        package static func capture(_ root: String?) -> Self {
            guard let root else {
                return Self(directory: PreferenceDirectory(nil), redirects: [:], uncertain: false)
            }
            let policy = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
            let scope = IOPOL_SCOPE_THREAD
            let previous = getiopolicy_np(policy, scope)
            guard previous >= 0, setiopolicy_np(policy, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
                return Self(directory: PreferenceDirectory(nil), redirects: [:], uncertain: true)
            }
            defer { _ = setiopolicy_np(policy, scope, previous) }
            let directory = PreferenceDirectory.capturingLocation(at: root)
            guard let physical = directory.resolvedPath else {
                var info = stat()
                if !directory.isUncertain, lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                    let target = absentDestination(of: root, relativeTo: (root as NSString).deletingLastPathComponent)
                    let missing = PreferenceDirectory(identity: nil, isUncertain: target == nil, resolvedPath: target)
                    return Self(directory: missing, redirects: [:], uncertain: missing.isUncertain)
                }
                return Self(directory: directory, redirects: [:], uncertain: directory.isUncertain)
            }
            var initial = stat()
            guard lstat(physical, &initial) == 0,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: physical) else {
                return Self(directory: directory, redirects: [:], uncertain: true)
            }
            var redirects: [String: PreferenceDirectory] = [:]
            for name in names {
                let path = (physical as NSString).appendingPathComponent(name)
                var entry = stat()
                guard lstat(path, &entry) == 0 else {
                    return Self(directory: directory, redirects: redirects, uncertain: true)
                }
                guard entry.st_mode & S_IFMT == S_IFLNK else { continue }
                let target = PreferenceDirectory.capturingLocation(at: path)
                if target.resolvedPath == nil, !target.isUncertain,
                   let absent = absentDestination(of: path, relativeTo: physical) {
                    redirects[name] = PreferenceDirectory(identity: nil, isUncertain: false, resolvedPath: absent)
                    continue
                }
                guard target.resolvedPath != nil, !target.isUncertain else {
                    return Self(directory: directory, redirects: redirects, uncertain: true)
                }
                redirects[name] = target
            }
            var final = stat()
            let stable = lstat(physical, &final) == 0 && initial.st_ino == final.st_ino && initial.st_dev == final.st_dev
                && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
                && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
                && directory == PreferenceDirectory.capturingLocation(at: root)
            return Self(directory: directory, redirects: redirects, uncertain: !stable)
        }

        package func contains(_ path: String, root: String?) -> Bool {
            guard let root else { return false }
            if uncertain { return true }
            let candidate = dataPath(path)
            return ([root] + locations.compactMap(\.resolvedPath)).contains {
                let backup = dataPath($0)
                return candidate == backup || candidate.hasPrefix(backup + "/")
            }
        }
    }

    /// Un montage absent ne rend pas incertains les autres chemins. Ne remonte
    /// que des composants dont l'absence est prouvée, sans écarter un autre lien.
    private static func absentDestination(of link: String, relativeTo parent: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { bytes in
            guard let start = bytes.baseAddress else { return -1 }
            return readlink(link, start, bytes.count)
        }
        guard count > 0, count < buffer.count, let destination = String(bytes: buffer.prefix(count), encoding: .utf8) else { return nil }
        var path = destination.hasPrefix("/") ? destination : parent + "/" + destination
        var missing: [String] = []
        while path != "/" {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard let canonical = realpath(path, nil) else { return nil }
                defer { free(canonical) }
                let resolved = String(cString: canonical)
                guard stat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
                return missing.reversed().reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
            }
            guard errno == ENOENT else { return nil }
            let current = path as NSString
            guard !current.lastPathComponent.isEmpty, current.lastPathComponent != ".." else { return nil }
            missing.append(current.lastPathComponent)
            let next = current.deletingLastPathComponent
            guard next != path, !next.isEmpty else { return nil }
            path = next
        }
        return missing.reversed().reduce("/") { ($0 as NSString).appendingPathComponent($1) }
    }

    private static func dataPath(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        let path = path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
        return URL(fileURLWithPath: path).standardizedFileURL.path
            .folding(options: .caseInsensitive, locale: nil)
    }
}
