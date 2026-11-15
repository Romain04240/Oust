import SwiftUI
import OustBrowsers
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Navigateurs : cache, historique et cookies, profil par profil.
public struct BrowsersView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        SectionScaffold(.browsers, subtitle: "browsers.subtitle") {
            HStack(spacing: Spacing.small) {
                FilterMenu(filter: Binding(get: { model.filter(for: .browsers) }, set: { model.setFilter($0, for: .browsers) }))
                Button { model.refreshBrowsers() } label: { Text("browsers.refresh", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
        } content: {
            HStack {
                HeroSize(model.total(of: [.browsers], headlineOnly: false), caption: "browsers.total_caption")
                Spacer()
            }
            GlassCard(padding: Spacing.medium) {
                Label { Text("browsers.cookies_warning", bundle: .oust) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(Typography.body)
                    .foregroundStyle(Palette.onGradient)
            }
            if model.browserProfiles.isEmpty {
                EmptyState(symbol: "globe", title: "browsers.empty_title", message: "browsers.empty_detail")
            }
            HiddenByFilters(count: model.hiddenCount(in: [.browsers], section: .browsers)) {
                model.setFilter(.none, for: .browsers)
            }
            let visible = Set(model.visibleItems(in: [.browsers], section: .browsers).map(\.id))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Spacing.medium)], spacing: Spacing.medium) {
                // Un profil dont le filtre cache tout disparaît avec ses éléments.
                ForEach(model.browserProfiles.filter { profile in
                    ProfileCard.ids(of: profile).contains(where: visible.contains)
                }) { profile in
                    ProfileCard(model: model, profile: profile, visible: visible)
                }
            }
        }
        .onAppear { model.refreshBrowsers() }
    }
}

private struct ProfileCard: View {
    let model: AppModel
    let profile: BrowserProfile
    let visible: Set<String>

    static func ids(of profile: BrowserProfile) -> [String] {
        ["cache", "history", "cookies"].map { "browser.\($0)|\(profile.id)" }
    }

    var body: some View {
        let items = Self.ids(of: profile).filter(visible.contains).compactMap { model.items[$0] }
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                Image(systemName: profile.browser == .safari ? "safari" : (profile.browser == .firefox ? "flame" : "globe"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Palette.linearGradient(for: .browsers), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: profile.browser.displayName).font(Typography.headline)
                    Text(verbatim: profile.name).font(Typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let reason = items.first?.protections.first, case .appRunning = reason {
                    Tag(L10n.string("browsers.running"), symbol: "exclamationmark.circle", tint: Palette.vivid(for: .review))
                }
            }
            ForEach(items) { item in
                Toggle(isOn: Binding(get: { model.isInCart(item.id) }, set: { _ in model.toggle(item) })) {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: Describe.ruleTitle(item.ruleID)).font(Typography.body.weight(.semibold))
                            if let reason = item.protections.first, reason != .appRunning(name: profile.browser.displayName) {
                                Text(verbatim: Describe.protection(reason)).font(Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(verbatim: Formatters.compactBytes(item.sizes.freeable)).font(Typography.size).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!model.canSelectForCleanup(item))
            }
        }
        .padding(Spacing.large)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
