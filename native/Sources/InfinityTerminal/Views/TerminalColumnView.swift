import SwiftUI

// MARK: - Hue wheel shape (conic gradient ring)

/// A small conic-gradient circle used as a button icon for the background color picker.
struct HueCircleIcon: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: [
                        Color(hue: 0.0,  saturation: 0.7, brightness: 0.85),
                        Color(hue: 0.17, saturation: 0.7, brightness: 0.85),
                        Color(hue: 0.33, saturation: 0.7, brightness: 0.85),
                        Color(hue: 0.5,  saturation: 0.7, brightness: 0.85),
                        Color(hue: 0.67, saturation: 0.7, brightness: 0.85),
                        Color(hue: 0.83, saturation: 0.7, brightness: 0.85),
                        Color(hue: 1.0,  saturation: 0.7, brightness: 0.85),
                    ]),
                    center: .center
                )
            )
            .frame(width: size, height: size)
    }
}

// MARK: - Hue picker popover content

struct HuePickerPopover: View {
    @ObservedObject var session: TerminalSession
    @Binding var isPresented: Bool

    // (label, applied terminal bg, bright preview for the swatch circle)
    private static let swatches: [(String, NSColor?, Color)] = [
        ("Default",  nil,
         Color(red: 0.059, green: 0.067, blue: 0.090)),
        ("Red",
         NSColor(hue: 0.0,       saturation: 0.40, brightness: 0.18, alpha: 1),
         Color(hue: 0.0,         saturation: 0.65, brightness: 0.55)),
        ("Orange",
         NSColor(hue: 30.0/360,  saturation: 0.40, brightness: 0.18, alpha: 1),
         Color(hue: 30.0/360,    saturation: 0.65, brightness: 0.55)),
        ("Yellow",
         NSColor(hue: 50.0/360,  saturation: 0.35, brightness: 0.18, alpha: 1),
         Color(hue: 50.0/360,    saturation: 0.60, brightness: 0.55)),
        ("Green",
         NSColor(hue: 120.0/360, saturation: 0.35, brightness: 0.16, alpha: 1),
         Color(hue: 120.0/360,   saturation: 0.55, brightness: 0.50)),
        ("Teal",
         NSColor(hue: 170.0/360, saturation: 0.35, brightness: 0.16, alpha: 1),
         Color(hue: 170.0/360,   saturation: 0.55, brightness: 0.50)),
        ("Cyan",
         NSColor(hue: 190.0/360, saturation: 0.35, brightness: 0.17, alpha: 1),
         Color(hue: 190.0/360,   saturation: 0.55, brightness: 0.50)),
        ("Blue",
         NSColor(hue: 220.0/360, saturation: 0.40, brightness: 0.18, alpha: 1),
         Color(hue: 220.0/360,   saturation: 0.60, brightness: 0.55)),
        ("Indigo",
         NSColor(hue: 250.0/360, saturation: 0.35, brightness: 0.18, alpha: 1),
         Color(hue: 250.0/360,   saturation: 0.55, brightness: 0.55)),
        ("Purple",
         NSColor(hue: 280.0/360, saturation: 0.35, brightness: 0.18, alpha: 1),
         Color(hue: 280.0/360,   saturation: 0.55, brightness: 0.55)),
        ("Magenta",
         NSColor(hue: 310.0/360, saturation: 0.35, brightness: 0.18, alpha: 1),
         Color(hue: 310.0/360,   saturation: 0.55, brightness: 0.55)),
        ("Rose",
         NSColor(hue: 340.0/360, saturation: 0.35, brightness: 0.18, alpha: 1),
         Color(hue: 340.0/360,   saturation: 0.60, brightness: 0.55)),
    ]

    private var currentColor: NSColor? { session.userBackgroundColor }

    var body: some View {
        let cols = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 4)
        LazyVGrid(columns: cols, spacing: 6) {
            ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                let (label, applied, preview) = swatch
                let isSelected = (applied == nil && currentColor == nil)
                    || (applied != nil && currentColor != nil
                        && abs(applied!.hueComponent - currentColor!.hueComponent) < 0.01)
                Button {
                    session.userBackgroundColor = applied
                    isPresented = false
                } label: {
                    Circle()
                        .fill(preview)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? Color.white : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .help(label)
            }
        }
        .padding(10)
    }
}

// MARK: - Exit overlay

struct ExitOverlayView: View {
    let exitCode: Int32
    let onRestart: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                Text("[process exited with code \(exitCode)]")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(white: 0.7))
                Button(action: onRestart) {
                    Text("Click or press Enter to restart")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Pane wrapper + hover controls

struct TerminalPaneWrapper: View {
    @EnvironmentObject var gridModel: TerminalGridModel
    @ObservedObject var session: TerminalSession
    let columnIndex: Int
    let sessionIndex: Int

    @State private var isHovered = false
    @State private var showColorPicker = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalPaneView(session: session, fontSize: gridModel.fontSize, onProcessExit: {
                    gridModel.closePane(columnIndex: columnIndex, sessionIndex: sessionIndex)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.isExited {
                ExitOverlayView(exitCode: session.exitCode) {
                    session.restartHandler?()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isHovered || showColorPicker {
                paneControls
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: showColorPicker)
    }

    // MARK: Control strip

    @ViewBuilder
    private var paneControls: some View {
        let col      = columnIndex < gridModel.columns.count ? gridModel.columns[columnIndex] : nil
        let canLeft  = columnIndex > 0
                    && columnIndex - 1 < gridModel.columns.count
                    && sessionIndex < gridModel.columns[columnIndex - 1].sessions.count
        let canRight = columnIndex < gridModel.columns.count - 1
                    && sessionIndex < gridModel.columns[columnIndex + 1].sessions.count
        HStack(spacing: 1) {
            if canLeft || canRight {
                ctrlBtn("⇄", help: canLeft ? "Swap with pane to the left" : "Swap with pane to the right") {
                    if canLeft { gridModel.movePaneLeft(columnIndex: columnIndex, sessionIndex: sessionIndex) }
                    else       { gridModel.movePaneRight(columnIndex: columnIndex, sessionIndex: sessionIndex) }
                }
            }
            if (col?.sessions.count ?? 0) == 2 {
                ctrlBtn("⇅", help: "Swap top / bottom") { gridModel.swapVertically(columnIndex: columnIndex) }
            }

            // Hue circle — background color picker
            Button(action: { showColorPicker.toggle() }) {
                HueCircleIcon(size: 12)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Background color")
            .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                HuePickerPopover(session: session, isPresented: $showColorPicker)
            }

            ctrlBtn("✕", help: "Close pane") {
                gridModel.closePane(columnIndex: columnIndex, sessionIndex: sessionIndex)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.93))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func ctrlBtn(_ label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: 0.75))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Column view

struct TerminalColumnView: View {
    @ObservedObject var column: TerminalColumn
    let columnIndex: Int

    var body: some View {
        VStack(spacing: 0) {
            // ForEach with stable session IDs — SwiftUI diffs and moves views
            // in-place when sessions reorder, preserving NSViews and PTY processes.
            ForEach(Array(column.sessions.enumerated()), id: \.element.id) { idx, session in
                TerminalPaneWrapper(session: session, columnIndex: columnIndex, sessionIndex: idx)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if idx < column.sessions.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.10))
                                .frame(height: 1)
                        }
                    }
            }
        }
        .background(Color(red: 0.059, green: 0.067, blue: 0.090))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1)
        }
    }
}
