import SwiftUI

/// Search that stays a small glass magnifier until it is needed, then
/// grows into a field (Command-F). Escape or clearing it shrinks it again.
struct SearchButton: View {
    @Binding var text: String
    @State private var open = false
    @FocusState private var focused: Bool
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.bouncy(duration: 0.35)) { open = true }
                    focused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(open ? .secondary : .primary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f")
                .help("Search (\u{2318}F)")

                if open {
                    TextField("Search", text: $text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .frame(width: 150)
                        .onExitCommand { close() }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                        .help("Clear")
                    }
                }
            }
            .padding(.horizontal, open ? 10 : 8)
            .frame(height: 30)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("search", in: glass)
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && text.isEmpty { close() }
        }
        .animation(.smooth(duration: 0.25), value: text.isEmpty)
    }

    private func close() {
        text = ""
        focused = false
        withAnimation(.bouncy(duration: 0.35)) { open = false }
    }
}
