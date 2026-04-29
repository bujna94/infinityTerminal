import SwiftUI

struct ShortcutsView: View {
    @EnvironmentObject var gridModel: TerminalGridModel

    // Modal bg: #121622
    private let modalBg = Color(red: 0.071, green: 0.086, blue: 0.133)
    // Muted: #7a8393
    private let muted = Color(red: 0.478, green: 0.514, blue: 0.576)
    // Foreground: #e5e9f0
    private let fg = Color(red: 229.0/255.0, green: 233.0/255.0, blue: 240.0/255.0)

    var body: some View {
        ZStack {
            // Semi-transparent backdrop (rgba(0,0,0,0.4)) — tap to dismiss
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    gridModel.showShortcuts = false
                }

            // Modal card — width 520 matching min(560, window-40)
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(fg)
                    Spacer()
                    Button {
                        gridModel.showShortcuts = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(muted)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 1)
                }

                // Flat shortcut list (not grouped categories — matching original)
                VStack(alignment: .leading, spacing: 0) {
                    ShortcutRow2(keys: ["⌘", "⇧", "H"],         description: "Home (scroll to first two columns)")
                    ShortcutRow2(keys: ["⌘", "⇧", "R"],         description: "Reset to original 2 columns")
                    ShortcutRow2(keys: ["⌘", "⇧", "←"],         description: "Add column to the left")
                    ShortcutRow2(keys: ["⌘", "⇧", "→"],         description: "Add column to the right")
                    ShortcutRow2(keys: ["⌘", "/"],               description: "Show this shortcuts popup")
                    ShortcutRow2(keys: ["⌘", "⇧", "M"],         description: "Toggle minimap")
                    ShortcutRow2(keys: ["⌥", "⌘", "←", "/", "→"], description: "Step a column; hold to smooth-scroll")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Footer hint
                Text("Press Esc or Cmd+/ to close")
                    .font(.system(size: 12))
                    .foregroundColor(muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 20)
            }
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(modalBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 30)
            )
        }
        // Dismiss with Escape key
        .onKeyPress(.escape) {
            gridModel.showShortcuts = false
            return .handled
        }
    }
}

// MARK: - Shortcut row

struct ShortcutRow2: View {
    let keys: [String]
    let description: String

    // Badge bg: #0f1117
    private let badgeBg = Color(red: 0.059, green: 0.067, blue: 0.090)
    // Foreground
    private let fg = Color(red: 229.0/255.0, green: 233.0/255.0, blue: 240.0/255.0)

    var body: some View {
        HStack(spacing: 12) {
            // Key badges
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(fg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            // Description
            Text(description)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }
}
