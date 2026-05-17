import SwiftUI

/// Floating member-picker that appears above the composer when the
/// user is typing an `@<query>` token. Pure SwiftUI — the keyboard
/// path (↑/↓/Enter/Tab/Esc) is owned by `MentionTextView`, which
/// forwards events to the parent. This view renders the visual list
/// and handles mouse hover + click.
///
/// Selection background is a neutral material-aware fill rather
/// than the brand tint — pickers that adopt the brand color fight
/// the bubble tint visually and look loud on glass. Quiet selection
/// matches the macOS contextual-menu idiom.
struct MentionPicker: View {
    let suggestions: [String]
    let selectedIndex: Int
    let onSelect: (String) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, name in
                row(name: name, isSelected: index == selectedIndex)
                    .onHover { if $0 { onHover(index) } }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(name) }
            }
        }
        .padding(5)
        .frame(minWidth: 220, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: CurvyRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CurvyRadius.card, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
    }

    private func row(name: String, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            Text("@")
                .foregroundStyle(.secondary)
            Text(name)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 26)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(0.09))
            }
        }
    }
}
