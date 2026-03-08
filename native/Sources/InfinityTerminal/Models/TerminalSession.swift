import Foundation
import AppKit

enum SSHState {
    case idle
    case pending(host: String)
    case connected(host: String)
}

/// Represents the logical state of one terminal pane (PTY session).
///
/// SSH detection works by scanning raw bytes that arrive from the PTY. When the
/// output contains an `ssh` command invocation we transition to `.pending`; once
/// we see a successful-login banner we transition to `.connected` and the pane
/// background colour changes. Detection follows the same patterns as the original
/// Electron app.
class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published var sshState: SSHState = .idle
    @Published var isExited: Bool = false
    @Published var exitCode: Int32 = 0

    var backgroundColor: NSColor {
        switch sshState {
        case .idle, .pending:
            return SSHColorizer.defaultBackground
        case .connected(let host):
            return SSHColorizer.backgroundColor(for: host)
        }
    }

    // MARK: - SSH Detection
    // Patterns match the original Electron app exactly (case-insensitive regex).

    private let sshCommandPattern = try! NSRegularExpression(
        pattern: #"ssh\s+(?:[-]\S+\s+)*(?:[^\s@]+@)?([^\s\-][^\s]*)"#,
        options: .caseInsensitive
    )

    // Compiled regex patterns matching the original JS app
    private let successRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "last login", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "welcome to", options: .caseInsensitive),
    ]
    private let failureRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "permission denied", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "could not resolve hostname", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "name or service not known", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "connection timed out", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "operation timed out", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "no route to host", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "connection refused", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "kex_exchange_identification", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "host key verification failed", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "too many authentication failures", options: .caseInsensitive),
    ]
    private let closeRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"connection to .* closed"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"shared connection to .* closed"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: "connection closed by remote host", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "connection reset by peer", options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"^logout"#, options: [.caseInsensitive, .anchorsMatchLines]),
    ]

    // MARK: - Output processing

    /// Called on the main thread with raw PTY output (already decoded to UTF-8).
    func processOutput(_ text: String) {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        // Detect an ssh command in the output stream
        if case .idle = sshState {
            if let match = sshCommandPattern.firstMatch(in: text, options: [], range: range) {
                let hostRange = match.range(at: 1)
                if hostRange.location != NSNotFound,
                   let swiftRange = Range(hostRange, in: text) {
                    let host = String(text[swiftRange])
                    sshState = .pending(host: host)
                }
            }
        }

        // State transitions based on what arrives from the remote end.
        switch sshState {
        case .pending(let host):
            if successRegexes.contains(where: { $0.firstMatch(in: text, options: [], range: range) != nil }) {
                sshState = .connected(host: host)
            } else if failureRegexes.contains(where: { $0.firstMatch(in: text, options: [], range: range) != nil }) {
                sshState = .idle
            }
        case .connected:
            if closeRegexes.contains(where: { $0.firstMatch(in: text, options: [], range: range) != nil }) {
                sshState = .idle
            }
        case .idle:
            // Check for a new SSH connection even from idle state
            if let match = sshCommandPattern.firstMatch(in: text, options: [], range: range) {
                let hostRange = match.range(at: 1)
                if hostRange.location != NSNotFound,
                   let swiftRange = Range(hostRange, in: text) {
                    let host = String(text[swiftRange])
                    sshState = .pending(host: host)
                }
            }
        }
    }

    /// Set by TerminalPaneView.makeNSView so the exit overlay can restart without
    /// holding a direct reference to the Coordinator.
    var restartHandler: (() -> Void)?

    /// Cached NSView — kept alive so the PTY is preserved when the pane moves
    /// between columns (left/right swap). Stored as NSView to avoid importing
    /// SwiftTerm here; TerminalPaneView casts it back to InfinityTerminalNSView.
    var cachedTermView: NSView?

    func markExited(code: Int32) {
        exitCode = code
        isExited = true
        sshState = .idle
    }

    func markRespawned() {
        isExited = false
        exitCode = 0
    }
}
