import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

struct DocumentVersionHistorySheet: View {
    let document: DocumentVersionHistory
    @Environment(\.dismiss) private var dismiss
    @State private var prepared: DocumentVersionHistory.Prepared?
    @State private var preparationFinished = false
    @State private var confirmed = false
    @State private var dates: [Date?]?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("explorer.document_history.title", bundle: .oust).font(Typography.headline)
            Text(verbatim: document.name).lineLimit(2).textSelection(.enabled)
            Text("explorer.document_history.read_only", bundle: .oust).foregroundStyle(.secondary)
            if let prepared, !confirmed {
                Text(verbatim: prepared.path)
                    .font(Typography.caption)
                    .textSelection(.enabled)
                LabeledContent {
                    Text(prepared.modificationDate, format: .dateTime.year().month().day().hour().minute().second())
                } label: {
                    Text("explorer.col.modified", bundle: .oust)
                }
                LabeledContent {
                    Text(verbatim: Formatters.compactBytes(prepared.byteCount))
                } label: {
                    Text("explorer.col.size", bundle: .oust)
                }
                Button { confirmed = true } label: {
                    Text("explorer.document_history.confirm", bundle: .oust)
                }
            } else if let dates, !dates.isEmpty {
                LabeledContent {
                    Text(verbatim: Formatters.count(dates.count))
                } label: {
                    Text("explorer.document_history.count", bundle: .oust)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        ForEach(dates.indices, id: \.self) { index in
                            if let date = dates[index] {
                                Text(date, format: .dateTime.year().month().day().hour().minute().second())
                            } else {
                                Text("explorer.document_history.unknown_date", bundle: .oust)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            } else if loaded || (preparationFinished && prepared == nil) {
                Text(dates == nil ? "explorer.document_history.unavailable" : "explorer.document_history.empty",
                     bundle: .oust)
            } else {
                ProgressView()
            }
            Button { dismiss() } label: { Text("explorer.document_history.close", bundle: .oust) }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Spacing.large)
        .frame(width: 420)
        .task {
            let result = await document.prepare()
            guard !Task.isCancelled else { return }
            prepared = result
            preparationFinished = true
        }
        .task(id: confirmed) {
            guard confirmed, let prepared else { return }
            let result = await prepared.revisionDates()
            guard !Task.isCancelled else { return }
            dates = result
            loaded = true
        }
    }
}
