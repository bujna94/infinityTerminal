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

    /// When true, Option acts as a Meta modifier (sends ESC+<char>); when
    /// false (default) Option types the character the keyboard layout composes
    /// — e.g. ⌥3 → #. Mirrors SwiftTerm's `optionAsMetaKey`, surfaced here so
    /// it can be toggled from the UI and persisted across launches.
    @Published var useOptionAsMetaKey: Bool = false

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
    /// Persisted immediately (unlike the view-only minimap/shortcuts toggles)
    /// so the preference survives the next launch.
    func toggleOptionAsMeta() { useOptionAsMetaKey.toggle(); scheduleSave() }

    // MARK: - Pane operations

    /// Find the (column, session) index of a session by identity. Safe against
    /// stale positional indices after a swap, since it locates by ID.
    private func locate(_ session: TerminalSession) -> (column: Int, session: Int)? {
        for (ci, col) in columns.enumerated() {
            if let si = col.sessions.firstIndex(where: { $0.id == session.id }) {
                return (ci, si)
            }
        }
        return nil
    }

    /// Refresh a pane — replace its shell with a brand-new session in the same
    /// slot (a new ID → SwiftUI calls makeNSView → a fresh shell starts). This
    /// is what the "✕" button used to do; it's now the "↻" button, and it's
    /// also what a shell process exiting falls back to.
    func refreshPane(session: TerminalSession) {
        guard let loc = locate(session) else { return }
        columns[loc.column].sessions[loc.session] = TerminalSession()
        columns[loc.column].maximizedSessionID = nil
        scheduleSave()
    }

    /// Actually close a pane, removing it from its column.
    ///
    /// - A column with two panes loses the pane; the survivor grows to fill the
    ///   column (and offers ＋ strips to add a second one back).
    /// - Closing the sole pane of a column removes the whole column.
    /// - …unless it's the last pane in the grid: we keep one live terminal by
    ///   refreshing it rather than leaving an empty window.
    func closePane(session: TerminalSession) {
        guard let loc = locate(session) else { return }
        closePane(columnIndex: loc.column, sessionIndex: loc.session)
    }

    func closePane(columnIndex ci: Int, sessionIndex si: Int) {
        guard ci < columns.count else { return }
        let col = columns[ci]
        guard si < col.sessions.count else { return }

        if col.sessions.count > 1 {
            // Two panes → drop this one; the survivor fills the column.
            withAnimation(.spring(duration: 0.28)) {
                col.sessions.remove(at: si)
                col.maximizedSessionID = nil
            }
        } else if columns.count > 1 {
            // Last pane in a non-last column → remove the whole column. The
            // grid strip animates this via ContentView's columns-id animation.
            columns.remove(at: ci)
            if let hid = homeColumnID, !columns.contains(where: { $0.id == hid }) {
                homeColumnID = columns.first?.id
            }
        } else {
            // The final terminal in the grid — never leave an empty window;
            // restart it in place instead.
            col.sessions[si] = TerminalSession()
            col.maximizedSessionID = nil
        }

        // If the active pane was the one we removed, move focus to something
        // that still exists so the active-pane outline doesn't vanish.
        if let aid = activeSessionID,
           !columns.contains(where: { $0.sessions.contains { $0.id == aid } }) {
            activeSessionID = columns.first?.sessions.first?.id
        }
        scheduleSave()
    }

    /// Add a second pane back to a single-pane column, above or below the
    /// survivor. Surfaced by the ＋ strips on a sole pane.
    func addPane(columnIndex ci: Int, atTop: Bool) {
        guard ci < columns.count else { return }
        let col = columns[ci]
        guard col.sessions.count == 1 else { return }
        withAnimation(.spring(duration: 0.28)) {
            col.sessions.insert(TerminalSession(), at: atTop ? 0 : 1)
            col.maximizedSessionID = nil
        }
        scheduleSave()
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
            columns[columnIndex].maximizedSessionID = nil
            columns[columnIndex - 1].maximizedSessionID = nil
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
            columns[columnIndex].maximizedSessionID = nil
            columns[columnIndex + 1].maximizedSessionID = nil
        }
        scheduleSave()
    }

    // MARK: - Pane maximize (vertical expansion)

    /// Toggle full-column height for a pane. The other pane in the column is
    /// hidden behind a thin restore strip (its shell keeps running) until the
    /// split is restored — allowed at any time, the user decides.
    func toggleMaximize(columnIndex: Int, sessionIndex: Int) {
        guard columnIndex < columns.count else { return }
        let col = columns[columnIndex]
        guard col.sessions.count == 2, sessionIndex < col.sessions.count else { return }
        let sid = col.sessions[sessionIndex].id
        withAnimation(.spring(duration: 0.28)) {
            col.maximizedSessionID = (col.maximizedSessionID == sid) ? nil : sid
        }
        scheduleSave()
    }

    /// Restore a column to an even split.
    func clearMaximize(columnIndex: Int) {
        guard columnIndex < columns.count, columns[columnIndex].maximizedSessionID != nil else { return }
        withAnimation(.spring(duration: 0.28)) { columns[columnIndex].maximizedSessionID = nil }
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
                                        cwd: $0.cwd,
                                        name: $0.name)
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
                            scrollLeft: lastScrollLeft,
                            useOptionAsMetaKey: useOptionAsMetaKey)
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
        if let meta = snap.useOptionAsMetaKey {
            self.useOptionAsMetaKey = meta
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
