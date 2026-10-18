import AppKit
import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel
import OustUninstall

// MARK: - Applications mises à la corbeille du Mac

/// Les applications qu'on vient de mettre à la corbeille du Mac et dont les
/// restes attendent la revue, épinglées sous la liste comme les restes
/// d'applications disparues. Absente tant qu'il n'y en a pas.
struct TrashedAppsEntry: View {
    let model: AppModel

    private var trashed: TrashedAppsModel { model.trashedApps }
    private var applications: ApplicationsModel { model.applications }

    var body: some View {
        if !trashed.reports.isEmpty || applications.trashedReviewID != nil {
            let current = applications.trashedReviewID
            Button {
                if let first = trashed.reports.first { trashed.review(first.id) }
            } label: {
                HStack(spacing: Spacing.medium) {
                    Image(systemName: "trash.square")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Palette.color(for: .applications).gradient,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        // Court, pour tenir dans la liste de 300 pt : « Mises à la corbeille
                        // du Mac » s'y coupait (Romain, 18/10/2026).
                        Text("trashed.entry_title", bundle: .oust).font(Typography.body.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Text(verbatim: entryDetail).font(Typography.caption).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.small)
                    Text(verbatim: Formatters.compactBytes(trashed.totalFreeable)).font(Typography.size)
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.small)
                .background(current != nil ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.small)
            .padding(.top, Spacing.small)
            .disabled(trashed.reports.isEmpty)
            .accessibilityAddTraits(current != nil ? .isSelected : [])
        }
    }

    private var entryDetail: String {
        let names = trashed.reports.map(\.app.name)
        guard let first = names.first else { return L10n.string("trashed.entry_none") }
        return names.count == 1 ? first : L10n.string("trashed.entry_more", first, Formatters.count(names.count - 1))
    }
}

/// La revue d'une application mise à la corbeille du Mac : ce qu'elle a
/// laissé, coché comme dans le désinstalleur (ce qui ne sert plus à rien sans
/// elle ; le reste attend la main de l'utilisateur), puis la corbeille d'Oust!.
struct TrashedAppDetail: View {
    let model: AppModel
    let id: String

    private var trashed: TrashedAppsModel { model.trashedApps }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                // Plusieurs applications jetées : on passe de l'une à l'autre.
                let others = trashed.reports.filter { $0.id != id }
                if !others.isEmpty {
                    HStack(spacing: Spacing.small) {
                        Text("trashed.others", bundle: .oust).font(Typography.caption)
                        ForEach(others) { other in
                            Button { trashed.review(other.id) } label: { Text(verbatim: other.app.name).lineLimit(1) }
                                .buttonStyle(OnGradientButtonStyle())
                        }
                    }
                    .foregroundStyle(Palette.onGradient)
                }
                if let report = trashed.report(id) {
                    TrashedAppHeader(trashed: trashed, report: report)
                    TrashedAppItems(trashed: trashed, report: report)
                    Text("trashed.strict_note", bundle: .oust)
                        .font(Typography.caption).foregroundStyle(Palette.onGradient)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    gone
                }
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear { trashed.pruneMissing() }
    }

    /// L'application est revenue, une autre copie est là, ou il n'y a plus rien.
    @ViewBuilder private var gone: some View {
        switch trashed.withdrawn[id] {
        case .replaced, .anotherCopy:
            EmptyState(symbol: "arrow.uturn.backward.circle", title: "trashed.back_title", message: "trashed.back_detail")
        case .running:
            EmptyState(symbol: "play.circle", title: "trashed.running_title", message: "trashed.running_detail")
        default:
            EmptyState(symbol: "checkmark.seal", title: "trashed.none_title", message: "trashed.none_detail")
        }
    }
}

private struct TrashedAppHeader: View {
    let trashed: TrashedAppsModel
    let report: TrashedApp

    var body: some View {
        let bytes = trashed.chosenBytes(report)
        GlassCard(padding: Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Spacing.large) {
                HStack(alignment: .center, spacing: Spacing.large) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: report.app.url.path))
                        .resizable().interpolation(.high)
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(verbatim: report.app.name).font(Typography.title)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(verbatim: [report.app.version, report.app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(Typography.caption).lineLimit(1).truncationMode(.middle)
                        Label {
                            Text(verbatim: L10n.string("trashed.trashed_at", Formatters.relative(report.trashedAt)))
                        } icon: {
                            Image(systemName: "trash.square")
                        }
                        .font(Typography.caption)
                    }
                    .foregroundStyle(Palette.onGradient)
                    Spacer(minLength: 0)
                }
                Divider().overlay(Color.white.opacity(0.25))
                HStack(alignment: .center, spacing: Spacing.medium) {
                    VStack(alignment: .leading, spacing: 0) {
                        if bytes == 0 && trashed.chosenItems(report).isEmpty {
                            Text("applications.nothing_chosen", bundle: .oust).font(Typography.headline)
                        } else {
                            Text(verbatim: Formatters.compactBytes(bytes))
                                .font(Typography.title.monospacedDigit())
                                .contentTransition(.numericText(value: Double(bytes)))
                            Text("applications.chosen_caption", bundle: .oust).font(Typography.caption)
                        }
                    }
                    .foregroundStyle(Palette.onGradient)
                    .fixedSize()
                    Spacer(minLength: Spacing.medium)
                    Button { trashed.dismiss(report) } label: {
                        Text("trashed.dismiss", bundle: .oust).lineLimit(1)
                    }
                    .buttonStyle(OnGradientButtonStyle())
                    .fixedSize()
                    Button { trashed.sendToBin(report) } label: {
                        Label { Text("applications.uninstall", bundle: .oust) } icon: { Image(systemName: "trash") }
                            .lineLimit(1)
                    }
                    .buttonStyle(PrimaryButtonStyle(section: .applications))
                    .fixedSize()
                    .disabled(trashed.chosenItems(report).isEmpty || trashed.refreshing.contains(report.id))
                }
            }
        }
    }
}

private struct TrashedAppItems: View {
    let trashed: TrashedAppsModel
    let report: TrashedApp

    var body: some View {
        let items = trashed.items(of: report)
        let selectable = items.filter(\.isSelectable)
        let checked = selectable.filter { trashed.isChosen($0, in: report) }.count
        // L'application n'est plus là : seulement ce qu'elle a laissé.
        ItemGroup(title: L10n.string("trashed.leftovers_title"), symbol: "shippingbox",
                  tint: Palette.color(for: .applications), total: report.freeable) {
            LazyVStack(spacing: 0) {
                if selectable.count > 1 {
                    SelectAllRow(
                        state: checked == 0 ? .none : (checked == selectable.count ? .all : .some),
                        count: selectable.count,
                        tint: Palette.color(for: .applications)
                    ) { trashed.toggleAll(report) }
                    Divider().opacity(0.4)
                }
                ForEach(items) { item in
                    ItemRow(item, isSelected: trashed.isChosen(item, in: report)) { trashed.toggle(item, in: report) }
                    Divider().opacity(0.25)
                }
                if trashed.refreshing.contains(report.id) {
                    HStack(spacing: Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text("trashed.rechecking", bundle: .oust).font(Typography.caption)
                    }
                    .padding(.vertical, Spacing.small)
                }
            }
        }
    }
}
