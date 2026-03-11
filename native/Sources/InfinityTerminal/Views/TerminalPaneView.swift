import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Intercepting subclass

/// A thin subclass of `LocalProcessTerminalView` that intercepts raw bytes
/// arriving from the PTY so we can do SSH detection without interfering with
/// the normal terminal rendering pipeline.
final class InfinityTerminalNSView: LocalProcessTerminalView {

    var onDataReceived: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onDataReceived?(slice)
    }

    // Right-click context menu with Copy / Paste / Select All
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy",       action: #selector(copy(_:)),      keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste",      action: #selector(paste(_:)),     keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: ""))
        return menu
    }

    // SwiftTerm adds an NSScroller with .legacy style; switch it to .overlay so
    // it doesn't consume layout space.
    override func addSubview(_ view: NSView) {
        if let scroller = view as? NSScroller {
            scroller.scrollerStyle = .overlay
        }
        super.addSubview(view)
        if let scroller = view as? NSScroller {
            DispatchQueue.main.async {
                for c in scroller.constraints where c.firstAttribute == .width {
                    c.constant = 0
                }
                scroller.superview?.needsLayout = true
            }
        }
    }
}

// MARK: - Slot wrapper NSView

/// A thin NSView shell returned by makeNSView. It always holds exactly one
/// InfinityTerminalNSView as its subview and fills it to its own bounds.
/// By returning a *fresh* TerminalSlot from makeNSView each time SwiftUI
/// (re-)creates the representable, we avoid NSView re-parenting issues while
/// still keeping the actual PTY view alive via session.cachedTermView.
final class TerminalSlot: NSView {
    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }
}

// MARK: - SwiftUI wrapper

struct TerminalPaneView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalSlot {
        let slot = TerminalSlot(frame: .zero)
        let tv = acquireTermView(for: context)
        slot.addSubview(tv)
        return slot
    }

    func updateNSView(_ slot: TerminalSlot, context: Context) {
        guard let tv = slot.subviews.first as? InfinityTerminalNSView else { return }
        let bg = session.backgroundColor
        if tv.nativeBackgroundColor != bg {
            tv.nativeBackgroundColor = bg
            tv.layer?.backgroundColor = bg.cgColor
            tv.needsDisplay = true
        }
    }

    // MARK: - PTY view lifecycle

    /// Returns the cached live terminal view for this session, or creates a new one.
    /// The real `InfinityTerminalNSView` is stored on the session so it survives
    /// when SwiftUI destroys and re-creates the representable (e.g. left/right swap).
    private func acquireTermView(for context: Context) -> InfinityTerminalNSView {
        if let existing = session.cachedTermView as? InfinityTerminalNSView {
            // Pane moved to a different column — detach from old slot and re-wire coordinator.
            existing.removeFromSuperview()
            existing.processDelegate = context.coordinator
            context.coordinator.termView = existing
            existing.onDataReceived = makeDataHandler(coordinator: context.coordinator)
            session.restartHandler = makeRestartHandler(coordinator: context.coordinator)
            return existing
        }

        // First time — create, configure, and cache the view.
        let tv = InfinityTerminalNSView(frame: .zero)
        session.cachedTermView = tv

        tv.nativeBackgroundColor = NSColor(red: 0.059, green: 0.067, blue: 0.090, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 229.0/255.0, green: 233.0/255.0, blue: 240.0/255.0, alpha: 1.0)

        let fontSize: CGFloat = 13
        tv.font =
            NSFont(name: "Menlo", size: fontSize)
            ?? NSFont(name: "Monaco", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        tv.processDelegate = context.coordinator
        context.coordinator.termView = tv
        tv.onDataReceived = makeDataHandler(coordinator: context.coordinator)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home  = FileManager.default.homeDirectoryForCurrentUser.path
        tv.startProcess(executable: shell, args: [], environment: nil, execName: nil, currentDirectory: home)

        session.restartHandler = makeRestartHandler(coordinator: context.coordinator)
        return tv
    }

    private func makeDataHandler(coordinator: Coordinator) -> (ArraySlice<UInt8>) -> Void {
        { [weak coordinator] slice in
            guard let coordinator else { return }
            if let text = String(bytes: slice, encoding: .utf8) {
                DispatchQueue.main.async { coordinator.session.processOutput(text) }
            }
        }
    }

    private func makeRestartHandler(coordinator: Coordinator) -> () -> Void {
        { [weak coordinator] in coordinator?.restartProcess() }
    }

    // MARK: Coordinator

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var session: TerminalSession
        weak var termView: InfinityTerminalNSView?

        init(session: TerminalSession) {
            self.session = session
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                self.session.markExited(code: exitCode ?? 0)
                // Auto-restart: reopen a fresh shell in the same pane (like the X button).
                self.restartProcess()
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func restartProcess() {
            guard let tv = termView else { return }
            session.markRespawned()
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let home  = FileManager.default.homeDirectoryForCurrentUser.path
            tv.startProcess(executable: shell, args: [], environment: nil, execName: nil, currentDirectory: home)
        }
    }
}
