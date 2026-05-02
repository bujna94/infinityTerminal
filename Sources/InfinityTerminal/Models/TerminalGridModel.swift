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

    /// ID of the pane that currently has keyboard focus (used to draw the
    /// active-pane highlight).
    @Published var activeSessionID: UUID?

    /// Latest known horizontal scroll offset of the grid. Written by
    /// ContentView's scroll preference observer; read at save time and
    /// re-applied on launch. Not @Published — updates are continuous during
    /// a scroll and would re-render every observer in the model.
    var lastScrollLeft: CGFloat = 0

    /// ID of the first column created at launch / after reset — the "Home" anchor.
    private(set) var homeColumnID: UUID?

    static let fontSizeMin: CGFloat = 9
    static let fontSizeMax: CGFloat = 28

    var totalPaneCount: Int {
        columns.reduce(0) { $0 + $1.sessions.count }
    }

    init() {
        if let snapshot = Self.loadSnapshot(), restore(from: snapshot) {
            // Restored from disk.
        } else {
            reset()
        }
    }

    // MARK: - Column operations

    func addColumnLeft()  { columns.insert(TerminalColumn(), at: 0); scheduleSave() }
    func addColumnRight() { columns.append(TerminalColumn()); scheduleSave() }

    func removeColumn(at index: Int) {
        guard columns.count > 2, index < columns.count else { return }
        columns.remove(at: index)
        scheduleSave()
    }

    func reset() {
        columns = [TerminalColumn(), TerminalColumn()]
        homeColumnID = columns.first?.id
        scheduleSave()
    }
    func toggleMinimap()   { showMinimap.toggle() }
    func toggleShortcuts() { showShortcuts.toggle() }

    // MARK: - Pane operations

    /// Close a pane — always replace with a fresh session so columns keep two panes.
    func closePane(columnIndex: Int, sessionIndex: Int) {
        guard columnIndex < columns.count else { return }
        let col = columns[columnIndex]
        guard sessionIndex < col.sessions.count else { return }
        // Replacing the session object gives it a new ID → SwiftUI calls makeNSView
        // → a fresh shell process starts in the same visual slot.
        col.sessions[sessionIndex] = TerminalSession()
        scheduleSave()
    }

    /// Close the pane hosting `session`, wherever it currently lives.
    /// Exit handlers on cached NSViews are wired up once and never refreshed
    /// by `updateNSView`, so they must not rely on positional indices that
    /// become stale after a swap.
    func closePane(session: TerminalSession) {
        for col in columns {
            if let idx = col.sessions.firstIndex(where: { $0.id == session.id }) {
                col.sessions[idx] = TerminalSession()
                scheduleSave()
                return
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
        scheduleSave()
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
        scheduleSave()
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
        scheduleSave()
    }

    // MARK: - Session restore (persistence)

    private static let snapshotFilename = "session.json"
    private var saveDebounce: DispatchWorkItem?

    /// Application Support / Infinity Terminal / session.json. Persists across
    /// app updates because the system never touches user Application Support.
    private static func snapshotURL() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let dir = base.appendingPathComponent("Infinity Terminal", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    /// Project the live model into a Codable snapshot.
    func snapshot() -> GridSnapshot {
        let cols: [TerminalColumnSnapshot] = columns.map { col in
            TerminalColumnSnapshot(sessions: col.sessions.map {
                TerminalSessionSnapshot(color: ColorSnapshot($0.userBackgroundColor),
                                        cwd: $0.cwd)
            })
        }
        let homeIdx = homeColumnID.flatMap { id in
            columns.firstIndex(where: { $0.id == id })
        }
        var activeCol: Int?
        var activeSes: Int?
        if let aid = activeSessionID {
            outer: for (ci, col) in columns.enumerated() {
                for (si, s) in col.sessions.enumerated() where s.id == aid {
                    activeCol = ci; activeSes = si; break outer
                }
            }
        }
        return GridSnapshot(columns: cols,
                            homeColumnIndex: homeIdx,
                            fontSize: fontSize,
                            activeColumn: activeCol,
                            activeSession: activeSes,
                            scrollLeft: lastScrollLeft)
    }

    /// Restored scroll offset, read by ContentView once the layout is up so
    /// the user lands where they left off rather than at home.
    var pendingScrollRestore: CGFloat?

    /// Coalesce save calls — most layout changes happen in bursts (typing,
    /// dragging, etc.). 500ms is short enough to feel instant but skips the
    /// per-keystroke noise that comes from cwd updates.
    func scheduleSave() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Synchronous save — used on app quit / window close where we can't wait
    /// for the debounce.
    func saveNow() {
        saveDebounce?.cancel()
        saveDebounce = nil
        guard let url = Self.snapshotURL() else { return }
        let snap = snapshot()
        do {
            let data = try JSONEncoder().encode(snap)
            try data.write(to: url, options: .atomic)
        } catch {
            // Persistence is best-effort; never block the user on a save error.
        }
    }

    private static func loadSnapshot() -> GridSnapshot? {
        guard let url = snapshotURL(),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(GridSnapshot.self, from: data),
              snap.version == GridSnapshot.currentVersion,
              !snap.columns.isEmpty
        else { return nil }
        return snap
    }

    /// Apply a previously-saved snapshot. Returns false if the snapshot was
    /// unusable (empty / version mismatch — caller falls back to default).
    @discardableResult
    private func restore(from snap: GridSnapshot) -> Bool {
        guard !snap.columns.isEmpty else { return false }
        let restoredColumns: [TerminalColumn] = snap.columns.map { colSnap in
            TerminalColumn(sessions: colSnap.sessions.map { TerminalSession(snapshot: $0) })
        }
        self.columns = restoredColumns
        if let idx = snap.homeColumnIndex, idx < restoredColumns.count {
            self.homeColumnID = restoredColumns[idx].id
        } else {
            self.homeColumnID = restoredColumns.first?.id
        }
        if snap.fontSize >= Self.fontSizeMin && snap.fontSize <= Self.fontSizeMax {
            self.fontSize = snap.fontSize
        }
        if let ci = snap.activeColumn, let si = snap.activeSession,
           ci < restoredColumns.count, si < restoredColumns[ci].sessions.count {
            self.activeSessionID = restoredColumns[ci].sessions[si].id
        }
        if let sl = snap.scrollLeft, sl > 0 {
            self.lastScrollLeft = sl
            self.pendingScrollRestore = sl
        }
        return true
    }
}
