import Foundation

/// One visual column in the grid. Holds 1 or 2 terminal sessions.
///
/// Using a `sessions` array (rather than separate top/bottom properties) lets
/// SwiftUI's ForEach diff and move views in-place when sessions reorder,
/// which preserves the underlying NSViews and their running PTY processes.
class TerminalColumn: ObservableObject, Identifiable {
    let id = UUID()
    @Published var sessions: [TerminalSession]

    init(sessions: [TerminalSession] = [TerminalSession(), TerminalSession()]) {
        self.sessions = sessions
    }
}
