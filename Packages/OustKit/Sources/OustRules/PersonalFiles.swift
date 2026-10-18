import Darwin
import Foundation
import OustCore
import OustSafety

/// Les gros postes classiques du contenu personnel : pièces jointes de Mail et de
/// Messages, mises à jour iOS téléchargées, vieilles captures d'écran.
///
/// Tout est « à examiner » et part à la corbeille du Mac, sauf les mises à jour
/// iOS que le Finder a téléchargées lui-même et retéléchargera au besoin.
struct PersonalFilesFinder {
    let context: RuleContext

    /// Une pièce jointe reçue ce mois-ci est sans doute encore utile.
    static let attachmentGraceDays = 30
    /// Une capture d'écran de plus d'un mois est rarement encore attendue.
    static let screenshotAgeDays = 30

    func find() async -> [Candidate] {
        mailAttachments() + messagesAttachments() + iOSUpdates() + screenshots()
    }

    // MARK: - Pièces jointes

    /// Mail range chaque pièce jointe téléchargée dans un dossier `Attachments`
    /// de la boîte ; on regroupe par année pour qu'on choisisse en connaissance
    /// de cause.
    func mailAttachments() -> [Candidate] {
        let mail = context.path("Library/Mail")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil) else {
            return inaccessible(mail, title: "Mail", owner: "Mail", rule: "attachments.mail")
        }
        guard let store = Self.latestMailStore(among: entries) else { return [] }
        var folders: [URL] = []
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: store, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            // Les messages eux-mêmes et l'index ne nous regardent pas : on ne descend pas.
            if name == "Messages" || name == "MailData" { enumerator?.skipDescendants(); continue }
            guard name == "Attachments", fileManager.isDirectory(url) else { continue }
            enumerator?.skipDescendants()
            folders += fileManager.children(of: url).filter { fileManager.isDirectory($0) && !$0.isSymbolicLink }
        }
        return protectIfOpen(byYear(folders, prefix: "Mail", owner: "Mail", rule: "attachments.mail"))
    }

    /// `~/Library/Messages/Attachments/xx/yy/<identifiant>/fichier` : un dossier
    /// par pièce jointe, regroupés par année.
    func messagesAttachments() -> [Candidate] {
        let root = context.path("Library/Messages/Attachments")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil else {
            return inaccessible(root, title: "Messages", owner: "Messages", rule: "attachments.messages")
        }
        var folders: [URL] = []
        for first in fileManager.children(of: root) where fileManager.isDirectory(first) {
            for second in fileManager.children(of: first) where fileManager.isDirectory(second) {
                folders += fileManager.children(of: second).filter { fileManager.isDirectory($0) && !$0.isSymbolicLink }
            }
        }
        return protectIfOpen(byYear(folders, prefix: "Messages", owner: "Messages", rule: "attachments.messages"))
    }

    /// Mail et Messages tiennent leurs pièces jointes : ouverts, on n'y touche pas.
    func protectIfOpen(_ candidates: [Candidate]) -> [Candidate] {
        candidates.map { candidate in
            var candidate = candidate
            if let owner = AppOwnership.runningOwner(ruleID: candidate.item.ruleID, paths: candidate.item.paths,
                                                     running: context.runningApps) {
                candidate.item.protect(.appRunning(name: owner))
            }
            return candidate
        }
    }

    /// Le dossier `V<n>` le plus récent de Mail.
    static func latestMailStore(among entries: [URL]) -> URL? {
        entries
            .filter { $0.lastPathComponent.hasPrefix("V") && Int($0.lastPathComponent.dropFirst()) != nil }
            .max { Int($0.lastPathComponent.dropFirst())! < Int($1.lastPathComponent.dropFirst())! }
    }

    /// Un dossier qu'on ne peut pas lire : montré, avec la raison, plutôt que passé
    /// sous silence (SPEC §3.1). Rien si l'application n'a jamais servi.
    func inaccessible(_ url: URL, title: String, owner: String, rule: String) -> [Candidate] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return [] }
        var item = CleanupItem(id: "\(rule)|\(url.path)", title: title, detail: url.abbreviated(home: context.home),
                               paths: [url], category: .attachments, owner: owner, ruleID: rule, safety: .review,
                               method: .trash, rebuild: .irreversible)
        item.protect(.needsFullDiskAccess)
        return [Candidate(item: item, needsMeasure: false)]
    }

    /// Un élément par année, sans ce qui est arrivé ces derniers jours.
    func byYear(_ folders: [URL], prefix: String, owner: String, rule: String) -> [Candidate] {
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = context.now.addingTimeInterval(-Double(Self.attachmentGraceDays) * 86_400)
        var years: [Int: [(URL, Date)]] = [:]
        for folder in folders {
            guard let date = folder.modificationDate, date < cutoff else { continue }
            years[calendar.component(.year, from: date), default: []].append((folder, date))
        }
        return years.keys.sorted().map { year in
            let entries = years[year]!.sorted { $0.1 < $1.1 }
            return Candidate(item: CleanupItem(
                id: "\(rule)|\(year)", title: "\(prefix) · \(year)", detail: String(entries.count),
                paths: entries.map(\.0), category: .attachments, owner: owner, ruleID: rule, safety: .review,
                method: .trash, lastActivity: entries.last?.1, rebuild: .irreversible
            ))
        }
    }

    // MARK: - Mises à jour iOS

    /// Les `.ipsw` : celles que le Finder a téléchargées pour mettre à jour un
    /// appareil (il les retélécharge au besoin), et celles qu'on a rangées
    /// soi-même dans les Téléchargements.
    func iOSUpdates() -> [Candidate] {
        let fileManager = FileManager.default
        var candidates: [Candidate] = []
        for device in ["iPhone", "iPad", "iPod", "AppleTV"] {
            let folder = context.path("Library/iTunes/\(device) Software Updates")
            for file in fileManager.children(of: folder) where file.pathExtension.lowercased() == "ipsw" && !file.isSymbolicLink {
                candidates.append(Candidate(item: CleanupItem(
                    title: file.lastPathComponent, detail: file.abbreviated(home: context.home), paths: [file],
                    category: .systemDownloads, owner: device, ruleID: "ios.update", safety: .safe,
                    method: .removeNow, lastActivity: file.modificationDate, rebuild: .download
                )))
            }
        }
        let downloads = context.path("Downloads")
        for file in fileManager.children(of: downloads) where file.pathExtension.lowercased() == "ipsw" && !file.isSymbolicLink {
            candidates.append(Candidate(item: CleanupItem(
                title: file.lastPathComponent, detail: file.abbreviated(home: context.home), paths: [file],
                category: .systemDownloads, owner: "Downloads", ruleID: "ios.update", safety: .review,
                method: .trash, lastActivity: file.modificationDate, rebuild: .download
            )))
        }
        return candidates
    }

    // MARK: - Captures d'écran

    /// Préfixes des noms que macOS donne aux captures, dans les langues courantes.
    /// L'attribut `kMDItemIsScreenCapture` reste la preuve principale.
    static let screenshotPrefixes = [
        "Screenshot", "Screen Shot", "Screen Recording", "Capture d’écran", "Capture d'écran",
        "Enregistrement de l’écran", "Enregistrement de l'écran", "Bildschirmfoto", "Bildschirmaufnahme",
        "Captura de pantalla", "Grabación de pantalla", "Schermata", "Registrazione schermo", "Skärmavbild",
        "Schermafbeelding", "Zrzut ekranu", "スクリーンショット", "截屏", "螢幕截圖",
    ]
    static let screenshotExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf", "mov", "mp4"]

    /// Les captures de plus d'un mois, au Bureau et là où macOS les range s'il a
    /// été réglé autrement (`com.apple.screencapture`, clé `location`).
    func screenshots() -> [Candidate] {
        let fileManager = FileManager.default
        var folders = [context.path("Desktop")]
        if let custom = screenshotLocation(), !folders.contains(where: { $0.standardizedFileURL == custom.standardizedFileURL }) {
            folders.append(custom)
        }
        let cutoff = context.now.addingTimeInterval(-Double(Self.screenshotAgeDays) * 86_400)
        let calendar = Calendar(identifier: .gregorian)
        var months: [DateComponents: [(URL, Date)]] = [:]
        for folder in folders {
            for file in fileManager.children(of: folder) where !file.isSymbolicLink && Self.isScreenshot(file) {
                guard let date = file.modificationDate, date < cutoff else { continue }
                months[calendar.dateComponents([.year, .month], from: date), default: []].append((file, date))
            }
        }
        return months.keys.sorted { ($0.year!, $0.month!) < ($1.year!, $1.month!) }.map { month in
            let entries = months[month]!.sorted { $0.1 < $1.1 }
            let first = calendar.date(from: month) ?? entries[0].1
            return Candidate(item: CleanupItem(
                id: "screenshots|\(month.year!)-\(month.month!)",
                title: first.formatted(.dateTime.month(.wide).year()), detail: String(entries.count),
                paths: entries.map(\.0), category: .screenshots, owner: "Desktop", ruleID: "screenshots.desktop",
                safety: .review, method: .trash, lastActivity: entries.last?.1, rebuild: .irreversible
            ))
        }
    }

    static func isScreenshot(_ file: URL) -> Bool {
        guard screenshotExtensions.contains(file.pathExtension.lowercased()) else { return false }
        if getxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0 { return true }
        let name = file.lastPathComponent
        return screenshotPrefixes.contains { name.hasPrefix($0) }
    }

    /// Le dossier choisi dans Capture d'écran › Options, s'il y en a un.
    func screenshotLocation() -> URL? {
        let plist = context.path("Library/Preferences/com.apple.screencapture.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let location = object["location"] as? String, !location.isEmpty else { return nil }
        let expanded = location.hasPrefix("~") ? context.home.path + location.dropFirst() : location
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        return FileManager.default.isDirectory(url) ? url : nil
    }
}
