import SwiftUI
import OustCore
import OustDesignSystem
import OustLocalization
import OustModel

struct AnalysisReviewView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var review: AnalysisReview
    @State private var category: ItemCategory?
    @State private var validationRequest: UUID?
    @State private var expired = false
    @State private var selectionChanged = false
    @State private var confirmation: AnalysisReview.CapacityReading?

    init(model: AppModel, review: AnalysisReview) {
        self.model = model
        _review = State(initialValue: review)
        _category = State(initialValue: review.rows.first?.category)
    }

    private var categories: [ItemCategory] {
        let present = Set(review.rows.map(\.category))
        return ItemCategory.allCases.filter { present.contains($0) }
    }

    private var checking: Bool { validationRequest != nil }

    private var isCurrent: Bool { !expired && model.analysisReview(for: review.volume)?.id == review.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("analysis_review.open", bundle: .oust).font(Typography.headline)
            Text(verbatim: review.volume.name).foregroundStyle(.secondary)
            Text("analysis_review.read_only", bundle: .oust).foregroundStyle(.secondary)

            if !isCurrent || review.rows.isEmpty {
                Text(isCurrent ? "analysis_review.empty" : "analysis_review.expired", bundle: .oust)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let confirmation {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.small) {
                        ForEach(review.selectedRows) { item in
                            itemDescription(item)
                            Divider()
                        }
                    }
                }
                if let available = confirmation.available {
                    Text(verbatim: L10n.string("analysis_review.available", Formatters.bytes(available)))
                } else {
                    Text("analysis_review.measure_unknown", bundle: .oust)
                }
                Text(verbatim: L10n.string("analysis_review.reclaimed", Formatters.bytes(confirmation.reclaimed)))
            } else {
                categorySelection
            }

            if selectionChanged && isCurrent {
                Text("analysis_review.selection_changed", bundle: .oust).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if isCurrent {
                    VStack(alignment: .leading) {
                        Text(verbatim: L10n.string("analysis_review.selected", Formatters.count(review.selection.count)))
                        Text(verbatim: L10n.string("analysis_review.estimated", Formatters.bytes(AnalysisReview.estimatedGain)))
                    }
                }
                Spacer()
                Button {
                    validationRequest = nil
                    dismiss()
                } label: { Text("analysis_review.close", bundle: .oust) }
                if checking { ProgressView().controlSize(.small) }
                if isCurrent, confirmation != nil {
                    Button { confirmation = nil } label: { Text("analysis_review.edit", bundle: .oust) }
                } else if isCurrent && !review.rows.isEmpty {
                    Button {
                        selectionChanged = false
                        validationRequest = UUID()
                    } label: { Text("analysis_review.validate", bundle: .oust) }
                        .buttonStyle(.borderedProminent)
                        .disabled(checking || review.selection.isEmpty)
                }
            }
        }
        .padding(Spacing.large)
        .frame(minWidth: 740, minHeight: 480)
        .onChange(of: model.currentAnalysisReviewIDs(for: review), initial: true) { _, ids in
            if isCurrent { updateRows(ids) } else { validationRequest = nil }
        }
        .task(id: validationRequest) { [validationRequest] in
            guard let validationRequest else { return }
            await validate(validationRequest)
        }
        .onDisappear { validationRequest = nil }
    }

    private var categorySelection: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            List(categories, id: \.self, selection: $category) { item in
                Label {
                    Text(LocalizedStringKey(item.localizationKey), bundle: .oust)
                } icon: { Image(systemName: item.symbol) }
                .tag(item)
            }
            .frame(width: 205)

            if let category {
                let group = review.rows.filter { $0.category == category }
                let count = group.filter { review.selection.contains($0.id) }.count
                VStack(alignment: .leading, spacing: Spacing.small) {
                    SelectAllRow(state: count == 0 ? .none : count == group.count ? .all : .some,
                                 count: group.count, tint: Palette.color(for: category)) {
                        review.toggleGroup(category)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.small) {
                            ForEach(group) { item in
                                Toggle(isOn: Binding(get: { review.selection.contains(item.id) },
                                                     set: { review.setSelected(item.id, $0) })) {
                                    itemDescription(item)
                                }
                                .toggleStyle(.checkbox)
                                Divider()
                            }
                        }
                        .padding(.trailing, Spacing.small)
                    }
                }
            }
        }
        .disabled(checking)
    }

    private func itemDescription(_ item: CleanupItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(verbatim: item.title).fontWeight(.medium)
            if let detail = item.detail, !detail.isEmpty {
                Text(verbatim: detail).font(Typography.caption).foregroundStyle(.secondary)
            }
            ForEach(item.protections, id: \.self) { protection in
                Text(verbatim: Describe.protection(protection)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.small)
    }

    private func updateRows(_ ids: Set<String>) {
        let previous = review.selection
        review.keepCurrentRows(ids)
        if !categories.contains(where: { $0 == category }) { category = review.rows.first?.category }
        if previous != review.selection {
            validationRequest = nil
            confirmation = nil
            selectionChanged = true
        }
    }

    private func validate(_ request: UUID) async {
        guard validationRequest == request, !Task.isCancelled else { return }
        let result = await model.validateAnalysisReview(review)
        guard validationRequest == request, !Task.isCancelled else { return }
        validationRequest = nil
        switch result {
        case .confirmed(let reading):
            confirmation = reading
        case .changed(let ids):
            updateRows(ids)
        case .unavailable:
            expired = true
        }
    }
}
