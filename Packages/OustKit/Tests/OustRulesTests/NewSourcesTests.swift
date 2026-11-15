import Darwin
import Foundation
import Testing
@testable import OustRules
import OustCore
import OustSafety
import OustScan

@Suite("Caches d'applications, une par une")
struct AppCachesTests {

    @Test("Un cache d'application est sûr ; Apple, les mots de passe et les navigateurs sont écartés")
    func exclusions() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.spotify.client/Data/a", bytes: 1_200_000)
        try home.file("Library/Caches/com.apple.Safari/b", bytes: 1_200_000)
        try home.file("Library/Caches/com.1password.1password/c", bytes: 1_200_000)
        try home.file("Library/Caches/com.bitwarden.desktop/c", bytes: 1_200_000)
        try home.file("Library/Caches/com.google.Chrome/d", bytes: 1_200_000)
        try home.file("Library/Caches/Homebrew/e", bytes: 1_200_000)
        try home.file("Library/Caches/com.petit.cache/f", bytes: 20_000)

        let items = await RuleEngine.collect(home.context(), finders: [.appCaches])

        #expect(items.map(\.detail) == ["com.spotify.client"])
        let spotify = try #require(items.first)
        #expect(spotify.safety == .safe && spotify.method == .removeNow && spotify.ruleID == "cache.app")
        #expect(spotify.category.section == .system)
    }

    @Test("Application ouverte : son cache est protégé, celui de son assistant aussi")
    func runningApp() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.spotify.client/a", bytes: 1_200_000)
        try home.file("Library/Caches/com.spotify.client.helper/a", bytes: 1_200_000)

        let items = await RuleEngine.collect(home.context(runningApps: ["com.spotify.client"]), finders: [.appCaches])

        #expect(items.count == 2)
        // Sans nom d'application connu, on nomme celle du cache.
        #expect(items.first { $0.detail == "com.spotify.client" }?.protections == [.appRunning(name: "com.spotify.client")])
        #expect(items.first { $0.detail == "com.spotify.client.helper" }?.protections
            == [.appRunning(name: "com.spotify.client.helper")])
    }

    @Test("Ce qui ressemble à un identifiant de bundle")
    func bundleIdentifiers() {
        #expect(AppCachesFinder.isBundleIdentifier("us.zoom.xos"))
        #expect(!AppCachesFinder.isBundleIdentifier("Homebrew"))
        #expect(!AppCachesFinder.isBundleIdentifier(".hidden"))
        #expect(AppCachesFinder.isExcluded("com.agilebits.onepassword7"))
        #expect(AppCachesFinder.isExcluded("COM.APPLE.Music"))
        // Déjà comptés par les agents.
        #expect(AppCachesFinder.isExcluded("com.openai.codex"))
    }
}

@Suite("Pièces jointes, mises à jour iOS, captures d'écran")
struct PersonalFilesTests {

    @Test("Pièces jointes de Mail : regroupées par année, jamais les messages, rien de récent")
    func mailAttachments() async throws {
        let home = try FakeHome()
        let old = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2023, month: 5, day: 2)))
        let base = "Library/Mail/V10/ACCOUNT/INBOX.mbox/UUID/Data/1/2"
        try home.file("\(base)/Attachments/1234/2/facture.pdf", bytes: 300_000)
        try home.file("\(base)/Attachments/5678/2/photo.jpg", bytes: 300_000)
        try home.file("\(base)/Messages/1234.emlx", bytes: 4_000)
        try home.setModified("\(base)/Attachments/1234", old)
        // Une pièce jointe d'hier : sans doute encore utile.

        let items = await RuleEngine.collect(home.context(), finders: [.personalFiles])
        let mail = try #require(items.first { $0.ruleID == "attachments.mail" })

        #expect(items.filter { $0.ruleID == "attachments.mail" }.count == 1)
        #expect(mail.title == "Mail · 2023")
        #expect(mail.paths.map(\.lastPathComponent) == ["1234"])
        #expect(mail.safety == .review && mail.method == .trash)
        #expect(!PreselectionPolicy().preselects(mail))
    }

    @Test("Mail ouvert : ses pièces jointes sont protégées")
    func mailOpen() async throws {
        let home = try FakeHome()
        let old = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2023, month: 5, day: 2)))
        let base = "Library/Mail/V10/ACCOUNT/INBOX.mbox/UUID/Data/1/2"
        try home.file("\(base)/Attachments/1234/2/facture.pdf", bytes: 300_000)
        try home.setModified("\(base)/Attachments/1234", old)

        let items = await RuleEngine.collect(home.context(runningApps: ["com.apple.mail"]), finders: [.personalFiles])

        #expect(items.first { $0.ruleID == "attachments.mail" }?.protections == [.appRunning(name: "Mail")])
    }

    @Test("Pièces jointes de Messages, par année")
    func messagesAttachments() async throws {
        let home = try FakeHome()
        let old = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2021, month: 1, day: 9)))
        try home.file("Library/Messages/Attachments/ab/01/GUID-1/IMG_0001.HEIC", bytes: 200_000)
        try home.setModified("Library/Messages/Attachments/ab/01/GUID-1", old)
        try home.file("Library/Messages/chat.db", bytes: 10_000)

        let items = await RuleEngine.collect(home.context(), finders: [.personalFiles])
        let messages = try #require(items.first { $0.ruleID == "attachments.messages" })

        #expect(messages.title == "Messages · 2021")
        #expect(messages.paths.map(\.lastPathComponent) == ["GUID-1"])
    }

    @Test("Mail illisible : montré, protégé, avec la raison")
    func mailNeedsFullDiskAccess() async throws {
        let home = try FakeHome()
        let mail = home.root.appendingPathComponent("Library/Mail")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        chmod(mail.path, 0o000)
        defer { chmod(mail.path, 0o755) }

        let items = await RuleEngine.collect(home.context(), finders: [.personalFiles])

        #expect(items.first { $0.ruleID == "attachments.mail" }?.protections == [.needsFullDiskAccess])
    }

    @Test("Les .ipsw du Finder sont sûrs, ceux des Téléchargements à examiner")
    func iOSUpdates() async throws {
        let home = try FakeHome()
        try home.file("Library/iTunes/iPhone Software Updates/iPhone17,1_26.0_Restore.ipsw", bytes: 200_000)
        try home.file("Downloads/iPad_beta.ipsw", bytes: 200_000)

        let items = await RuleEngine.collect(home.context(), finders: [.personalFiles])

        let finder = try #require(items.first { $0.owner == "iPhone" })
        #expect(finder.safety == .safe && finder.method == .removeNow)
        let downloaded = try #require(items.first { $0.owner == "Downloads" })
        #expect(downloaded.safety == .review && downloaded.method == .trash)
    }

    @Test("Captures d'écran de plus de 30 jours sur le Bureau, par mois")
    func screenshots() async throws {
        let home = try FakeHome()
        let now = Date()
        let old = now.addingTimeInterval(-60 * 86_400)
        try home.file("Desktop/Capture d’écran 2026-08-01 à 10.00.00.png", bytes: 100_000, modified: old)
        try home.file("Desktop/Screenshot 2026-08-02 at 10.00.00.png", bytes: 100_000, modified: old)
        try home.file("Desktop/sans-nom.png", bytes: 100_000, modified: old)
        try home.file("Desktop/Capture d’écran récente.png", bytes: 100_000)
        // Reconnue à son attribut, quel que soit son nom.
        try home.file("Desktop/renommée.png", bytes: 100_000, modified: old)
        let tagged = home.root.appendingPathComponent("Desktop/renommée.png").path
        var yes: UInt8 = 1
        setxattr(tagged, "com.apple.metadata:kMDItemIsScreenCapture", &yes, 1, 0, 0)

        let items = await RuleEngine.collect(home.context(now: now), finders: [.personalFiles])
        let month = try #require(items.first { $0.ruleID == "screenshots.desktop" })

        #expect(Set(month.paths.map(\.lastPathComponent))
            == ["Capture d’écran 2026-08-01 à 10.00.00.png", "Screenshot 2026-08-02 at 10.00.00.png", "renommée.png"])
        #expect(month.safety == .review && month.method == .trash)
    }
}

@Suite("Le nuage : libérer sans supprimer")
struct CloudCopiesTests {

    @Test("Inventaire, estimation et éviction reconnaissent les mêmes paquets cloud",
          arguments: [false, true], ["app", "PAGES", "rtfd", "photoslibrary"])
    func safariCloudIndivisibleGain(fromTree: Bool, ext: String) async throws {
        let home = try FakeHome()
        let relative = "Library/CloudStorage/Dropbox/"
        let protectedName = "Indivisible.\(ext)"
        try home.file(relative + "Projet/\(protectedName)/Ressources/Archive.download/partiel", bytes: 2_000_000)
        try home.file(relative + "Projet/\(protectedName)/Ressources/interne.txt", bytes: 3_000_000)
        try home.file(relative + "Projet/Voisin.txt", bytes: 1_500_000)
        let ordinaryName = "Ordinaire.\(ext)"
        try home.file(relative + "\(ordinaryName)/Fichier.txt", bytes: 2_000_000)
        let root = home.root.appendingPathComponent(relative, isDirectory: true)
        let finder = CloudCopiesFinder(context: home.context())
        let provider = CloudCopiesFinder.Provider(root: root, name: "Dropbox", rule: "cloud.file_provider")
        let walk: CloudCopiesFinder.Walk
        if fromTree {
            let tree = try #require(await Scanner.scan([root]).root)
            walk = CloudCopiesFinder.largeFiles(in: tree, eligible: { _ in true })
        } else {
            walk = { url, visit in CloudCopiesFinder.largeFiles(under: url, eligible: { _ in true }, visit: visit) }
        }
        let items = finder.candidates(for: provider, walk: walk).map(\.item)
        #expect(items.count == 2)
        let project = try #require(items.first { $0.title == "Projet" })
        #expect(project.sizes.freeable == FileFacts.of(root.appendingPathComponent("Projet/Voisin.txt").path)?.allocated)
        let loose = try #require(items.first { $0.title == "Dropbox" })
        #expect(loose.paths.map(\.lastPathComponent) == [ordinaryName])
        #expect(loose.sizes.freeable == FileFacts.of(root.appendingPathComponent("\(ordinaryName)/Fichier.txt").path)?.allocated)

        let listed = try #require(CloudLister.list(root).files.first { URL(fileURLWithPath: $0.path).lastPathComponent == protectedName })
        #expect(listed.isPackage && listed.containsSafariDownload && listed.privateSize == 0)
        var targets: [String] = []
        CloudFile.walk(root, minimumBytes: 0, eligible: { _ in true }) { url, _, _ in
            targets.append(url.lastPathComponent)
            return true
        }
        #expect(targets.sorted() == [ordinaryName, "Voisin.txt"].sorted())
    }

    @Test("Le gain cloud ignore le paquet Safari, ses fichiers et un lien, avec un fichier voisin")
    func safariDownloadCloudGain() throws {
        let home = try FakeHome()
        let relative = "Library/CloudStorage/Dropbox/Projets/"
        try home.file(relative + "Archive.DOWNLOAD/Fichier.partiel")
        try home.file(relative + "Voisin.txt")
        let project = home.root.appendingPathComponent(relative)
        let safari = project.appendingPathComponent("Archive.DOWNLOAD")
        let neighbour = project.appendingPathComponent("Voisin.txt")
        let link = project.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: safari)
        let finder = CloudCopiesFinder(context: home.context())
        let provider = CloudCopiesFinder.Provider(root: project.deletingLastPathComponent(), name: "Dropbox",
                                                 rule: "cloud.file_provider")
        let candidates = finder.candidates(for: provider) { _, visit in
            for entry in [safari, safari.appendingPathComponent("Fichier.partiel"), link.appendingPathComponent("Fichier.partiel")] {
                _ = visit(entry, 3_000_000, nil)
            }
            _ = visit(neighbour, 2_000_000, nil)
        }
        let only = try #require(candidates.first?.item)
        #expect(candidates.count == 1 && only.title == "Projets" && only.sizes.freeable == 2_000_000)
    }

    @Test("Les copies évinçables sont regroupées par dossier, sous « Mon Drive » un cran plus bas")
    func grouping() throws {
        let home = try FakeHome()
        let root = home.root.appendingPathComponent("Library/CloudStorage/GoogleDrive-moi@exemple.fr")
        let provider = CloudCopiesFinder.Provider(root: root, name: "Google Drive", rule: "cloud.file_provider")
        let files: [(String, Int64)] = [
            ("Mon Drive/Photos/a.jpg", 2_000_000), ("Mon Drive/Photos/b.jpg", 3_000_000),
            ("Mon Drive/Factures/f.pdf", 1_500_000), ("lâche.txt", 1_200_000), ("Mon Drive/minuscule.txt", 10),
        ]
        let finder = CloudCopiesFinder(context: home.context())

        let candidates = finder.candidates(for: provider) { _, visit in
            for (relative, bytes) in files { _ = visit(root.appendingPathComponent(relative), bytes, nil) }
        }
        let items = candidates.filter { $0.item.sizes.allocated >= $0.minimumAllocated }.map(\.item)

        let photos = try #require(items.first { $0.title == "Photos" })
        #expect(photos.sizes.freeable == 5_000_000)
        #expect(photos.method == .evictLocalCopy && photos.safety == .review)
        #expect(photos.paths == [root.appendingPathComponent("Mon Drive/Photos", isDirectory: true)])
        #expect(items.contains { $0.title == "Google Drive" && $0.paths.map(\.lastPathComponent) == ["lâche.txt"] })
    }

    @Test("Un fichier posé dans « Mon Drive » ne fait pas évincer tout le dossier")
    func looseFilesInContainer() throws {
        let home = try FakeHome()
        let root = home.root.appendingPathComponent("Library/CloudStorage/GoogleDrive-moi@exemple.fr")
        let provider = CloudCopiesFinder.Provider(root: root, name: "Google Drive", rule: "cloud.file_provider")
        let finder = CloudCopiesFinder(context: home.context())

        let candidates = finder.candidates(for: provider) { _, visit in
            _ = visit(root.appendingPathComponent("Mon Drive/rapport.pdf"), 2_000_000, nil)
            _ = visit(root.appendingPathComponent("Mon Drive/Photos/a.jpg"), 3_000_000, nil)
        }
        let drive = try #require(candidates.map(\.item).first { $0.title == "Mon Drive" })

        // Le fichier lui-même, pas le dossier « Mon Drive » (qui contient « Photos »).
        #expect(drive.paths == [root.appendingPathComponent("Mon Drive/rapport.pdf")])
        #expect(drive.sizes.freeable == 2_000_000)
    }

    @Test("Des chemins reçus sous /System/Volumes/Data sont rangés comme les autres")
    func firmlinkedPaths() throws {
        let home = URL(fileURLWithPath: "/Home/test")
        let context = RuleContext(home: home, projectRoots: [], processes: ProcessSnapshot(processes: []),
                                  tools: .none, runningApps: [], applicationName: { _ in nil })
        let root = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let provider = CloudCopiesFinder.Provider(root: root, name: "iCloud Drive", rule: "cloud.icloud")
        let physical = "/System/Volumes/Data" + root.path

        let candidates = CloudCopiesFinder(context: context).candidates(for: provider) { _, visit in
            _ = visit(URL(fileURLWithPath: physical + "/Business/devis.pdf"), 2_000_000, nil)
            _ = visit(URL(fileURLWithPath: physical + "/Famille/photo.heic"), 3_000_000, nil)
            _ = visit(URL(fileURLWithPath: physical + "/lâche.txt"), 1_500_000, nil)
        }
        let items = candidates.map(\.item)

        #expect(Set(items.map(\.title)) == ["Business", "Famille", "iCloud Drive"])
        #expect(items.first { $0.title == "Business" }?.paths == [root.appendingPathComponent("Business", isDirectory: true)])
        #expect(items.first { $0.title == "iCloud Drive" }?.paths == [root.appendingPathComponent("lâche.txt")])
    }

    @Test("Domaines morts, dossiers cachés et coffres de mots de passe sont écartés")
    func providersSkipped() throws {
        let home = try FakeHome()
        for folder in ["Library/CloudStorage/GoogleDrive-moi@exemple.fr", "Library/CloudStorage/GoogleDrive-moi@exemple.fr (10-07-2026 16:41)",
                       "Library/CloudStorage/.Trash", "Library/Mobile Documents/com~apple~CloudDocs",
                       "Library/Mobile Documents/iCloud~com~agilebits~onepassword", "Library/Mobile Documents/iCloud~md~obsidian"] {
            try FileManager.default.createDirectory(at: home.root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // Un ancien dossier d'un fournisseur déconnecté n'est plus dans le nuage.
        let providers = CloudCopiesFinder(context: home.context()).providers { !$0.lastPathComponent.contains("(") }

        #expect(Set(providers.map(\.name)) == ["Google Drive", "iCloud Drive", "iCloud · Obsidian"])
    }

    @Test("Un gros fichier ordinaire n'est pas compté")
    func ordinaryLargeFile() throws {
        let home = try FakeHome()
        try home.file("Library/CloudStorage/Dropbox/film.mov", bytes: 2_000_000)
        var visited = 0
        CloudCopiesFinder.largeFiles(under: home.root.appendingPathComponent("Library/CloudStorage/Dropbox")) { _, _, _ in
            visited += 1
            return true
        }
        #expect(visited == 0)
    }

    @Test("Seul ce qui est téléchargé et déjà envoyé s'évince")
    func eligibility() {
        var status = CloudFile.Status()
        status.isUbiquitous = true
        status.isLocal = true
        status.isUploaded = true
        #expect(status.isEvictable)
        var pending = status
        pending.isUploaded = false
        #expect(!pending.isEvictable)
        var uploading = status
        uploading.isUploading = true
        #expect(!uploading.isEvictable)
        var conflict = status
        conflict.hasConflicts = true
        #expect(!conflict.isEvictable)
        var remote = status
        remote.isLocal = false
        #expect(!remote.isEvictable)
        #expect(!CloudFile.Status().isEvictable)
    }

    @Test("Un fichier ordinaire n'est pas dans le nuage")
    func ordinaryFileIsNotUbiquitous() throws {
        let home = try FakeHome()
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/doc.txt", bytes: 2_000_000)
        var visited: [URL] = []
        CloudFile.walk(home.root.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")) { url, _, _ in
            visited.append(url)
            return true
        }
        #expect(visited.isEmpty)
    }

    @Test("Noms des fournisseurs")
    func providerNames() {
        #expect(CloudCopiesFinder.providerName("GoogleDrive-moi@exemple.fr") == "Google Drive")
        #expect(CloudCopiesFinder.providerName("OneDrive-Personal") == "OneDrive")
        #expect(CloudCopiesFinder.providerName("Dropbox") == "Dropbox")
    }
}

@Suite("Compression des projets endormis")
struct CompressionFinderTests {

    /// Du texte qui se compresse comme du code ou des journaux : un paragraphe
    /// tiré au hasard, répété (zlib ne voit que 32 Kio en arrière).
    static func text(_ words: Int) -> String {
        let vocabulary = ["let", "var", "func", "return", "struct", "import", "guard", "else", "self", "oust"]
        var generator = SystemRandomNumberGenerator()
        let paragraph = (0..<min(words, 20_000)).map { _ in vocabulary.randomElement(using: &generator)! }
            .joined(separator: " ")
        return String(repeating: paragraph + "\n", count: max(1, words / 20_000))
    }

    @Test("Un projet endormi est proposé avec un gain estimé ; un projet vivant ne l'est pas")
    func staleProjects() async throws {
        let home = try FakeHome()
        let old = Date().addingTimeInterval(-400 * 86_400)
        for index in 0..<4 {
            try home.text("Developpement/endormi/logs/journal-\(index).log", Self.text(900_000))
            try home.setModified("Developpement/endormi/logs/journal-\(index).log", old)
        }
        try home.setModified("Developpement/endormi/logs", old)
        try home.text("Developpement/vivant/journal.log", Self.text(900_000))

        let items = await RuleEngine.collect(home.context(), finders: [.compression])

        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.title == "endormi")
        #expect(item.method == .compressInPlace && item.safety == .review)
        #expect(item.notes.contains(.estimated))
        #expect(item.sizes.freeable > 10_000_000)
        #expect(!PreselectionPolicy().preselects(item))
    }

    @Test("Les fichiers déjà compressés et les dossiers git ne comptent pas")
    func skips() throws {
        let home = try FakeHome()
        let old = Date().addingTimeInterval(-400 * 86_400)
        try home.text("Developpement/p/.git/objects/pack/pack.idx", Self.text(100_000))
        try home.file("Developpement/p/photo.jpg", bytes: 300_000)
        try home.text("Developpement/p/petit.txt", "court")
        try home.text("Developpement/p/code.swift", Self.text(20_000))
        for path in [".git/objects/pack/pack.idx", ".git/objects/pack", ".git/objects", ".git", "photo.jpg", "petit.txt",
                     "code.swift"] {
            try home.setModified("Developpement/p/\(path)", old)
        }

        let survey = try #require(CompressionSurvey.survey(home.root.appendingPathComponent("Developpement/p"),
                                                           cutoff: Date().addingTimeInterval(-180 * 86_400)))

        #expect(survey.files.map(\.url.lastPathComponent) == ["code.swift"])
    }

    @Test("Un petit fichier compressé occupe toujours un bloc ; le gain suit la taille compressée")
    func allocationModel() {
        #expect(CompressionSurvey.allocatedAfterCompression(size: 3_000, ratio: 0.2) == 4_096)
        #expect(CompressionSurvey.allocatedAfterCompression(size: 1_000_000, ratio: 0.1) == 102_400)
        // Un fichier qui ne se compresse pas ne rend rien (et ne prend pas moins qu'avant).
        #expect(CompressionSurvey.allocatedAfterCompression(size: 1_000_000, ratio: 1.0) >= 1_000_000)
    }
}

extension FakeHome {
    func setModified(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: root.appendingPathComponent(relative).path)
    }
}
