import AppKit
import SwiftTerm

/// SwiftTerm's `TerminalViewDelegate`, wrapped so that two things a running
/// program can ask for go through a check first. Everything else is passed
/// straight to the terminal view, which is SwiftTerm's own delegate otherwise.
///
/// - ⌘-clicked hyperlinks (OSC 8): the visible text can differ from the real
///   target. Web and mail links open directly; anything else (`file://`,
///   app URL schemes) asks first and shows the full address.
/// - Clipboard writes (OSC 52): anything printed to the terminal can carry
///   one — a file you `cat`, a remote host over SSH, a `git log`. SwiftTerm
///   1.11 on macOS drops them before they reach this delegate, so today this
///   is a safeguard: if a SwiftTerm update starts forwarding them, they're
///   accepted only from the pane you're working in.
final class TerminalGuardDelegate: TerminalViewDelegate {
    private weak var view: InfinityTerminalNSView?

    /// Programs legitimately copy whole files; this only stops absurd sizes.
    static let maxClipboardBytes = 1_000_000
    static let directSchemes: Set<String> = ["http", "https", "mailto"]

    init(view: InfinityTerminalNSView) {
        self.view = view
    }

    // MARK: Vetted

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let view, view.isFocusedPane,
              content.count <= Self.maxClipboardBytes else { return }
        view.clipboardCopy(source: source, content: content)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = Self.url(from: link), let scheme = url.scheme?.lowercased() else { return }
        if Self.directSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open this link?"
        alert.informativeText = "A program in the terminal printed a \(scheme): link. It may open a file or another app:\n\n\(url.absoluteString)"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    /// Same tolerance as SwiftTerm: accept the link as-is, or percent-encode
    /// stray characters (spaces etc.) and try again.
    static func url(from link: String) -> URL? {
        if let url = URL(string: link), url.scheme != nil { return url }
        guard let fixed = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return NSURLComponents(string: fixed)?.url
    }

    // MARK: Passed through unchanged

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        view?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        view?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        view?.scrolled(source: source, position: position)
    }

    func bell(source: TerminalView) {
        view?.bell(source: source)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        view?.iTermContent(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}
