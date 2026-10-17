import SwiftUI
import CinemacoreCore

/// The one sheet implementation behind every "pick one of these" moment —
/// the player's six selection panels and the Settings pickers.
///
/// The Android source had six bespoke Compose sheets; this collapses them so a
/// change to selection affordance happens once.
struct SelectionSheet<Item: Hashable>: View {
    let title: String
    let items: [Item]
    let label: (Item) -> String
    let isSelected: (Item) -> Bool
    let onSelect: (Item) -> Void
    var columns: Int = 2
    var detail: ((Item) -> String?)?
    /// Renders a leading "off" row, used by the subtitle picker.
    var noneLabel: String?
    var isNoneSelected: Bool = false
    var onSelectNone: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Layout.spacing2), count: max(1, columns))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Layout.spacing2) {
                    if let noneLabel {
                        SelectionCell(text: noneLabel, selected: isNoneSelected) {
                            onSelectNone?()
                            dismiss()
                        }
                    }
                    ForEach(items, id: \.self) { item in
                        SelectionCell(
                            text: label(item),
                            subtitle: detail?(item),
                            selected: isSelected(item)
                        ) {
                            onSelect(item)
                            dismiss()
                        }
                    }
                }
                .padding(Layout.spacing4)
            }
            .background(theme.background.color)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
    }
}

/// A single selectable cell.
struct SelectionCell: View {
    let text: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.spacing2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(Typography.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(
                            selected ? theme.accent.color : theme.textPrimary.color
                        )
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.metadata)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.accent.color)
                }
            }
            .padding(.horizontal, Layout.spacing3)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? theme.accent.color.opacity(0.16) : theme.surface.color,
                in: RoundedRectangle(cornerRadius: Layout.radiusMedium, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.radiusMedium, style: .continuous)
                    .strokeBorder(
                        selected ? theme.accent.color.opacity(0.55) : theme.separator.color,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: Layout.minimumTarget)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
