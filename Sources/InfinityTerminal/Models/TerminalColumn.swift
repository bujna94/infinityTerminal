import Foundation

/// One visual column in the grid. Holds 1 or 2 terminal sessions.
///
/// Using a `sessions` array (rather than separate top/bottom properties) lets
/// SwiftUI's ForEach diff and move views in-place when sessions reorder,
/// which preserves the underlying NSViews and their running PTY processes.
class TerminalColumn: ObservableObject, Identifiable {
    let id = UUID()
    @Published var sessions: [TerminalSession]

    /// ID of the session currently expanded to fill the whole column (the
    /// other pane collapses to a thin restore strip). `nil` = even split.
    @Published var maximizedSessionID: UUID?

    init(sessions: [TerminalSession] = [TerminalSession(), TerminalSession()]) {
        self.sessions = sessions
    }
}
