import AppKit
import OustArchive
import OustDesignSystem
import OustLocalization
import OustModel
import SwiftUI

/// À présenter depuis Archivage ou l'Explorateur, avec le modèle partagé.
public struct TransferView: View {
  @Bindable private var model: TransferModel
  @State private var confirming = false

  public init(model: TransferModel) { self.model = model }

  public var body: some View {
    SectionScaffold(.transfer, subtitle: "transfer.explanation") {
      GlassCard {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Button {
                chooseSources()
              } label: {
                Label {
                  Text("transfer.chooseSources", bundle: .oust)
                } icon: {
                  Image(systemName: "doc.on.doc")
                }
              }
              Button {
                chooseFolder()
              } label: {
                Label {
                  Text("transfer.chooseDestination", bundle: .oust)
                } icon: {
                  Image(systemName: "externaldrive")
                }
              }
            }
            .disabled(model.isRunning || model.phase == .planning)
            ForEach(model.sources, id: \.path) { url in
              Text(verbatim: url.path).font(.caption).textSelection(.enabled)
            }
            if let folder = model.folder {
              Text("transfer.destination", bundle: .oust).font(.headline)
              Text(verbatim: folder.path).textSelection(.enabled)
            }
            if let error = model.error { Text(verbatim: error).foregroundStyle(.red) }
            if let plan = model.plan {
              Divider()
              Text(
                verbatim: L10n.string(
                  "transfer.plan", Formatters.count(plan.sources.count),
                  Formatters.bytes(plan.logicalBytes))
              )
              .monospacedDigit()
              Text("transfer.planNotice", bundle: .oust).font(.callout)
              Text("transfer.namesNotice", bundle: .oust).font(.caption).foregroundStyle(.secondary)
              if case .warning(let warning) = plan.destination.advice {
                Text(verbatim: L10n.string(warning.localizationKey)).font(.caption).foregroundStyle(
                  .orange)
              }
            }
            if model.phase == .planning {
              ProgressView { Text("transfer.planning", bundle: .oust) }
            }
            if model.isRunning {
              TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                  ProgressView()
                  Text(verbatim: phaseText)
                  Text(verbatim: L10n.string("transfer.elapsed", duration(model.elapsed()), duration(model.phaseElapsed())))
                    .font(.caption).monospacedDigit()
                  if let current = model.current { Text(verbatim: current.path).font(.caption) }
                  Text(
                    verbatim: L10n.string(
                      "transfer.copiedBytes", Formatters.bytes(model.progress.copiedBytes))
                  )
                  .monospacedDigit()
                }
              }
            }
            if model.phase == .finished { report }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          HStack {
            Spacer()
            if model.isRunning {
              Button {
                model.cancel()
              } label: {
                Text("transfer.cancel", bundle: .oust)
              }
            } else {
              if model.phase == .ready {
                Button {
                  confirming = true
                } label: {
                  Text("transfer.confirmPlan", bundle: .oust)
                }
                .buttonStyle(PrimaryButtonStyle(section: .transfer))
              } else {
                Button {
                  model.prepare()
                } label: {
                  Text("transfer.prepare", bundle: .oust)
                }
                .buttonStyle(PrimaryButtonStyle(section: .transfer)).disabled(!model.canPrepare)
              }
            }
          }
        }
        .foregroundStyle(Palette.onGradient)
      }
    }
    .confirmationDialog(
      Text("transfer.confirmTitle", bundle: .oust), isPresented: $confirming,
      titleVisibility: .visible
    ) {
      Button(role: .destructive) {
        model.startConfirmedPlan()
      } label: {
        Text("transfer.start", bundle: .oust)
      }
      Button(role: .cancel) {
      } label: {
        Text("transfer.cancel", bundle: .oust)
      }
    } message: {
      Text("transfer.confirmMessage", bundle: .oust)
    }
  }

  private var phaseText: String {
    if model.phase == .trashing { return L10n.string("transfer.trashing") }
    if model.phase == .revalidating || model.progress.isVerifying {
      return L10n.string("transfer.verifying")
    }
    return L10n.string("transfer.copying")
  }

  private func duration(_ elapsed: Duration) -> String {
    Duration.seconds(max(0, elapsed.components.seconds)).formatted(.time(pattern: .hourMinuteSecond))
  }

  private var report: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("transfer.report", bundle: .oust).font(.headline)
      Text("transfer.spaceNotice", bundle: .oust).font(.caption)
      ForEach(model.outcomes) { outcome in
        VStack(alignment: .leading, spacing: 4) {
          Label {
            Text(verbatim: outcome.source.lastPathComponent)
          } icon: {
            Image(
              systemName: outcome.completed ? "checkmark.circle.fill" : "exclamationmark.triangle")
          }
          Text(outcome.completed ? "transfer.completed" : "transfer.kept", bundle: .oust).font(
            .caption)
          if let error = outcome.error {
            Text(verbatim: TransferModel.describe(error)).font(.caption)
          }
          if let result = outcome.result, !outcome.completed {
            Text(verbatim: Describe.outcome(result)).font(.caption)
          }
          if let copy = outcome.copy { reveal(copy, key: "transfer.revealCopy") }
          if let partial = outcome.partial { reveal(partial, key: "transfer.revealPartial") }
        }
      }
    }
  }

  private func reveal(_ url: URL, key: String) -> some View {
    Button {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } label: {
      Text(verbatim: L10n.string(key))
    }
  }

  private func chooseSources() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { model.chooseSources(panel.urls) }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let folder = panel.url { model.chooseFolder(folder) }
  }
}
