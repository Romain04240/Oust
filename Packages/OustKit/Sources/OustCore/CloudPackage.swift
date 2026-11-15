import Foundation

/// Documents cloud à traiter comme une unité, même sans reconnaissance du Finder.
public enum CloudPackage {
    public static let extensions: Set<String> = [
        "pages", "numbers", "key", "rtfd", "logicx", "band", "fcpbundle", "imovielibrary", "photoslibrary",
        "musiclibrary", "tvlibrary", "aplibrary", "lrlibrary", "sparsebundle", "app", "bundle", "framework",
        "xcodeproj", "xcworkspace", "playground", "scriv", "sketch", "graffle", "oo3", "mindnode", "ulysses",
        "nb", "dtBase2", "dtSparse", "pkg", "mpkg", "dmgpart", "mlpackage", "xcarchive", "playgroundbook",
        "epub", "ibooks",
    ]

    private static let normalizedExtensions = Set(extensions.map { $0.lowercased() })

    /// À appeler pour un dossier. Un fichier ordinaire peut porter la même extension.
    public static func isIndivisible(named name: String, reportedBySystem: Bool = false) -> Bool {
        reportedBySystem || normalizedExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
