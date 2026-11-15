/// Un paquet Safari peut être repris, quel que soit son dossier de destination.
public enum SafariDownloadPath {
    public static func hasPackageExtension(_ name: some StringProtocol) -> Bool {
        let suffix = ".download"
        return name.utf8.count > suffix.utf8.count && name.suffix(suffix.count).lowercased() == suffix
    }

    public static func containsPackage(_ path: String) -> Bool {
        path.split(separator: "/").contains(where: { hasPackageExtension($0) })
    }
}
