import Foundation
import Combine
import SwiftUI

/// The top-level application state shared via `@EnvironmentObject`.
class TerminalGridModel: ObservableObject {
    @Published var columns: [TerminalColumn] = []
    @Published var showMinimap: Bool = false
    @Published var showShortcuts: Bool = false
    @Published var minimapHeight: CGFloat = 84
    @Published var fontSize: CGFloat = 13

    static let fontSizeMin: CGFloat = 9
    static let fontSizeMax: CGFloat = 28

    var totalPaneCount: Int {
        columns.reduce(0) { $0 + $1.sessions.count }
    }

    private var observers: [Any] = []

    init() {
        reset()
        let obs = NotificationCenter.default.addObserver(
            forName: .sessionExited, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let id = note.object as? UUID else { return }
            self.replaceSession(id: id)
        }
        observers.append(obs)
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: - Column operations

    func addColumnLeft()  { columns.insert(TerminalColumn(), at: 0) }
    func addColumnRight() { columns.append(TerminalColumn()) }

    func removeColumn(at index: Int) {
        guard columns.count > 2, index < columns.count else { return }
        columns.remove(at: index)
    }

    func reset() { columns = [TerminalColumn(), TerminalColumn()] }
    func toggleMinimap()   { showMinimap.toggle() }
    func toggleShortcuts() { showShortcuts.toggle() }

    // MARK: - Pane operations

    /// Replace an exited session with a fresh one (auto-restart on exit).
    func replaceSession(id: UUID) {
        for col in columns {
            if let idx = col.sessions.firstIndex(where: { $0.id == id }) {
                col.sessions[idx] = TerminalSession()
                return
            }
        }
    }

    /// Close a pane.
    /// ≤ 4 panes: replace with a fresh session (new process starts in the same slot).
    /// > 4 panes: remove the pane; collapse the column if it becomes empty.
    func closePane(columnIndex: Int, sessionIndex: Int) {
        guard columnIndex < columns.count else { return }
        let col = columns[columnIndex]
        guard sessionIndex < col.sessions.count else { return }

        if totalPaneCount <= 4 {
            // Replacing the session object gives it a new ID → SwiftUI calls makeNSView
            // → a fresh shell process starts in the same visual slot.
            col.sessions[sessionIndex] = TerminalSession()
            return
        }

        withAnimation(.spring(duration: 0.28)) {
            col.sessions.remove(at: sessionIndex)
            if col.sessions.isEmpty {
                columns.remove(at: columnIndex)
                while columns.count < 2 { columns.append(TerminalColumn()) }
            }
        }
    }

    /// Swap the two sessions within a column (top ↔ bottom).
    /// SwiftUI's ForEach moves views in-place, preserving NSViews and PTY processes.
    func swapVertically(columnIndex: Int) {
        guard columnIndex < columns.count,
              columns[columnIndex].sessions.count == 2 else { return }
        withAnimation(.spring(duration: 0.28)) {
            columns[columnIndex].sessions.swapAt(0, 1)
        }
    }

    /// Swap this individual pane with the same-row pane in the previous column.
    func movePaneLeft(columnIndex: Int, sessionIndex: Int) {
        guard columnIndex > 0, columnIndex < columns.count,
              sessionIndex < columns[columnIndex].sessions.count,
              sessionIndex < columns[columnIndex - 1].sessions.count else { return }
        withAnimation(.spring(duration: 0.28)) {
            let tmp = columns[columnIndex].sessions[sessionIndex]
            columns[columnIndex].sessions[sessionIndex] = columns[columnIndex - 1].sessions[sessionIndex]
            columns[columnIndex - 1].sessions[sessionIndex] = tmp
        }
    }

    /// Swap this individual pane with the same-row pane in the next column.
    func movePaneRight(columnIndex: Int, sessionIndex: Int) {
        guard columnIndex < columns.count - 1,
              sessionIndex < columns[columnIndex].sessions.count,
              sessionIndex < columns[columnIndex + 1].sessions.count else { return }
        withAnimation(.spring(duration: 0.28)) {
            let tmp = columns[columnIndex].sessions[sessionIndex]
            columns[columnIndex].sessions[sessionIndex] = columns[columnIndex + 1].sessions[sessionIndex]
            columns[columnIndex + 1].sessions[sessionIndex] = tmp
        }
    }
}
