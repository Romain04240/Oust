import AVKit
import Photos
import PhotosUI
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustPhotos

/// L'aperçu en grand, façon Coup d'œil : un clic sur une vignette, ou la barre
/// d'espace sur l'élément choisi. Les flèches passent à l'élément voisin, Échap
/// et la barre d'espace referment. La case reste là, avec le même effet que dans
/// la liste : rien n'est coché d'office.
///
/// Demandé par Romain (18/10/2026) : « en petit comme ça, c'est compliqué de se
/// faire une idée […], on risque de faire des erreurs ».
struct PhotoPreview: View {
    let model: AppModel
    let preview: PhotosModel.Preview
    @FocusState private var focused: Bool

    private var photos: PhotosModel { model.photos }
    private var entry: PhotoEntry { preview.sequence.current }

    var body: some View {
        ZStack {
            // Un fond plein, le profond de la section assombri : à 84 % de noir,
            // la liste transparaissait derrière l'image et ses détails (revue du
            // 18/10/2026), et une photo se juge mal sur un fond qui bouge.
            ZStack {
                Palette.colors(for: .photos).deep
                Color.black.opacity(0.6)
            }
            .ignoresSafeArea()
            .onTapGesture { photos.closePreview() }
            VStack(spacing: Spacing.large) {
                header
                if preview.tab == .duplicates, let group = preview.group {
                    SideBySide(model: model, preview: preview, group: group)
                } else {
                    PreviewMedia(photos: photos, entry: entry, allowNetwork: photos.allowsDownload(entry.id))
                        .id(entry.id)
                    Details(model: model, preview: preview, entry: entry)
                }
                Text("photos.preview.hint", bundle: .oust)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.onGradient)
            }
            .padding(Spacing.xxLarge)
        }
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) { close() }
        .onKeyPress(.escape) { close() }
        .onExitCommand { photos.closePreview() }
        .onKeyPress(.leftArrow) {
            photos.stepPreview(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            photos.stepPreview(1)
            return .handled
        }
        // Un fondu seul. Avec une réduction d'échelle en plus, le fond plein, qui
        // couvre toute la section, rétrécissait de 3 % en s'effaçant : à la
        // fermeture, un cadre noir translucide passait sur ses bords (Romain,
        // 18/10/2026 : « c'est littéralement ce que je veux pas »).
        .transition(.opacity)
    }

    private func close() -> KeyPress.Result {
        photos.closePreview()
        return .handled
    }

    private var header: some View {
        HStack(spacing: Spacing.medium) {
            Button { photos.stepPreview(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(OnGradientButtonStyle())
                .disabled(!preview.sequence.canGoBack)
                .accessibilityLabel(Text("photos.preview.previous", bundle: .oust))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: entry.title).font(Typography.headline).lineLimit(1).truncationMode(.middle)
                Text(verbatim: L10n.string("photos.preview.position", Formatters.count(preview.sequence.index + 1),
                                           Formatters.count(preview.sequence.entries.count)))
                    .font(Typography.caption).monospacedDigit()
            }
            .foregroundStyle(Palette.onGradient)
            Button { photos.stepPreview(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(OnGradientButtonStyle())
                .disabled(!preview.sequence.canGoForward)
                .accessibilityLabel(Text("photos.preview.next", bundle: .oust))
            Spacer()
            // L'autorisation de la session se voit, et se retire d'un clic.
            if photos.downloadsAllowedForSession {
                Tag(L10n.string("photos.preview.session_on"), symbol: "icloud.and.arrow.down", tint: Palette.vivid(for: .rebuilds))
                Button { photos.stopDownloadsForSession() } label: { Text("photos.preview.session_stop", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
            Button { photos.closePreview() } label: {
                Label { Text("photos.preview.close", bundle: .oust) } icon: { Image(systemName: "xmark") }
            }
            .buttonStyle(OnGradientButtonStyle())
        }
    }
}

// MARK: - Ce qu'on montre

/// L'image en grand, la vidéo avec ses commandes, ou la Live Photo qui s'anime.
/// Sans réseau : ce qui est sur ce Mac, et on dit quand ce n'est qu'une version
/// réduite. Le téléchargement depuis iCloud n'a lieu qu'après confirmation.
private struct PreviewMedia: View {
    let photos: PhotosModel
    let entry: PhotoEntry
    let allowNetwork: Bool
    /// Côte à côte, les copies d'un doublon se montrent en image seule.
    var stillOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: PhotoImage?
    @State private var player: AVPlayer?
    @State private var live: PhotoLive?
    @State private var loaded = false
    @State private var confirming = false

    private var isVideo: Bool { entry.asset.media == .video }

    var body: some View {
        VStack(spacing: Spacing.small) {
            ZStack {
                if let player {
                    VideoPlayer(player: player)
                } else if let live, !live.isReduced {
                    LivePhotoView(livePhoto: live.livePhoto, plays: !reduceMotion)
                } else if let image {
                    Image(decorative: image.thumbnail.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if loaded {
                    Label { Text("photos.preview.unavailable", bundle: .oust) } icon: { Image(systemName: "photo") }
                        .font(Typography.body)
                        .foregroundStyle(Palette.onGradient)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            if loaded, let reason = cloudReason {
                // Rien ne sort du Mac : c'est Photos qui télécharge l'original de
                // l'utilisateur, à sa demande expresse, pour qu'il le voie en entier.
                HStack(spacing: Spacing.medium) {
                    Label { Text(verbatim: L10n.string(reason)) } icon: { Image(systemName: "icloud") }
                        .font(Typography.caption)
                        .foregroundStyle(Palette.onGradient)
                        .fixedSize(horizontal: false, vertical: true)
                    if !allowNetwork {
                        Button { confirming = true } label: {
                            Text(isVideo ? "photos.preview.play_cloud" : "photos.preview.download", bundle: .oust)
                        }
                        .buttonStyle(OnGradientButtonStyle())
                    }
                }
            }
        }
        .task(id: allowNetwork) { await load() }
        .onDisappear { player?.pause() }
        .confirmationDialog(Text("photos.preview.download_title", bundle: .oust), isPresented: $confirming) {
            Button { photos.allowDownload(entry.id) } label: { Text("photos.preview.download_confirm", bundle: .oust) }
            Button { photos.allowDownloadsForSession() } label: { Text("photos.preview.download_session", bundle: .oust) }
            Button(role: .cancel) {} label: { Text("common.cancel", bundle: .oust) }
        } message: {
            Text(verbatim: L10n.string("photos.preview.download_message", entry.title,
                                       Formatters.compactBytes(entry.size.inCloudOnly)))
        }
    }

    /// Pourquoi on ne montre pas l'original, s'il manque. Photos ne marque pas
    /// toujours comme dégradée la petite copie locale d'un original resté dans
    /// iCloud (revue du 18/10/2026) : ce qui est sur ce Mac fait foi aussi.
    private var cloudReason: String? {
        if isVideo, !stillOnly, player == nil, image != nil { return "photos.preview.video_cloud" }
        let reduced = image?.isReduced == true || (!allowNetwork && entry.size.isMostlyInCloud)
        return reduced && player == nil ? "photos.preview.reduced" : nil
    }

    private func load() async {
        loaded = false
        let id = entry.id
        // 2 048 points : de quoi remplir l'aperçu sur un écran Retina sans
        // demander à Photos l'original entier.
        image = await photos.image(for: id, side: 2048, allowNetwork: allowNetwork)
        if !stillOnly {
            if isVideo, let video = await photos.video(for: id, allowNetwork: allowNetwork) {
                player = AVPlayer(playerItem: video.item)
            } else if entry.asset.isLivePhoto {
                live = await photos.livePhoto(for: id, side: 2048, allowNetwork: allowNetwork)
            }
        }
        loaded = true
    }
}

/// Une Live Photo, qui s'anime à l'ouverture — sauf avec « Réduire les
/// animations », où elle ne bouge que si on la survole.
private struct LivePhotoView: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let plays: Bool

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .aspectFit
        view.isMuted = true
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        guard view.livePhoto !== livePhoto else { return }
        view.livePhoto = livePhoto
        if plays { view.startPlayback(with: .full) }
    }
}

// MARK: - Détails et case

private struct Details: View {
    let model: AppModel
    let preview: PhotosModel.Preview
    let entry: PhotoEntry
    /// Côte à côte, chaque copie n'a que la moitié de la largeur : les détails
    /// passent au-dessus de la case, sans quoi son libellé tenait sur deux lignes.
    var stacked = false
    @State private var albums: [String] = []

    private var photos: PhotosModel { model.photos }

    var body: some View {
        let item = photos.item(for: entry, in: preview.tab)
        let inCart = photos.isInCart(entry)
        let enabled = preview.group.map { photos.canToggle(entry, in: $0, tab: preview.tab) } ?? item.isSelectable
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.small))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.large))
        layout {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                if let created = entry.asset.created {
                    Text(verbatim: created.formatted(date: .long, time: .shortened)).font(Typography.body.weight(.semibold))
                }
                Text(verbatim: sizeLine).font(Typography.caption).monospacedDigit()
                if !albums.isEmpty {
                    Text(verbatim: L10n.string("photos.preview.albums", albums.joined(separator: ", ")))
                        .font(Typography.caption).lineLimit(2)
                }
            }
            .foregroundStyle(Palette.onGradient)
            if !stacked { Spacer(minLength: Spacing.medium) }
            HStack(spacing: Spacing.medium) {
                if let reason = item.protections.first {
                    Tag(Describe.protection(reason), symbol: "lock.fill", tint: Palette.vivid(for: .protected))
                } else if preview.tab == .duplicates, !inCart, !enabled {
                    Tag(L10n.string("photos.kept"), symbol: "star.fill", tint: Palette.vivid(for: .safe))
                }
                Button { photos.toggle(entry, in: preview.tab) } label: {
                    Label {
                        Text(inCart ? "row.remove_from_cart" : "row.add_to_cart", bundle: .oust)
                    } icon: {
                        Image(systemName: inCart ? "checkmark.circle.fill" : "circle")
                    }
                    .lineLimit(1)
                }
                .buttonStyle(OnGradientButtonStyle())
                .fixedSize()
                .disabled(!enabled)
            }
        }
        .task(id: entry.id) { albums = await photos.albums(for: entry.id) }
    }

    private var sizeLine: String {
        var line = entry.size.local > 0 ? L10n.string("photos.preview.on_mac", Formatters.compactBytes(entry.size.local))
            : L10n.string("photos.preview.nothing_on_mac")
        if entry.size.inCloudOnly > 0 {
            line += "  " + L10n.string("photos.in_icloud", Formatters.compactBytes(entry.size.inCloudOnly))
        }
        return line
    }
}

/// Les copies d'un doublon côte à côte : on voit qu'elles sont identiques, et
/// laquelle on garde. Les flèches, ou un clic, changent la copie choisie.
private struct SideBySide: View {
    let model: AppModel
    let preview: PhotosModel.Preview
    let group: PhotoGroup

    private var photos: PhotosModel { model.photos }

    var body: some View {
        Text(verbatim: L10n.string("photos.preview.copies", Formatters.count(group.entries.count)))
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(Palette.onGradient)
        HStack(alignment: .top, spacing: Spacing.large) {
            ForEach(group.entries) { copy in
                let current = copy.id == preview.sequence.current.id
                VStack(spacing: Spacing.small) {
                    PreviewMedia(photos: photos, entry: copy, allowNetwork: photos.allowsDownload(copy.id), stillOnly: true)
                        .padding(Spacing.tight)
                        .overlay(RoundedRectangle(cornerRadius: Radius.medium + Spacing.tight, style: .continuous)
                            .strokeBorder(.white.opacity(current ? 0.9 : 0.15), lineWidth: current ? 2 : 1))
                        .contentShape(Rectangle())
                        .onTapGesture { photos.showInPreview(copy.id) }
                    Details(model: model, preview: preview, entry: copy, stacked: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
