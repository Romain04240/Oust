import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

/// Les mêmes couleurs pour la barre, sa légende et la jauge compacte.
func storageColor(_ category: StorageCategory) -> Color {
    switch category {
    case .applications: Color(hex: 0xF26B5B)
    case .documents: Color(hex: 0xF3BE50)
    case .images: Color(hex: 0xD86FE5)
    case .videos: Color(hex: 0x8078F4)
    case .audio: Color(hex: 0xF279AB)
    case .development: Color(hex: 0x4CC8DC)
    case .archives: Color(hex: 0x64BE8B)
    case .other: Color(hex: 0xA5ADBD)
    case .system: Color(hex: 0x74798C)
    case .purgeable: Color.white.opacity(0.45)
    case .free: Color.white.opacity(0.13)
    }
}

struct StorageChart: View {
    let parts: [StoragePart]
    let capacity: Capacity
    let date: Date?
    var showSystemDetails: (() -> Void)?
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(parts) { part in
                        Rectangle().fill(storageColor(part.category))
                            .frame(width: proxy.size.width * Double(part.bytes) / Double(max(1, capacity.total)))
                            .help(Text(verbatim: L10n.string(part.category.localizationKey) + " · " + Formatters.compactBytes(part.bytes)))
                    }
                }
                .clipShape(Capsule())
                .mask(alignment: .leading) {
                    Rectangle().scaleEffect(x: revealed || reduceMotion ? 1 : 0, y: 1, anchor: .leading)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.55), value: revealed)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: parts.map(\.bytes))
            }
            .frame(height: 18)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading,
                      spacing: Spacing.small) {
                ForEach(compact ? Array(parts.prefix(4)) : parts) { part in
                    Group {
                        if part.category == .system, let showSystemDetails {
                            Button(action: showSystemDetails) { legend(part) }
                                .buttonStyle(.plain)
                        } else { legend(part) }
                    }
                    .font(Typography.caption).foregroundStyle(Palette.onGradient)
                    .help(Text(verbatim: L10n.string(part.category.localizationKey) + " · " + Formatters.bytes(part.bytes)))
                }
            }
            if !compact, let date {
                Text(verbatim: L10n.string("storage.based_on_scan", Formatters.timestamp(date)))
                    .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
            } else if !compact {
                Text("storage.needs_scan", bundle: .oust)
                    .font(Typography.caption).foregroundStyle(Palette.onGradientSecondary)
            }
        }
        .onAppear { revealed = true }
        .onDisappear { revealed = false }
    }

    private func legend(_ part: StoragePart) -> some View {
        HStack(spacing: Spacing.tight) {
            Circle().fill(storageColor(part.category)).frame(width: 7, height: 7)
            Text(verbatim: L10n.string(part.category.localizationKey)).lineLimit(1)
            Spacer(minLength: 2)
            Text(verbatim: Formatters.compactBytes(part.bytes)).monospacedDigit().fontWeight(.semibold)
            if part.category == .system { Image(systemName: "info.circle").imageScale(.small) }
        }
    }
}
