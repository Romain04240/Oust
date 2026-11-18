import AppKit
import SwiftUI
import OustDesignSystem
import OustLocalization
import OustModel

struct DuplicateExclusionsView: View {
    let model: AppModel
    @State private var invalidFolder = false
    @State private var reset = false
    @State private var invalidPaths: Set<URL> = []

    var body: some View {
        let exclusions = model.preferences.duplicateExclusions
        GlassCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("duplicates.exclusions_detail", bundle: .oust)
                        .font(Typography.caption)
                    if exclusions.isReadable {
                        ForEach(exclusions.folders) { folder in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(verbatim: (folder.url.path as NSString).abbreviatingWithTildeInPath)
                                    if invalidPaths.contains(folder.url) {
                                        Text("duplicates.exclusions_check", bundle: .oust)
                                            .font(Typography.caption)
                                    }
                                }
                                Spacer()
                                Button {
                                    Task { await model.removeDuplicateExclusion(folder.id) }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .accessibilityLabel(Text("duplicates.exclusions_remove", bundle: .oust))
                            }
                            .task(id: folder) {
                                let current = await model.checkDuplicateExclusion(folder)
                                guard !Task.isCancelled else { return }
                                if current == true { invalidPaths.remove(folder.url) }
                                else { invalidPaths.insert(folder.url) }
                            }
                        }
                        Button(action: chooseFolder) {
                            Label { Text("duplicates.exclusions_add", bundle: .oust) } icon: {
                                Image(systemName: "plus")
                            }
                        }
                    } else {
                        Button(role: .destructive) {
                            reset = true
                        } label: { Text("duplicates.exclusions_reset", bundle: .oust) }
                    }
                }
                .disabled(model.cleaning == .running || model.changingDuplicateExclusions)
                .padding(.top, Spacing.small)
            } label: {
                Text("duplicates.exclusions", bundle: .oust)
                    .font(Typography.headline)
            }
            if model.duplicateExclusionsTimedOut {
                Text("duplicates.exclusions_timeout", bundle: .oust)
                    .font(Typography.caption)
            } else if model.duplicateExclusionsWaitingForQuickLook {
                Text("duplicates.exclusions_wait_quicklook", bundle: .oust)
                    .font(Typography.caption)
            } else if !model.canUseDuplicateQuickLook {
                Text("duplicates.exclusions_preview", bundle: .oust)
                    .font(Typography.caption)
            }
            if model.duplicateExclusionBlocked || !exclusions.isReadable {
                Text("duplicates.exclusions_blocked", bundle: .oust)
                    .font(Typography.caption)
            }
        }
        .foregroundStyle(Palette.onGradient)
        .alert(Text("duplicates.exclusions_invalid", bundle: .oust), isPresented: $invalidFolder) {
            Button(role: .cancel) {} label: { Text("duplicates.exclusions_ok", bundle: .oust) }
        }
        .confirmationDialog(Text("duplicates.exclusions_reset", bundle: .oust), isPresented: $reset) {
            Button(role: .destructive) {
                Task { await model.resetUnreadableDuplicateExclusions() }
            } label: { Text("duplicates.exclusions_reset", bundle: .oust) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.resolvesAliases = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { invalidFolder = !(await model.excludeDuplicateFolder(url)) && !model.duplicateExclusionsTimedOut }
    }
}
