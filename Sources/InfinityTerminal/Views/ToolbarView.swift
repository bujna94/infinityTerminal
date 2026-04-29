import SwiftUI
import AppKit

// MARK: - Title-bar drag + double-click-to-zoom area

/// An invisible NSView placed behind the toolbar content.
/// • `mouseDownCanMoveWindow = true`  → dragging moves the window like a real title bar
/// • Double-click                     → zooms the window (fills screen, not full-screen)
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

// MARK: - Toolbar

struct ToolbarView: View {
    @EnvironmentObject var gridModel: TerminalGridModel
    let onScrollToStart: () -> Void

    private let fg = Color(red: 229.0/255.0, green: 233.0/255.0, blue: 240.0/255.0)

    var body: some View {
        HStack(spacing: 0) {
            // Spacer clears the traffic-light buttons (zoom right edge ≈ 54pt)
            Spacer()
                .frame(width: 90)

            // Brand: appLogo.png + "Infinity Terminal"
            HStack(spacing: 8) {
                appLogoImage
                    .frame(height: 14)

                Text("Infinity Terminal")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 229.0/255.0, green: 233.0/255.0, blue: 240.0/255.0))
            }

            Spacer()

            // Hint text
            Text("Scroll left/right to add columns")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.478, green: 0.514, blue: 0.576))

            Spacer()
                .frame(width: 16)

            // Action buttons
            HStack(spacing: 6) {
                ToolbarButton(label: "🏠 Home", action: onScrollToStart)

                ToolbarButton(label: "↺ Reset") {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { gridModel.reset() }
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .jumpToStartInstant, object: nil)
                    }
                }

                ToolbarButton(
                    label: "🗺 Minimap",
                    isActive: gridModel.showMinimap
                ) {
                    gridModel.toggleMinimap()
                }

                ToolbarButton(
                    label: "⌨️ Shortcuts",
                    isActive: gridModel.showShortcuts
                ) {
                    gridModel.toggleShortcuts()
                }

                // Font size controls
                HStack(spacing: 0) {
                    Button(action: {
                        gridModel.fontSize = max(gridModel.fontSize - 1, TerminalGridModel.fontSizeMin)
                    }) {
                        Text("−")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(fg)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(gridModel.fontSize))px")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(fg)
                        .frame(width: 32)

                    Button(action: {
                        gridModel.fontSize = min(gridModel.fontSize + 1, TerminalGridModel.fontSizeMax)
                    }) {
                        Text("+")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(fg)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .frame(height: 20)
                .background(Color(red: 0.086, green: 0.102, blue: 0.141))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(.trailing, 12)
        }
        .frame(height: 38)
        .background(
            ZStack {
                Color(red: 0.059, green: 0.067, blue: 0.090).opacity(0.9)
                WindowDragArea()
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var appLogoImage: some View {
        if let url = Bundle.appResources.url(forResource: "appLogo", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "terminal.fill")
                .foregroundColor(Color(red: 0.310, green: 0.451, blue: 1.0))
                .font(.system(size: 12, weight: .semibold))
        }
    }
}

// MARK: - Toolbar button

struct ToolbarButton: View {
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private let fg      = Color(red: 229.0/255.0, green: 233.0/255.0, blue: 240.0/255.0)
    private let buttonBg = Color(red: 0.086, green: 0.102, blue: 0.141)
    private let accent   = Color(red: 0.310, green: 0.451, blue: 1.0)

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(fg)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(buttonBg)
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isActive
                                ? accent
                                : (isHovered ? accent : Color.white.opacity(0.12)),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
