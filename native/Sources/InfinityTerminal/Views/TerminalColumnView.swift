import SwiftUI

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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalPaneView(session: session, fontSize: gridModel.fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.isExited {
                ExitOverlayView(exitCode: session.exitCode) {
                    session.restartHandler?()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isHovered {
                paneControls
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 1)
                        }
                    }
            }
        }
        .background(Color(red: 0.059, green: 0.067, blue: 0.090))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
        }
    }
}
