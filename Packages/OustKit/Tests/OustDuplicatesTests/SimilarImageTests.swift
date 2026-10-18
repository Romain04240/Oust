import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OustDuplicates
import OustCore

/// Un dossier temporaire rempli d'images fabriquées : jamais une vraie photo.
final class ImageFolder {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oust-similar-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func image(_ relative: String, _ image: CGImage, type: UTType = .jpeg, quality: Double = 0.9,
               captured: String? = nil, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let captured {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: captured]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// Les options d'un test : ce dossier seul, et tout ce qui est image compte.
    func options(minimumSize: Int64 = 1, minimumSide: Int = 64) -> SimilarImageOptions {
        SimilarImageOptions(roots: [root], minimumSize: minimumSize, minimumSide: minimumSide)
    }
}

// MARK: - Images fabriquées

/// Des scènes dessinées, déterministes : un paysage, une ville, une page.
enum Drawing {
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func canvas(_ width: Int, _ height: Int, _ draw: (CGContext, Double, Double) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context, Double(width), Double(height))
        return context.makeImage()!
    }

    static func landscape(seed: UInt64 = 1) -> CGImage {
        canvas(1600, 1066) { context, width, height in
            var random = Random(state: seed)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let sky = CGGradient(colorsSpace: space, colors: [
                CGColor(srgbRed: 0.95, green: 0.6, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.2, green: 0.35, blue: 0.8, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: height * 0.3), end: CGPoint(x: 0, y: height), options: [])
            context.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.6, alpha: 1))
            context.fillEllipse(in: CGRect(x: width * 0.6, y: height * 0.7, width: height * 0.12, height: height * 0.12))
            for layer in 0..<4 {
                let shade = 0.15 + Double(layer) * 0.1
                context.setFillColor(CGColor(srgbRed: shade * 0.6, green: shade, blue: shade * 0.8, alpha: 1))
                context.move(to: .zero)
                var y = height * (0.55 - Double(layer) * 0.12)
                for step in 0...40 {
                    y = max(height * 0.05, min(height * 0.9, y + (random.next() - 0.5) * height * 0.08))
                    context.addLine(to: CGPoint(x: Double(step) * width / 40, y: y))
                }
                context.addLine(to: CGPoint(x: width, y: 0))
                context.closePath()
                context.fillPath()
            }
        }
    }

    static func city(seed: UInt64 = 3) -> CGImage {
        canvas(1600, 1066) { context, width, height in
            var random = Random(state: seed)
            context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x = 0.0
            while x < width {
                let building = width * (0.04 + random.next() * 0.08), tall = height * (0.2 + random.next() * 0.6)
                context.setFillColor(CGColor(gray: 0.1 + random.next() * 0.2, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: building, height: tall))
                context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1))
                var row = height * 0.02
                while row < tall - height * 0.03 {
                    var column = x + building * 0.1
                    while column < x + building * 0.85 {
                        if random.next() > 0.4 {
                            context.fill(CGRect(x: column, y: row, width: building * 0.1, height: height * 0.015))
                        }
                        column += building * 0.2
                    }
                    row += height * 0.035
                }
                x += building + width * 0.005
            }
        }
    }

    static func page(seed: UInt64 = 7) -> CGImage {
        canvas(1100, 1500) { context, width, height in
            var random = Random(state: seed)
            context.setFillColor(CGColor(gray: 0.97, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            var y = height * 0.9
            while y > height * 0.08 {
                var x = width * 0.1
                while x < width * 0.88 {
                    let word = width * (0.02 + random.next() * 0.07)
                    context.fill(CGRect(x: x, y: y, width: word, height: height * 0.012))
                    x += word + width * 0.012
                }
                y -= height * 0.03
            }
        }
    }

    /// Une couleur unie, pour les tests où seules comptent les empreintes factices.
    static func plain(_ gray: Double = 0.5, width: Int = 400, height: Int = 300) -> CGImage {
        canvas(width, height) { context, w, h in
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// Recadrée au centre, éclaircie, réduite : ce qu'on fait d'une photo.
    static func variant(_ image: CGImage, crop: Double = 1, brighten: Double = 0, scale: Double = 1) -> CGImage {
        var source = image
        if crop < 1 {
            let width = Int(Double(image.width) * crop), height = Int(Double(image.height) * crop)
            source = image.cropping(to: CGRect(x: (image.width - width) / 2, y: (image.height - height) / 2,
                                               width: width, height: height))!
        }
        return canvas(Int(Double(source.width) * scale), Int(Double(source.height) * scale)) { context, width, height in
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            if brighten > 0 {
                context.setBlendMode(.screen)
                context.setFillColor(CGColor(gray: brighten, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
    }
}

/// Des empreintes choisies à la main, par nom de fichier : de quoi vérifier les
/// paires et les groupes sans dépendre de ce que Vision voit.
struct FakePrinter: ImagePrinter {
    let table: [String: [Float]]
    var fallback: [Float] = [1, 0]

    func featurePrint(of url: URL, side: Int) -> ImagePrint? {
        ImagePrint(table[url.lastPathComponent] ?? fallback)
    }
}

/// Un vecteur de norme 1, à `degrees` de l'axe : la distance entre deux d'entre
/// eux est 2 sin(écart / 2). 26° donnent 0,45.
func unit(_ degrees: Double) -> [Float] {
    let radians = degrees * .pi / 180
    return [Float(cos(radians)), Float(sin(radians))]
}

// MARK: - Tests

@Suite("Les images similaires, hors photothèque")
struct SimilarImageTests {

    @Test("Une photo recadrée, éclaircie, réduite ou recompressée reste avec l'originale ; une autre scène non")
    func variantsGroupWithVision() async throws {
        let folder = try ImageFolder()
        let original = Drawing.landscape()
        // Un export garde la date de prise de vue de l'original.
        let shot = "2026:07:14 10:00:00"
        try folder.image("Images/paysage.jpg", original, captured: shot)
        try folder.image("Images/paysage recadré.jpg", Drawing.variant(original, crop: 0.9), captured: shot)
        try folder.image("Images/paysage clair.jpg", Drawing.variant(original, brighten: 0.2), captured: shot)
        try folder.image("Images/paysage petit.png", Drawing.variant(original, scale: 0.5), type: .png, captured: shot)
        try folder.image("Images/paysage.heic", original, type: .heic, quality: 0.5, captured: shot)
        try folder.image("Images/ville.jpg", Drawing.city())
        try folder.image("Images/page.jpg", Drawing.page())

        let findings = await SimilarImageFinder.find(folder.options(minimumSide: 320))

        #expect(findings.examined == 7)
        #expect(findings.groups.count == 1)
        let names = Set(findings.groups.first?.images.map(\.url.lastPathComponent) ?? [])
        #expect(names == ["paysage.jpg", "paysage recadré.jpg", "paysage clair.jpg", "paysage petit.png", "paysage.heic"])
    }

    @Test("Sans date ni nom commun, une copie réduite ou recompressée est retrouvée au seuil strict")
    func strictContextWithVision() async throws {
        let folder = try ImageFolder()
        let original = Drawing.landscape()
        try folder.image("paysage.jpg", original)
        try folder.image("bannière.png", Drawing.variant(original, scale: 0.5), type: .png)
        try folder.image("léger.heic", original, type: .heic, quality: 0.4)
        try folder.image("ville.jpg", Drawing.city())

        let findings = await SimilarImageFinder.find(folder.options(minimumSide: 320))

        #expect(findings.groups.count == 1)
        #expect(Set(findings.groups.first?.images.map(\.url.lastPathComponent) ?? []) == ["paysage.jpg", "bannière.png", "léger.heic"])
    }

    @Test("Quatre recherches à la fois ne se figent pas", .timeLimit(.minutes(1)))
    func parallelSearchesFinish() async throws {
        // Vision appelé depuis le pool coopératif de Swift s'y bloquait quand
        // plusieurs recherches tournaient ensemble (18/10/2026).
        let folder = try ImageFolder()
        let original = Drawing.landscape()
        for index in 0..<6 {
            try folder.image("paysage \(index).png", Drawing.variant(original, scale: 0.4 + Double(index) * 0.05), type: .png)
        }
        let options = folder.options(minimumSide: 320)
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 { group.addTask { await SimilarImageFinder.find(options).groups.count } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts == [1, 1, 1, 1])
    }

    @Test("Trois scènes différentes ne forment aucun groupe")
    func differentScenesStayApart() async throws {
        let folder = try ImageFolder()
        try folder.image("paysage.jpg", Drawing.landscape())
        try folder.image("ville.jpg", Drawing.city())
        try folder.image("page.png", Drawing.page(), type: .png)

        let findings = await SimilarImageFinder.find(folder.options(minimumSide: 320))

        #expect(findings.examined == 3)
        #expect(findings.groups.isEmpty)
    }

    @Test("La meilleure copie : la plus grande résolution, puis l'originale (la plus ancienne)")
    func bestCopy() async throws {
        let folder = try ImageFolder()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try folder.image("petite.jpg", Drawing.plain(width: 800, height: 600), modified: old.addingTimeInterval(500))
        try folder.image("grande.jpg", Drawing.plain(width: 1600, height: 1200), modified: old)
        try folder.image("grande récente.jpg", Drawing.plain(width: 1600, height: 1200), modified: old.addingTimeInterval(60))

        let findings = await SimilarImageFinder.find(folder.options(), printer: FakePrinter(table: [:]))

        let group = try #require(findings.groups.first)
        #expect(group.images.map(\.url.lastPathComponent) == ["grande.jpg", "grande récente.jpg", "petite.jpg"])
        #expect(group.best?.pixelWidth == 1600)
        // L'économie annoncée : tout sauf la meilleure.
        #expect(group.potential == group.images.dropFirst().reduce(0) { $0 + $1.privateSize })
        #expect(group.potential > 0)
    }

    @Test("Entre deux dossiers, seules les images prises à moins de 5 minutes sont comparées")
    func acrossFoldersByCaptureDate() async throws {
        let folder = try ImageFolder()
        let gray = Drawing.plain()
        try folder.image("Bureau/a.jpg", gray, captured: "2026:07:14 10:00:00")
        try folder.image("Téléchargements/b.jpg", gray, captured: "2026:07:14 10:03:00")
        try folder.image("Documents/c.jpg", gray, captured: "2026:07:14 18:00:00")

        let findings = await SimilarImageFinder.find(folder.options(), printer: FakePrinter(table: [:]))

        #expect(findings.groups.count == 1)
        #expect(Set(findings.groups.first?.images.map(\.url.lastPathComponent) ?? []) == ["a.jpg", "b.jpg"])
    }

    @Test("Sans date proche, une copie d'un autre dossier au même nom est comparée")
    func acrossFoldersByName() async throws {
        let folder = try ImageFolder()
        let gray = Drawing.plain()
        try folder.image("Images/IMG_1234.jpg", gray, captured: "2024:05:01 09:00:00")
        try folder.image("Bureau/IMG_1234 (1).jpg", gray, modified: Date(timeIntervalSince1970: 1_750_000_000))
        try folder.image("Documents/IMG_9999.jpg", gray, modified: Date(timeIntervalSince1970: 1_760_000_000))

        let findings = await SimilarImageFinder.find(folder.options(), printer: FakePrinter(table: [:]))

        #expect(Set(findings.groups.first?.images.map(\.url.lastPathComponent) ?? []) == ["IMG_1234.jpg", "IMG_1234 (1).jpg"])
        #expect(findings.groups.count == 1)
    }

    @Test("Un groupe ne se forme pas de proche en proche : chaque image ressemble à toutes les autres")
    func completeLinkage() async throws {
        let folder = try ImageFolder()
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try folder.image(name, Drawing.plain()) }
        // a–b et b–c à 0,26 ; a–c à 0,52 : au-delà du seuil.
        let printer = FakePrinter(table: ["a.jpg": unit(0), "b.jpg": unit(15), "c.jpg": unit(30)])

        let findings = await SimilarImageFinder.find(folder.options(), printer: printer)

        #expect(findings.groups.count == 1)
        #expect(findings.groups.first?.images.count == 2)
        #expect(findings.groups.first.map { $0.images.map(\.url.lastPathComponent).contains("b.jpg") } == true)
    }

    @Test("Pour une même prise de vue, le seuil est celui de Photos : 0,45")
    func threshold() async throws {
        let folder = try ImageFolder()
        for name in ["proche.jpg", "loin.jpg", "base.jpg"] {
            try folder.image(name, Drawing.plain(), captured: "2026:07:14 10:00:00")
        }
        // 25° : 0,433 ; 27° : 0,467.
        let printer = FakePrinter(table: ["base.jpg": unit(0), "proche.jpg": unit(25), "loin.jpg": unit(-27)])

        let findings = await SimilarImageFinder.find(folder.options(), printer: printer)

        #expect(SimilarImageOptions(roots: []).threshold == 0.45)
        #expect(Set(findings.groups.first?.images.map(\.url.lastPathComponent) ?? []) == ["base.jpg", "proche.jpg"])
    }

    @Test("Sans même prise de vue ni même nom, le seuil se resserre à 0,30")
    func strictThreshold() async throws {
        // 23,5° : 0,407, comme « Pigeon colombin » et « Pigeon ramier » sur le Mac de Romain.
        let pigeons = ["Pigeon colombin.png": unit(0), "Pigeon ramier.png": unit(23.5)]
        let apart = try ImageFolder()
        for name in pigeons.keys { try apart.image(name, Drawing.plain(), type: .png) }
        #expect(SimilarImageOptions(roots: []).strictThreshold == 0.30)
        #expect(await SimilarImageFinder.find(apart.options(), printer: FakePrinter(table: pigeons)).groups.isEmpty)

        // Même distance, même prise de vue : une rafale.
        let burst = try ImageFolder()
        try burst.image("IMG_0001.jpg", Drawing.plain(), captured: "2026:07:14 10:00:00")
        try burst.image("IMG_0002.jpg", Drawing.plain(), captured: "2026:07:14 10:00:02")
        let burstPrints = ["IMG_0001.jpg": unit(0), "IMG_0002.jpg": unit(23.5)]
        #expect(await SimilarImageFinder.find(burst.options(), printer: FakePrinter(table: burstPrints)).groups.count == 1)

        // Même distance, même nom au suffixe de copie près : une copie retouchée.
        let copy = try ImageFolder()
        try copy.image("Affiche.png", Drawing.plain(), type: .png)
        try copy.image("Affiche (1).png", Drawing.plain(), type: .png)
        let copyPrints = ["Affiche.png": unit(0), "Affiche (1).png": unit(23.5)]
        #expect(await SimilarImageFinder.find(copy.options(), printer: FakePrinter(table: copyPrints)).groups.count == 1)
    }

    @Test("Photothèques, catalogues, bibliothèques, dépôts git, projets et captures d'écran ne sont jamais lus")
    func exclusions() async throws {
        let folder = try ImageFolder()
        let gray = Drawing.plain()
        try folder.image("Images/gardée.jpg", gray)
        try folder.image("Images/gardée aussi.jpg", gray)
        try folder.image("Images/Photothèque.photoslibrary/originals/0/a.jpg", gray)
        try folder.image("Images/Aperçus.lrdata/0/b.jpg", gray)
        try folder.image("Images/Catalogue/c.jpg", gray)
        try Data().write(to: folder.root.appendingPathComponent("Images/Catalogue/Catalogue.lrcat"))
        try folder.image("Images/Projet/Assets.xcassets/AppIcon.appiconset/d.png", gray, type: .png)
        try folder.image("Documents/site/e.jpg", gray)
        try FileManager.default.createDirectory(at: folder.root.appendingPathComponent("Documents/site/.git"),
                                                withIntermediateDirectories: true)
        try folder.image("Documents/Développement/f.jpg", gray)
        try folder.image("Bureau/Capture d’écran 2026-10-18 à 14.32.10.png", gray, type: .png)
        try folder.image("Bureau/Library/g.jpg", gray)

        var options = folder.options()
        options.excludedFolders = [folder.root.appendingPathComponent("Documents/Développement")]
        let findings = await SimilarImageFinder.find(options, printer: FakePrinter(table: [:]))

        #expect(findings.examined == 2)
        #expect(Set(findings.groups.flatMap(\.images).map(\.url.lastPathComponent)) == ["gardée.jpg", "gardée aussi.jpg"])
    }

    @Test("Un lien physique n'est pas une copie de plus : il ne rendrait rien")
    func hardLinkCountedOnce() async throws {
        let folder = try ImageFolder()
        let original = try folder.image("original.jpg", Drawing.plain())
        #expect(Darwin.link(original.path, folder.root.appendingPathComponent("lien.jpg").path) == 0)

        let findings = await SimilarImageFinder.find(folder.options(), printer: FakePrinter(table: [:]))

        #expect(findings.examined == 1)
        #expect(findings.groups.isEmpty)
    }

    @Test("Trop petites, en octets ou en pixels : ni lues ni comparées")
    func tooSmall() async throws {
        let folder = try ImageFolder()
        try folder.image("icône.png", Drawing.plain(width: 128, height: 128), type: .png)
        try folder.image("icône@2x.png", Drawing.plain(width: 256, height: 256), type: .png)
        try folder.image("photo.jpg", Drawing.landscape())
        try folder.image("photo 2.jpg", Drawing.landscape())

        let findings = await SimilarImageFinder.find(folder.options(minimumSize: 1, minimumSide: 320),
                                                     printer: FakePrinter(table: [:]))
        #expect(findings.examined == 2)

        let bySize = await SimilarImageFinder.find(folder.options(minimumSize: 10_000_000, minimumSide: 1),
                                                   printer: FakePrinter(table: [:]))
        #expect(bySize.examined == 0)
    }

    @Test("Annulée, la recherche ne rend rien")
    func cancelled() async throws {
        let folder = try ImageFolder()
        try folder.image("a.jpg", Drawing.plain())
        try folder.image("b.jpg", Drawing.plain())
        let progress = SimilarImageProgress()
        progress.cancel()

        let findings = await SimilarImageFinder.find(folder.options(), progress: progress, printer: FakePrinter(table: [:]))

        #expect(findings.groups.isEmpty)
    }

    @Test("L'avancement compte les images examinées puis les empreintes")
    func progressCounts() async throws {
        let folder = try ImageFolder()
        for index in 0..<3 { try folder.image("\(index).jpg", Drawing.plain()) }
        let progress = SimilarImageProgress()

        _ = await SimilarImageFinder.find(folder.options(), progress: progress, printer: FakePrinter(table: [:]))

        #expect(progress.stage == .comparing)
        #expect(progress.done == progress.total)
    }

    @Test("Dans la corbeille : à examiner, vers la corbeille du Mac, jamais régénérable")
    func cleanupItem() throws {
        let image = SimilarImage(url: URL(fileURLWithPath: "/tmp/x/b.jpg"), logicalSize: 2_000_000, allocated: 2_002_944,
                                 privateSize: 2_002_944, modified: nil, captured: nil, pixelWidth: 100, pixelHeight: 100)
        let best = SimilarImage(url: URL(fileURLWithPath: "/tmp/x/a.jpg"), logicalSize: 3_000_000, allocated: 3_002_368,
                                privateSize: 3_002_368, modified: nil, captured: nil, pixelWidth: 200, pixelHeight: 200)
        let group = SimilarImageGroup(images: [image, best])
        let item = group.cleanupItem(for: image)

        #expect(group.best == best)
        #expect(item.id == "similar|/tmp/x/b.jpg")
        #expect(item.category == .similarImages)
        #expect(item.category.section == .duplicates)
        #expect(item.safety == .review)
        #expect(item.method == .trash)
        #expect(item.rebuild == .irreversible)
        #expect(item.sizes.freeable == 2_002_944)
        #expect(item.owner == "a.jpg")
    }

    @Test("D'un groupe, on ne peut jamais tout cocher ; décocher reste possible")
    func neverAllCopies() {
        func image(_ name: String) -> SimilarImage {
            SimilarImage(url: URL(fileURLWithPath: "/tmp/x/\(name)"), logicalSize: 1, allocated: 4096, privateSize: 4096,
                         modified: nil, captured: nil, pixelWidth: 10, pixelHeight: 10)
        }
        let (a, b, c) = (image("a.jpg"), image("b.jpg"), image("c.jpg"))
        let group = SimilarImageGroup(images: [a, b, c])

        #expect(group.canToggle(c, checked: []))
        #expect(group.canToggle(c, checked: [a.url.path]))
        #expect(!group.canToggle(c, checked: [a.url.path, b.url.path]))
        #expect(group.canToggle(a, checked: [a.url.path, b.url.path]))
        // Cochée ailleurs (depuis « Identiques ») : comptée de même.
        #expect(!group.canToggle(a, checked: [b.url.path, c.url.path, "/tmp/autre.jpg"]))
    }

    @Test("Un clone APFS ne rend rien : il le dit, et l'économie l'ignore")
    func cloneFreesNothing() throws {
        let clone = SimilarImage(url: URL(fileURLWithPath: "/tmp/x/a.png"), logicalSize: 2_222_996, allocated: 2_224_128,
                                 privateSize: 0, modified: nil, captured: nil, pixelWidth: 10, pixelHeight: 10)
        let best = SimilarImage(url: URL(fileURLWithPath: "/tmp/x/b.png"), logicalSize: 2_407_759, allocated: 2_408_448,
                                privateSize: 2_408_448, modified: nil, captured: nil, pixelWidth: 20, pixelHeight: 20)
        let group = SimilarImageGroup(images: [clone, best])

        #expect(clone.isClone)
        #expect(!best.isClone)
        #expect(group.potential == 0)
        #expect(group.cleanupItem(for: clone).sizes.freeable == 0)
    }

    @Test("Date de prise de vue : l'heure de l'appareil, avec son décalage s'il l'a noté")
    func exifDates() throws {
        let withOffset = try #require(ImageReader.exifDate("2026:10:18 14:32:10", offset: "+02:00"))
        #expect(withOffset == Date(timeIntervalSince1970: 1_792_326_730))
        #expect(ImageReader.exifDate("0000:00:00 00:00:00", offset: nil) == nil)
        #expect(ImageReader.exifDate("n'importe quoi", offset: nil) == nil)
    }

    @Test("Le nom sans suffixe de copie")
    func stems() {
        func stem(_ name: String) -> String { SimilarImageFinder.stem(of: URL(fileURLWithPath: "/x/" + name)) }
        #expect(stem("IMG_1234 (1).jpg") == "img_1234")
        #expect(stem("IMG_1234 copie.heic") == "img_1234")
        #expect(stem("IMG_1234 copy 2.jpg") == "img_1234")
        #expect(stem("IMG_1234-edited.png") == "img_1234")
        #expect(stem("IMG_1234.jpg") == "img_1234")
        #expect(stem("IMG_1235.jpg") == "img_1235")
        #expect(stem("(1).jpg") == "(1)")
    }

    @Test("La distance est euclidienne, comme celle de Vision")
    func distance() throws {
        let a = ImagePrint([1, 0, 0]), b = ImagePrint([0, 1, 0])
        #expect(abs((a.distance(to: b) ?? 0) - Float(2).squareRoot()) < 1e-6)
        #expect(a.distance(to: ImagePrint([1, 0])) == nil)
        #expect(abs((ImagePrint(unit(0)).distance(to: ImagePrint(unit(26))) ?? 0) - 0.45) < 0.002)
    }
}
