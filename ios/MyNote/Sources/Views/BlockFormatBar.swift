import SwiftUI
import MyNoteCore

/// The formatting controls above the keyboard.
///
/// Rendered as a safe-area inset rather than `ToolbarItemGroup(placement:
/// .keyboard)`. That placement attaches to SwiftUI's *own* focused text input,
/// and the editor's field is a `UITextView` managing its own first responder —
/// so SwiftUI sees nothing focused and installs no accessory. The bar vanished
/// the moment the editor stopped using `TextField`.
///
/// An inset also keeps the whole thing in SwiftUI, so it themes itself and can
/// be driven by the same focus state as everything else.
struct BlockFormatBar: View {
    let current: BlockType
    let onSelect: (BlockType) -> Void
    let onDone: () -> Void

    @Environment(ThemeManager.self) private var theme

    /// Ordered for reach, not for the enum's sake: the things people press
    /// constantly sit nearest the left thumb.
    private static let ordered: [BlockType] = [
        .paragraph, .heading1, .heading2, .heading3,
        .bullet, .numbered, .todo, .quote, .code, .drawing, .divider,
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Self.ordered, id: \.self) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            Image(systemName: type.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 40, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(type == current
                                              ? theme.current.accentColor.opacity(0.18)
                                              : .clear)
                                )
                                .foregroundStyle(type == current
                                                 ? theme.current.accentColor
                                                 : theme.current.textSecondary)
                        }
                        .accessibilityLabel(type.label)
                        .accessibilityAddTraits(type == current ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider().frame(height: 24)

            Button("Done", action: onDone)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.current.accentColor)
                .padding(.horizontal, 14)
        }
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().overlay(theme.current.border)
        }
    }
}
