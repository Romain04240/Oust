import Darwin
import Foundation
import OustCore
import OustSafety
import OustScan

/// Diagnostic en lecture seule de préférences tierces dans la bibliothèque personnelle.
struct PreferenceDiagnosticsFinder {
    let context: RuleContext
    static let maximumBytes: Int64 = 1_048_576
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    func find() -> [Candidate] {
        guard context.volume == nil else { return [] }
        Scanner.configureProcessIOPolicy()
        let home = context.home.resolvingSymlinksInPath()
        let homeFD = open(home.path, Self.directoryFlags)
        guard homeFD >= 0 else { return [] }
        defer { close(homeFD) }
        let libraryFD = openat(homeFD, "Library", Self.directoryFlags)
        guard libraryFD >= 0 else { return [] }
        defer { close(libraryFD) }
        let directoryFD = openat(libraryFD, "Preferences", Self.directoryFlags)
        guard directoryFD >= 0 else { return [] }
        guard let stream = fdopendir(directoryFD) else { close(directoryFD); return [] }
        defer { closedir(stream) }
        guard let directoryFacts = FileFacts.openFile(directoryFD),
              FileFacts.openFile(homeFD)?.device == directoryFacts.device, !directoryFacts.isDataless else { return [] }

        let directory = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        var candidates: [Candidate] = []
        while !Task.isCancelled, let entry = readdir(stream) {
            guard let name = withUnsafeBytes(of: entry.pointee.d_name, { raw in
                String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
            }),
                  name.hasSuffix(".plist"), let app = owner(of: String(name.dropLast(".plist".count))),
                  let facts = invalidFile(name, in: directoryFD, device: directoryFacts.device) else { continue }
            let url = directory.appendingPathComponent(name)
            candidates.append(Candidate(item: CleanupItem(
                id: "\(CleanupItem.invalidPreferenceRuleID)|\(PathNormalizer.normalize(url.path))",
                title: app, detail: name, paths: [url], category: .preferenceDiagnostics, owner: app,
                ruleID: CleanupItem.invalidPreferenceRuleID, safety: .protected, method: .manual,
                lastActivity: facts.modificationDate, rebuild: .nothing,
                fingerprint: Fingerprint(modificationDate: facts.modificationDate, fileID: facts.inode)
            ), needsMeasure: false, location: AnalyzedItemLocation(directory: directoryFacts, entry: facts)))
        }
        // Le dossier énuméré doit toujours être celui que les fiches désignent.
        guard let resolved = PathGuard.withResolvedParent(directory.appendingPathComponent("check.plist")),
              PathNormalizer.normalize(resolved.deletingLastPathComponent().path) == PathNormalizer.normalize(directory.path),
              let current = FileFacts.of(directory.path), current.device == directoryFacts.device,
              current.inode == directoryFacts.inode else { return [] }
        return candidates
    }

    private func owner(of identifier: String) -> String? {
        let lower = identifier.lowercased()
        guard AppCachesFinder.isBundleIdentifier(identifier), !lower.hasPrefix("com.apple."),
              !AppCachesFinder.passwordManagerMarkers.contains(where: lower.contains),
              !context.runningApps.contains(where: { $0.lowercased() == lower }),
              let url = context.applicationURL(identifier), url.isFileURL else { return nil }
        let app = url.resolvingSymlinksInPath()
        guard app.pathExtension.lowercased() == "app",
              !app.pathComponents.contains(where: { [".trash", ".trashes"].contains($0.lowercased()) }),
              Bundle(url: app)?.bundleIdentifier == identifier else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func invalidFile(_ name: String, in directory: Int32, device: Int32) -> FileFacts? {
        guard let expected = FileFacts.at(name, in: directory), expected.isRegularFile, expected.device == device,
              expected.linkCount == 1, !expected.isDataless, (0...Self.maximumBytes).contains(expected.size) else { return nil }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let before = FileFacts.openFile(fd), before.isRegularFile, before.device == device,
              !before.isDataless, before.isUnchanged(comparedTo: expected) else { return nil }

        let data: Data
        do {
            data = try handle.read(upToCount: Int(before.size) + 1) ?? Data()
        } catch {
            return nil
        }
        guard data.count == Int(before.size),
              (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil,
              let after = FileFacts.openFile(fd), after.isUnchanged(comparedTo: before),
              let current = FileFacts.at(name, in: directory), current.device == device,
              current.isUnchanged(comparedTo: after) else { return nil }
        return current
    }
}
