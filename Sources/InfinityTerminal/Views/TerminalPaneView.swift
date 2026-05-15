import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Intercepting subclass

/// A thin subclass of `LocalProcessTerminalView` that intercepts raw bytes
/// arriving from the PTY so we can do SSH detection without interfering with
/// the normal terminal rendering pipeline.
final class InfinityTerminalNSView: LocalProcessTerminalView {

    var onDataReceived: ((ArraySlice<UInt8>) -> Void)?
    /// Called on the main thread when the child shell process exits.
    var onProcessExited: (() -> Void)?
    /// Called on a background queue when a periodic cwd poll detects a
    /// change (used as a fallback for shells that don't emit OSC 7).
    var onCwdPolled: ((String) -> Void)?
    /// The session this view belongs to. Used by the global mouse event
    /// monitor in AppDelegate to update `activeSessionID` when the user
    /// clicks a pane. (LocalProcessTerminalView's becomeFirstResponder /
    /// mouseDown aren't `open`, so we can't intercept them via override.)
    var sessionID: UUID?

    private var pidMonitor: DispatchSourceProcess?
    private var cwdPollTimer: DispatchSourceTimer?
    private var lastPolledCwd: String?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // SwiftTerm's feed() pushes yDisp to yBase on every chunk, yanking the
        // viewport to the bottom even when the user has scrolled up to read
        // earlier output. We snapshot yDisp before super and, if the user was
        // scrolled up, restore it by scrolling back up by the delta. When the
        // user is already at the bottom (scrollPosition == 1) we skip this
        // and let auto-follow run as normal.
        let buffer = terminal.buffer
        let preserveScrollback = !terminal.isCurrentBufferAlternate
            && canScroll
            && scrollPosition < 1.0
        let savedYDisp = preserveScrollback ? buffer.yDisp : 0

        super.dataReceived(slice: slice)

        if preserveScrollback {
            let delta = buffer.yDisp - savedYDisp
            if delta > 0 {
                scrollUp(lines: delta)
            }
        }
        onDataReceived?(slice)
    }

    /// Start monitoring the child PID ourselves via a DispatchSource.
    /// SwiftTerm's weak-delegate chain is unreliable with SwiftUI, so we
    /// bypass it entirely and watch the PID directly.
    func monitorProcess() {
        pidMonitor?.cancel()
        pidMonitor = nil

        let pid = process.shellPid
        guard pid > 0 else { return }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.pidMonitor?.cancel()
            self?.pidMonitor = nil
            self?.onProcessExited?()
        }
        source.resume()
        pidMonitor = source

        startCwdPolling()
    }

    /// Periodically poll `proc_pidinfo` for the shell's current working
    /// directory. Apple's default zsh emits OSC 7 (handled in the SwiftTerm
    /// `hostCurrentDirectoryUpdate` delegate) so for the common case this
    /// poll is redundant. Other shells (fish, nushell, custom configs)
    /// don't emit OSC 7 — without this fallback their session restores
    /// would always reopen at $HOME instead of where the user left off.
    private func startCwdPolling() {
        cwdPollTimer?.cancel()
        let pid = process.shellPid
        guard pid > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: .seconds(30), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let cwd = Self.cwdForPid(pid), cwd != self.lastPolledCwd {
                self.lastPolledCwd = cwd
                self.onCwdPolled?(cwd)
            }
        }
        timer.resume()
        cwdPollTimer = timer
    }

    private static func cwdForPid(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let n = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, Int32(size))
        }
        guard n == Int32(size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { c in
                String(cString: c)
            }
        }
    }

    deinit {
        pidMonitor?.cancel()
        cwdPollTimer?.cancel()
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
    var fontSize: CGFloat = 13
    var onProcessExit: (() -> Void)?
    /// Passed in so the coordinator can persist cwd updates and the slot can
    /// flip the active-pane highlight on click.
    weak var gridModel: TerminalGridModel?

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, gridModel: gridModel)
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
        // Apply font size changes
        let newFont = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont(name: "Monaco", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if tv.font.pointSize != fontSize {
            tv.font = newFont
        }
    }

    // MARK: - PTY view lifecycle

    private func acquireTermView(for context: Context) -> InfinityTerminalNSView {
        if let existing = session.cachedTermView as? InfinityTerminalNSView {
            existing.removeFromSuperview()
            existing.processDelegate = context.coordinator
            existing.sessionID = session.id
            context.coordinator.termView = existing
            existing.onProcessExited = onProcessExit
            existing.onCwdPolled = { [weak coord = context.coordinator] cwd in
                DispatchQueue.main.async { coord?.applyPolledCwd(cwd) }
            }
            session.restartHandler = makeRestartHandler(coordinator: context.coordinator)
            return existing
        }

        let tv = InfinityTerminalNSView(frame: .zero)
        session.cachedTermView = tv

        // SwiftTerm's default scrollback is only 500 lines, which Claude Code
        // and other verbose tools blow past in a single response — once the
        // ring buffer trims, the absolute content under our preserved yDisp
        // shifts and the viewport appears to drift toward the bottom.
        tv.terminal.changeHistorySize(50_000)

        tv.nativeBackgroundColor = NSColor(red: 0.059, green: 0.067, blue: 0.090, alpha: 1.0)
        tv.nativeForegroundColor = NSColor(red: 229.0/255.0, green: 233.0/255.0, blue: 240.0/255.0, alpha: 1.0)

        tv.font =
            NSFont(name: "Menlo", size: fontSize)
            ?? NSFont(name: "Monaco", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        tv.processDelegate = context.coordinator
        tv.sessionID = session.id
        context.coordinator.termView = tv
        tv.onProcessExited = onProcessExit
        tv.onCwdPolled = { [weak coord = context.coordinator] cwd in
            DispatchQueue.main.async { coord?.applyPolledCwd(cwd) }
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let startDir = Self.validatedCwd(session.cwd)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        tv.startProcess(executable: shell, args: [], environment: nil, execName: nil, currentDirectory: startDir)
        tv.monitorProcess()

        session.restartHandler = makeRestartHandler(coordinator: context.coordinator)
        return tv
    }

    /// Drop a restored cwd if the directory has been deleted / unmounted
    /// since the snapshot was written. Falls back to home in the caller.
    private static func validatedCwd(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? path : nil
    }

    private func makeRestartHandler(coordinator: Coordinator) -> () -> Void {
        { [weak coordinator] in coordinator?.restartProcess() }
    }

    // MARK: Coordinator

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var session: TerminalSession
        weak var termView: InfinityTerminalNSView?
        weak var gridModel: TerminalGridModel?

        init(session: TerminalSession, gridModel: TerminalGridModel?) {
            self.session = session
            self.gridModel = gridModel
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}

        /// Fired when the shell emits OSC 7 (cwd notification). macOS's
        /// default zsh ships with this enabled, so we get cwd updates "for
        /// free" without polling lsof or proc_pidinfo.
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let dir = directory, !dir.isEmpty else { return }
            // Some shells send file:// URLs; strip the scheme.
            let path: String
            if dir.hasPrefix("file://"), let url = URL(string: dir) {
                path = url.path
            } else {
                path = dir
            }
            applyPolledCwd(path)
        }

        /// Update the session's cwd from any source (OSC 7 or the periodic
        /// proc_pidinfo poll) and schedule a session save if it changed.
        func applyPolledCwd(_ path: String) {
            guard !path.isEmpty, session.cwd != path else { return }
            session.cwd = path
            gridModel?.scheduleSave()
        }

        func restartProcess() {
            guard let tv = termView else { return }
            session.markRespawned()
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let home  = FileManager.default.homeDirectoryForCurrentUser.path
            tv.startProcess(executable: shell, args: [], environment: nil, execName: nil, currentDirectory: home)
            tv.monitorProcess()
        }
    }
}
