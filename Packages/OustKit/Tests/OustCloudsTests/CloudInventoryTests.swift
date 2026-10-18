import Foundation
import Testing
import OustCore
import OustSafety
import OustScan
@testable import OustClouds

/// Des inventaires écrits à la main : les fantômes ne se fabriquent pas dans un
/// dossier temporaire, la logique des listes se vérifie donc à part.
private enum Sample {
    static let iCloud = CloudAccount(id: "icloud", service: .iCloudDrive, account: nil, roots: [
        CloudRoot(url: URL(fileURLWithPath: "/m/Drive")),
        CloudRoot(url: URL(fileURLWithPath: "/m/Pages/Documents"), label: "Pages"),
    ])
    static let google = CloudAccount(id: "/m/GoogleDrive-a", service: .googleDrive, account: "a@b.fr",
                                     roots: [CloudRoot(url: URL(fileURLWithPath: "/m/GoogleDrive-a"))])

    static func date(_ year: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 6, day: 1))!
    }

    static func ghost(_ path: String, _ size: Int64, year: Int? = 2020) -> CloudListedFile {
        CloudListedFile(path: path, logicalSize: size, allocatedSize: 0, modified: year.map(date), fileID: 1, isDataless: true)
    }

    static func local(_ path: String, _ size: Int64, year: Int? = 2020) -> CloudListedFile {
        CloudListedFile(path: path, logicalSize: size, allocatedSize: size + 4_096, modified: year.map(date), fileID: 2,
                        isDataless: false)
    }

    static func inventory() -> CloudInventory {
        var drive = CloudListing()
        drive.files = [
            ghost("/m/Drive/Films/vacances.mov", 4_000_000_000, year: 2015),
            local("/m/Drive/Business/Facture.PDF", 2_000_000, year: 2024),
            ghost("/m/Drive/vieux.zip", 50_000_000, year: nil),
            local("/m/Drive/Cafe\u{301}.jpg", 3_000_000, year: 2018),
        ]
        drive.unlistedFolders = ["/m/Drive/Archives"]
        var pages = CloudListing()
        pages.files = [ghost("/m/Pages/Documents/Rapport.pages", 30_000_000, year: 2019)]
        var google = CloudListing()
        google.files = [
            ghost("/m/GoogleDrive-a/Mon Drive/facture.pdf", 2_000_000, year: 2021),
            ghost("/m/GoogleDrive-a/Mon Drive/Café.jpg", 3_000_000, year: 2022),
            ghost("/m/GoogleDrive-a/Mon Drive/facture-2.pdf", 2_000_001, year: 2021),
            ghost("/m/GoogleDrive-a/Mon Drive/petit.txt", 500, year: 2010),
            ghost("/m/GoogleDrive-a/Mon Drive/autre/petit.txt", 500, year: 2011),
        ]
        return CloudInventory(accounts: [iCloud, Sample.google], listings: [
            .init(account: iCloud, root: iCloud.roots[0], listing: drive),
            .init(account: iCloud, root: iCloud.roots[1], listing: pages),
            .init(account: Sample.google, root: Sample.google.roots[0], listing: google),
        ])
    }
}

@Suite("Les listes des nuages : gros, vieux, sur ce Mac, doublons évidents")
struct CloudInventoryTests {

    @Test("Les plus gros d'après le nuage, un compte à la fois si on le demande")
    func largest() {
        let inventory = Sample.inventory()
        #expect(inventory.largest(minimumSize: 10_000_000).map(\.name) == ["vacances.mov", "vieux.zip", "Rapport.pages"])
        #expect(inventory.largest(in: ["/m/GoogleDrive-a"], minimumSize: 2_500_000).map(\.name) == ["Café.jpg"])
    }

    @Test("Les plus vieux du plus ancien au plus récent ; sans date, jamais « vieux »")
    func oldest() {
        let inventory = Sample.inventory()
        let old = inventory.oldest(before: Sample.date(2020), minimumSize: 1_000_000)
        #expect(old.map(\.name) == ["vacances.mov", "Café.jpg", "Rapport.pages"])
        #expect(!old.contains { $0.name == "vieux.zip" })
    }

    @Test("Sur ce Mac : seulement ce qui y occupe de la place")
    func onThisMac() {
        let inventory = Sample.inventory()
        #expect(inventory.onThisMac().map(\.name) == ["Café.jpg", "Facture.PDF"])
    }

    @Test("Doublons évidents : même nom (casse et accents composés confondus) et même taille")
    func duplicates() throws {
        let inventory = Sample.inventory()
        let groups = inventory.duplicates(minimumSize: 1_000_000)
        #expect(groups.count == 2)
        // Le groupe qui rendrait le plus en tête ; les copies du plus ancien au plus récent.
        let cafe = groups[0]
        #expect(cafe.size == 3_000_000 && cafe.cloudSavings == 3_000_000)
        #expect(cafe.files.map(\.accountID) == ["icloud", "/m/GoogleDrive-a"])
        let facture = groups[1]
        #expect(Set(facture.files.map(\.name)) == ["Facture.PDF", "facture.pdf"])
        // Un octet d'écart : pas un doublon. Sous le seuil : pas montré.
        #expect(!groups.contains { $0.files.contains { $0.name == "facture-2.pdf" } })
        #expect(!groups.contains { $0.name == "petit.txt" })
        #expect(inventory.duplicates(minimumSize: 1).contains { $0.name == "petit.txt" })
    }

    @Test("Totaux par compte : nuage, ce Mac, dossiers pas encore listés")
    func summaries() throws {
        let inventory = Sample.inventory()
        let iCloud = try #require(inventory.summaries["icloud"])
        #expect(iCloud.files == 5)
        #expect(iCloud.cloudBytes == 4_000_000_000 + 2_000_000 + 50_000_000 + 3_000_000 + 30_000_000)
        #expect(iCloud.localBytes == 2_000_000 + 3_000_000 + 2 * 4_096)
        #expect(iCloud.downloadedFiles == 2 && iCloud.unlistedFolders == 1)
        #expect(inventory.summary(of: []).files == 10)
    }

    @Test("Le dossier dans le nuage porte le nom de sa racine")
    func folders() throws {
        let inventory = Sample.inventory()
        let rapport = try #require(inventory.files.first { $0.name == "Rapport.pages" })
        #expect(rapport.folder == ["Pages"])
        let film = try #require(inventory.files.first { $0.name == "vacances.mov" })
        #expect(film.folder == ["Films"])
        #expect(film.place(account: Sample.iCloud) == "iCloud Drive › Films")
    }

    @Test("Ce qui vient de partir quitte les listes et les totaux")
    func removing() throws {
        let inventory = Sample.inventory().removing(["/m/Drive/Business/Facture.PDF"])
        #expect(!inventory.files.contains { $0.name == "Facture.PDF" })
        let iCloud = try #require(inventory.summaries["icloud"])
        #expect(iCloud.files == 4 && iCloud.downloadedFiles == 1)
        #expect(inventory.duplicates(minimumSize: 1_000_000).count == 1)
    }
}

@Suite("Un fichier d'un nuage comme élément de la corbeille")
struct CloudItemTests {

    @Test("À examiner, jamais coché d'office, et rien d'annoncé sur ce Mac pour un fantôme")
    func ghostItem() throws {
        let inventory = Sample.inventory()
        let film = try #require(inventory.files.first { $0.name == "vacances.mov" })
        let item = film.cleanupItem(account: Sample.iCloud, guard: PathGuard(home: URL(fileURLWithPath: "/m")))

        #expect(item.method == .trashFromCloud && item.safety == .review)
        #expect(!PreselectionPolicy().preselects(item))
        #expect(item.sizes.freeable == 0 && item.notes == [.cloudOnly])
        #expect(item.rebuild == .cloudTrash && item.category.section == .clouds)
        #expect(item.owner == "iCloud Drive")
    }

    @Test("Téléchargé : ce qu'il occupe ici est annoncé")
    func localItem() throws {
        let inventory = Sample.inventory()
        let facture = try #require(inventory.files.first { $0.name == "Facture.PDF" })
        let item = facture.cleanupItem(account: Sample.iCloud, guard: PathGuard(home: URL(fileURLWithPath: "/m")))
        #expect(item.sizes.freeable == 2_000_000 + 4_096 && item.notes.isEmpty)
    }

    @Test("Hors des documents d'un nuage, protégé")
    func protectedOutsideDocuments() {
        let file = CloudEntry(url: URL(fileURLWithPath: "/m/Library/Mobile Documents/com~apple~mail/Data/x.plist"),
                             accountID: "icloud", folder: [], cloudSize: 10, localSize: 10, freeable: 10, modified: nil,
                             fileID: 1, isDataless: false)
        let item = file.cleanupItem(account: Sample.iCloud, guard: PathGuard(home: URL(fileURLWithPath: "/m")))
        #expect(item.protections == [.systemPath] && !item.isSelectable)
    }
}
