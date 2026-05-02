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
    @EnvironmentObject var gridModel: TerminalGridModel
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
                    gridModel.scheduleSave()
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

// MARK: - Rename popover

/// Tiny popover with a single text field for setting / clearing a pane's
/// user-assigned name. Empty field clears the name (label disappears).
struct RenamePopover: View {
    @EnvironmentObject var gridModel: TerminalGridModel
    @ObservedObject var session: TerminalSession
    @Binding var isPresented: Bool
    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($focused)
                .onSubmit { commit() }
            Button("Done") { commit() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .onAppear {
            draft = session.name ?? ""
            DispatchQueue.main.async { focused = true }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        if session.name != newName {
            session.name = newName
            gridModel.scheduleSave()
        }
        isPresented = false
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
    @State private var showRename = false

    /// Height reserved for the name badge so the terminal viewport starts
    /// below it instead of having the first row hidden under the label.
    private static let nameBadgeHeight: CGFloat = 28

    private var hasName: Bool {
        if let n = session.name { return !n.isEmpty }
        return false
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TerminalPaneView(session: session,
                             fontSize: gridModel.fontSize,
                             onProcessExit: { [session, gridModel] in
                                 gridModel.closePane(session: session)
                             },
                             gridModel: gridModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, hasName ? Self.nameBadgeHeight : 0)

            if session.isExited {
                ExitOverlayView(exitCode: session.exitCode) {
                    session.restartHandler?()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // User-assigned name label, flush with the pane's top-left
            // corner. Always visible when set so the user can see which
            // terminal is which without hovering. Only the inner
            // (bottom-trailing) corner is rounded — the outer two edges
            // sit against the pane's borders.
            if let name = session.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.07, green: 0.09, blue: 0.13))
                    .clipShape(
                        .rect(cornerRadii: RectangleCornerRadii(bottomTrailing: 6))
                    )
                    .overlay(
                        UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(bottomTrailing: 6))
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }

            if isHovered || showColorPicker || showRename {
                paneControls
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: showColorPicker)
        .animation(.easeInOut(duration: 0.15), value: showRename)
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
            // Rename — first in the strip so it stays in the same place
            // regardless of which swap buttons happen to be available.
            Button(action: { showRename.toggle() }) {
                Text("✎")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(white: 0.75))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename pane")
            .popover(isPresented: $showRename, arrowEdge: .bottom) {
                RenamePopover(session: session, isPresented: $showRename)
            }

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
    @EnvironmentObject var gridModel: TerminalGridModel
    @ObservedObject var column: TerminalColumn
    let columnIndex: Int

    /// Accent color for the active-pane outline, matches toolbar/minimap.
    private static let accent = Color(red: 0.310, green: 0.451, blue: 1.0)

    /// Index (0 = top, 1 = bottom) of the active session within this column,
    /// or nil if the active pane lives somewhere else.
    private var activeIndex: Int? {
        guard let id = gridModel.activeSessionID else { return nil }
        return column.sessions.firstIndex(where: { $0.id == id })
    }

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
        // Active-pane outline. Drawn *after* the column's own right divider
        // so the accent stroke covers it (no white-then-blue seam) and
        // extended asymmetrically so it also lands on top of the *previous*
        // column's right divider on the left, and onto the inter-pane
        // horizontal divider above when the bottom pane is active.
        // No transition animation — the outline snaps to whichever pane was
        // just clicked.
        .overlay {
            GeometryReader { geo in
                if let i = activeIndex {
                    let count = max(1, column.sessions.count)
                    let h = geo.size.height / CGFloat(count)
                    let topPad: CGFloat = i > 0 ? 1 : 0
                    Rectangle()
                        .strokeBorder(Self.accent.opacity(0.3), lineWidth: 1)
                        .frame(width: geo.size.width + 1, height: h + topPad)
                        .offset(x: -1, y: CGFloat(i) * h - topPad)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
