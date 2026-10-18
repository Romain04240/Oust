import SwiftUI
import OustCore
import OustLocalization

/// Le menu « Filtres » d'une section : classe de sécurité, âge, méthode, taille.
///
/// Un menu plutôt qu'une barre : quatre critères tiendraient mal au-dessus de
/// listes déjà riches, et on filtre rarement. Le nombre de critères posés
/// s'affiche sur le bouton, pour qu'une liste raccourcie ne passe jamais pour
/// une liste complète.
public struct FilterMenu: View {
    @Binding var filter: ItemFilter

    public init(filter: Binding<ItemFilter>) {
        self._filter = filter
    }

    static let classes = SafetyClass.allCases

    public var body: some View {
        Menu {
            Section {
                ForEach(Self.classes, id: \.self) { safety in
                    Toggle(isOn: membership(safety, in: \.safety)) {
                        Label { Text(LocalizedStringKey(safety.localizationKey), bundle: .oust) } icon: {
                            Image(systemName: Palette.symbol(for: safety))
                        }
                    }
                }
            } header: { Text("filter.safety", bundle: .oust) }

            Section {
                ForEach(MethodFamily.allCases, id: \.self) { family in
                    Toggle(isOn: membership(family, in: \.families)) {
                        Text(LocalizedStringKey(family.localizationKey), bundle: .oust)
                    }
                }
            } header: { Text("filter.method", bundle: .oust) }

            Picker(selection: $filter.age) {
                ForEach(AgeFilter.allCases, id: \.self) { age in
                    Text(LocalizedStringKey(age.localizationKey), bundle: .oust).tag(age)
                }
            } label: { Text("filter.age", bundle: .oust) }
            .pickerStyle(.menu)

            Picker(selection: $filter.size) {
                ForEach(SizeFilter.allCases, id: \.self) { size in
                    Text(LocalizedStringKey(size.localizationKey), bundle: .oust).tag(size)
                }
            } label: { Text("filter.size", bundle: .oust) }
            .pickerStyle(.menu)

            Divider()
            Button { filter = ItemFilter(query: filter.query) } label: { Text("filter.reset", bundle: .oust) }
                .disabled(filter.criteriaCount == 0)
        } label: {
            Label {
                if filter.criteriaCount > 0 {
                    Text(verbatim: L10n.string("filter.button_count", Formatters.count(filter.criteriaCount)))
                } else {
                    Text("filter.button", bundle: .oust)
                }
            } icon: {
                Image(systemName: filter.criteriaCount > 0
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
        .menuStyle(.button)
        .buttonStyle(OnGradientButtonStyle())
        .fixedSize()
    }

    /// Cocher ou décocher une valeur dans un ensemble du filtre.
    private func membership<Value: Hashable>(_ value: Value, in keyPath: WritableKeyPath<ItemFilter, Set<Value>>) -> Binding<Bool> {
        Binding(
            get: { filter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn { filter[keyPath: keyPath].insert(value) } else { filter[keyPath: keyPath].remove(value) }
            }
        )
    }
}

/// « 12 éléments masqués par les filtres », avec de quoi les retirer.
public struct HiddenByFilters: View {
    let count: Int
    let reset: () -> Void

    public init(count: Int, reset: @escaping () -> Void) {
        self.count = count
        self.reset = reset
    }

    public var body: some View {
        if count > 0 {
            HStack(spacing: Spacing.small) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                Text(verbatim: L10n.string("filter.hidden", Formatters.count(count)))
                Spacer()
                Button(action: reset) { Text("filter.reset", bundle: .oust) }
                    .buttonStyle(OnGradientButtonStyle())
            }
            .font(Typography.body.weight(.semibold))
            .foregroundStyle(Palette.onGradient)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .glassEffect(.regular.tint(.black.opacity(0.14)), in: Capsule())
        }
    }
}
