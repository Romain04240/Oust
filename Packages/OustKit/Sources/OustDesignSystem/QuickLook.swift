import AppKit
import QuickLook
import QuickLookUI
import SwiftUI
import OustLocalization

// MARK: - Coup d'œil

// Voir un fichier en grand avant de le jeter, sans quitter Oust!. Romain, pour
// la photothèque (18/10/2026) : « en petit, c'est compliqué de se faire une
// idée […] sinon, on risque de faire des erreurs ». Le nom, le chemin et la
// taille ne disent pas laquelle de deux vidéos de 4 Go est la bonne.
//
// L'aperçu ne fait que montrer. Il ne coche rien, ne retire rien de la
// corbeille et ne supprime rien : le panneau de macOS n'a pas de commande pour
// cela, et aucune des fonctions ci-dessous ne touche à la corbeille d'Oust!.

/// Ce qu'un chemin devient quand on veut le voir.
public enum PreviewKind: Sendable, Equatable {
    /// Un fichier : le panneau Coup d'œil de macOS.
    case file
    /// Un dossier : il s'ouvre dans le Finder. Le panneau n'en montrerait que
    /// l'icône, ce qui n'aide pas à décider.
    case folder
    /// Un paquet (application, bibliothèque Photos, projet…) : montré dans le
    /// Finder, jamais ouvert. L'ouvrir lancerait l'application.
    case package

    /// Lu sur le disque à l'instant. Un chemin illisible ou disparu est traité
    /// en fichier : le panneau dira lui-même qu'il n'a rien à montrer.
    public static func of(_ url: URL) -> PreviewKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isPackage == true { return .package }
        return values?.isDirectory == true ? .folder : .file
    }
}

/// Le Coup d'œil d'une section : le fichier montré, et ceux entre lesquels les
/// flèches du panneau circulent.
///
/// Une instance par liste, posée sur elle par `filePreview(_:)`. Le panneau est
/// celui de macOS (`QLPreviewPanel`) : Échap ou la barre d'espace le ferment, les
/// flèches passent au fichier voisin, et `current` suit.
@MainActor
@Observable
public final class FilePreview {
    /// Le fichier montré ; `nil` quand le panneau est fermé.
    public var current: URL?
    /// Les voisins, dans l'ordre de la liste. Toujours des fichiers : un dossier
    /// n'a rien à y faire, il s'ouvre dans le Finder.
    public private(set) var items: [URL] = []
    @ObservationIgnored private var panelKeys: Any?

    public init() {}

    public var isOpen: Bool { current != nil }

    /// Montre `url`, parmi `neighbors` (des fichiers, dans l'ordre de la liste).
    /// Un dossier s'ouvre dans le Finder, un paquet y est montré : ni l'un ni
    /// l'autre ne passe par le panneau.
    public func show(_ url: URL, among neighbors: [URL] = []) {
        switch PreviewKind.of(url) {
        case .folder:
            Self.openInFinder(url)
        case .package:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .file:
            items = neighbors.contains(url) ? neighbors : [url]
            current = url
        }
    }

    /// La barre d'espace : ouvre, ou referme si le panneau est déjà là.
    public func toggle(_ url: URL, among neighbors: [URL] = []) {
        if isOpen { close() } else { show(url, among: neighbors) }
    }

    /// La sélection de la liste a bougé : panneau ouvert, il la suit, comme dans
    /// le Finder. Un dossier choisi ne l'emmène pas : il resterait sans image.
    public func follow(_ url: URL?, among neighbors: [URL]) {
        guard isOpen, let url, url != current, neighbors.contains(url) else { return }
        items = neighbors
        current = url
    }

    public func close() {
        current = nil
    }

    /// Le fichier d'à côté dans `items` ; rien au bout de la liste.
    public func step(_ offset: Int) {
        guard let current, let index = items.firstIndex(of: current), items.indices.contains(index + offset) else { return }
        self.current = items[index + offset]
    }

    /// Le panneau de macOS ne passe d'un fichier à l'autre qu'avec ← et →, alors
    /// qu'une liste se parcourt avec ↑ et ↓ : à l'essai (18/10/2026), ↓ ne
    /// faisait rien. Tant qu'il est ouvert et qu'il a le clavier, ↑ et ↓ y
    /// passent aussi au voisin.
    func watchPanelKeys(_ on: Bool) {
        if on, panelKeys == nil {
            panelKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.window is QLPreviewPanel,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                let offset: Int
                switch event.keyCode {
                case 126: offset = -1   // ↑
                case 125: offset = 1    // ↓
                default: return event
                }
                MainActor.assumeIsolated { self?.step(offset) }
                return nil
            }
        } else if !on, let monitor = panelKeys {
            NSEvent.removeMonitor(monitor)
            panelKeys = nil
        }
    }

    /// Un dossier, dans une fenêtre du Finder, même si une autre application
    /// s'est déclarée pour les dossiers : on a promis le Finder.
    private static func openInFinder(_ url: URL) {
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension View {
    /// Pose le panneau Coup d'œil de macOS sur cette vue, piloté par `preview`.
    public func filePreview(_ preview: FilePreview) -> some View {
        modifier(FilePreviewPanel(preview: preview))
    }

    /// Une ligne d'une liste maison qui se choisit d'un clic, comme dans une
    /// liste de macOS, et dont la barre d'espace donne un coup d'œil.
    ///
    /// Le clic est simultané : la case à cocher et le double-clic de la ligne
    /// gardent leur effet, et choisir une ligne ne coche rien.
    public func previewRow(isSelected: Bool, select: @escaping () -> Void,
                           preview: (() -> Void)?) -> some View {
        modifier(PreviewRow(isSelected: isSelected, select: select, preview: preview))
    }

    /// Le clavier d'une liste maison : flèches haut et bas pour la ligne
    /// voisine, barre d'espace pour le coup d'œil. `order` : les identifiants
    /// des lignes affichées, de haut en bas.
    public func previewKeys<ID: Hashable>(selection: Binding<ID?>, order: [ID],
                                          space: @escaping (ID) -> Void) -> some View {
        modifier(PreviewKeys(selection: selection, order: order, space: space))
    }
}

private struct FilePreviewPanel: ViewModifier {
    @Bindable var preview: FilePreview

    func body(content: Content) -> some View {
        content
            .quickLookPreview($preview.current, in: preview.items)
            // Le panneau a ses propres touches quand il a le clavier ; quand la
            // liste l'a repris d'un clic, Échap le ferme aussi.
            .onKeyPress(.escape) {
                guard preview.isOpen else { return .ignored }
                preview.close()
                return .handled
            }
            .onChange(of: preview.isOpen) { preview.watchPanelKeys(preview.isOpen) }
            // Quitter la section referme le panneau : il ne doit pas continuer à
            // montrer les fichiers d'une liste qu'on ne voit plus.
            .onDisappear {
                preview.close()
                preview.watchPanelKeys(false)
            }
    }
}

private struct PreviewRow: ViewModifier {
    let isSelected: Bool
    let select: () -> Void
    let preview: (() -> Void)?

    func body(content: Content) -> some View {
        let row = content
            // Le surlignage déborde un peu de la ligne : collé au texte, il le
            // rognait à gauche.
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(Color.accentColor.opacity(0.45))
                        .padding(.horizontal, -Spacing.small)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(select))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        if let preview {
            row.accessibilityAction(named: Text("quicklook.action", bundle: .oust), preview)
        } else {
            row
        }
    }
}

private struct PreviewKeys<ID: Hashable>: ViewModifier {
    @Binding var selection: ID?
    let order: [ID]
    let space: (ID) -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard let selection else { return .ignored }
                    space(selection)
                    return .handled
                }
                .onKeyPress(.upArrow) { move(by: -1, proxy) }
                .onKeyPress(.downArrow) { move(by: 1, proxy) }
                // Un clic sur une ligne donne le clavier à la liste.
                .onChange(of: selection) { if selection != nil { focused = true } }
        }
    }

    private func move(by step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let index = selection.flatMap { order.firstIndex(of: $0) }.map { $0 + step } ?? (step > 0 ? 0 : order.count - 1)
        let next = order[min(max(index, 0), order.count - 1)]
        selection = next
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(next) }
        return .handled
    }
}

/// L'œil d'une ligne : visible au survol ou sur la ligne choisie. Caché, il
/// reste lu par VoiceOver, qui ne survole rien.
public struct PreviewButton: View {
    let kind: PreviewKind
    let isVisible: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(kind: PreviewKind = .file, isVisible: Bool, action: @escaping () -> Void) {
        self.kind = kind
        self.isVisible = isVisible
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "eye")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.onGradient)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        // Un fondu, sans mouvement : il reste avec Réduire les animations, en
        // plus court.
        .animation(.easeOut(duration: reduceMotion ? 0.05 : 0.15), value: isVisible)
        .help(Text(helpKey, bundle: .oust))
        .accessibilityLabel(Text(labelKey, bundle: .oust))
    }

    private var labelKey: LocalizedStringKey {
        switch kind {
        case .file: "quicklook.action"
        case .folder: "quicklook.open_folder"
        case .package: "row.reveal"
        }
    }

    private var helpKey: LocalizedStringKey {
        switch kind {
        case .file: "quicklook.help"
        case .folder: "quicklook.open_folder_help"
        case .package: "quicklook.reveal_help"
        }
    }
}

/// « Coup d'œil » dans un menu contextuel, ou « Ouvrir dans le Finder » pour
/// un dossier.
public struct PreviewMenuItem: View {
    let kind: PreviewKind
    let action: () -> Void

    public init(kind: PreviewKind = .file, action: @escaping () -> Void) {
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        switch kind {
        case .file:
            Button(action: action) {
                Label { Text("quicklook.action", bundle: .oust) } icon: { Image(systemName: "eye") }
            }
        case .folder:
            Button(action: action) {
                Label { Text("quicklook.open_folder", bundle: .oust) } icon: { Image(systemName: "folder") }
            }
        case .package:
            // « Afficher dans le Finder » est déjà au menu de chaque ligne.
            EmptyView()
        }
    }
}
