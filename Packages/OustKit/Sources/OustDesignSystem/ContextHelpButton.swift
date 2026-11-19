import SwiftUI
import OustLocalization

/// Les explications restent accessibles sans encombrer la zone de travail.
/// Les protections et les erreurs restent visibles sur l’écran concerné.
public struct ContextHelpButton: View {
    private let message: AnyView
    @State private var presented = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ key: LocalizedStringKey) {
        message = AnyView(Text(key, bundle: .oust))
    }

    public init(text: String) {
        message = AnyView(Text(verbatim: text))
    }

    public var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered && !reduceMotion ? 1.08 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text("help.more", bundle: .oust))
        .help(Text("help.more", bundle: .oust))
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack {
                    Text("help.more", bundle: .oust).font(Typography.headline)
                    Spacer()
                    Button { presented = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("help.close", bundle: .oust))
                }
                ViewThatFits(in: .vertical) {
                    message.fixedSize(horizontal: false, vertical: true)
                    ScrollView { message.fixedSize(horizontal: false, vertical: true) }
                        .frame(height: 330)
                }
                .frame(maxHeight: 330, alignment: .top)
                .font(Typography.body)
            }
            .foregroundStyle(.primary)
            .padding(Spacing.large)
            .frame(width: 340)
        }
        .onDisappear { presented = false }
    }
}
