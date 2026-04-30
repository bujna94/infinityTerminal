import Foundation
import AppKit

/// Represents the logical state of one terminal pane (PTY session).
class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published var isExited: Bool = false
    @Published var exitCode: Int32 = 0

    /// User-chosen background color for this terminal pane (nil = default).
    @Published var userBackgroundColor: NSColor?

    /// Latest known working directory of the running shell. Updated via the
    /// SwiftTerm `hostCurrentDirectoryUpdate` delegate (OSC 7 / 1337). Used to
    /// re-open the pane in the same directory after a session restore.
    @Published var cwd: String?

    static let defaultBackground = NSColor(red: 0.059, green: 0.067, blue: 0.090, alpha: 1.0)

    var backgroundColor: NSColor {
        userBackgroundColor ?? Self.defaultBackground
    }

    /// Set by TerminalPaneView.makeNSView so the exit overlay can restart without
    /// holding a direct reference to the Coordinator.
    var restartHandler: (() -> Void)?

    /// Cached NSView — kept alive so the PTY is preserved when the pane moves
    /// between columns (left/right swap). Stored as NSView to avoid importing
    /// SwiftTerm here; TerminalPaneView casts it back to InfinityTerminalNSView.
    var cachedTermView: NSView?

    init() {}

    /// Initialize from a restored snapshot (color + cwd carried over from a
    /// previous launch). The PTY is started lazily by TerminalPaneView.
    init(snapshot: TerminalSessionSnapshot) {
        self.userBackgroundColor = snapshot.color?.nsColor
        self.cwd = snapshot.cwd
    }

    func markExited(code: Int32) {
        exitCode = code
        isExited = true
    }

    func markRespawned() {
        isExited = false
        exitCode = 0
    }
}
