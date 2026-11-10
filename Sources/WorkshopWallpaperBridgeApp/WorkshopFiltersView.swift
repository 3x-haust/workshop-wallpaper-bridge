import SwiftUI

struct WorkshopFiltersView: View {
    @ObservedObject var model: AppViewModel
    let onApply: (WorkshopSearchFilters) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkshopSearchFilters
    @State private var expanded: Set<WorkshopSearchFilters.Category> = [.ageRating, .type]

    init(model: AppViewModel, filters: WorkshopSearchFilters, onApply: @escaping (WorkshopSearchFilters) -> Void) {
        self.model = model
        self.onApply = onApply
        _draft = State(initialValue: filters.normalized())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.L("workshop.filter.title")).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Text(String(format: model.L("workshop.filter.count"), draft.selectedCount))
                        .font(.caption.monospacedDigit()).foregroundStyle(BrowserPalette.secondary)
                }
                Text(model.L(draft.ageSummaryKey)).font(.callout).foregroundStyle(BrowserPalette.accent)
                Text(model.L("workshop.filter.selectionHelp"))
                    .font(.caption).foregroundStyle(BrowserPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach([WorkshopSearchFilters.Category.ageRating, .type, .genre, .miscellaneous, .resolution]) { category in
                        categorySection(category)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                Button(model.L("workshop.filter.reset")) { draft.reset() }
                Spacer()
                Button(model.L("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.L("workshop.filter.apply")) {
                    onApply(draft.normalized())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
        .foregroundStyle(BrowserPalette.text)
        .background(BrowserPalette.sidebar)
    }

    private func categorySection(_ category: WorkshopSearchFilters.Category) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(category) },
            set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } }
        )) {
            VStack(alignment: .leading, spacing: 9) {
                Text(model.L(category == .miscellaneous ? "workshop.filter.matchAll" : "workshop.filter.matchAny"))
                    .font(.caption).foregroundStyle(BrowserPalette.secondary)
                    .padding(.top, 6)
                ForEach(category.tags, id: \.self) { tag in
                    HStack(spacing: 10) {
                        Text(model.L(WorkshopSearchFilters.localizationKey(for: tag)))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Picker(model.L(WorkshopSearchFilters.localizationKey(for: tag)), selection: Binding(
                            get: { draft.selection(for: tag) },
                            set: { draft.setSelection($0, for: tag) }
                        )) {
                            ForEach(WorkshopSearchFilters.Selection.allCases, id: \.self) { selection in
                                Text(model.L(selection.localizationKey)).tag(selection)
                            }
                        }
                        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                        .frame(width: 190)
                    }
                }
            }
        } label: {
            HStack {
                Text(model.L(category.localizationKey)).font(.system(size: 13, weight: .semibold))
                Spacer()
                let count = category.tags.filter { draft.selection(for: $0) != .neutral }.count
                if count > 0 {
                    Text(String(format: model.L("workshop.filter.count"), count))
                        .font(.caption.monospacedDigit()).foregroundStyle(BrowserPalette.secondary)
                }
            }
        }
    }
}
