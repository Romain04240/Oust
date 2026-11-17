import AppKit

/// Le monogramme d'Oust!, image de la barre des menus (IDENTITE, « Fichiers »).
/// Pris en place dans Design/, comme l'icône, et copié dans l'app par
/// `project.yml`. Ici plutôt que dans l'app : l'aperçu des Réglages montre
/// exactement l'image que la barre des menus recevra.
@MainActor
public enum MenuBarIcon {
    /// Le monogramme : en image modèle, que macOS teint en blanc ou en noir ;
    /// ou aux couleurs de l'icône, si on le demande dans les Réglages.
    public static func image(colored: Bool, drive: Bool = false) -> NSImage {
        let name = colored ? "oust-monogramme-couleur" : "oust-monogramme"
        let monogram = drive ? nil : Bundle.main.url(forResource: name, withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:))
        let source = monogram
            ?? NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
            ?? NSImage()
        source.size = NSSize(width: 16, height: 16)
        source.isTemplate = drive || !colored
        return source
    }
}
