import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)
NSWindow.allowsAutomaticWindowTabbing = false  // suppresses "cannot index window tabs" warning

// MARK: - Window with vertically-centered traffic-light buttons
//
// Our toolbar is 38pt tall but the system's standard title bar is ~28pt, so the
// close/min/zoom buttons sit above the toolbar's vertical center. We override
// `setFrame` (called on every resize, including zoom/maximize) and shift the
// buttons down so their centers land on the toolbar's center.

final class CenteredTrafficLightWindow: NSWindow {
    /// Must match `ToolbarView`'s `.frame(height: 38)` — keep them in sync.
    static let toolbarHeight: CGFloat = 38

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        DispatchQueue.main.async { [weak self] in self?.recenterTrafficLights() }
    }

    func recenterTrafficLights() {
        let buttons: [NSButton] = [
            standardWindowButton(.closeButton),
            standardWindowButton(.miniaturizeButton),
            standardWindowButton(.zoomButton),
        ].compactMap { $0 }

        for b in buttons {
            guard let parent = b.superview else { continue }
            let h = b.frame.height
            // themeFrame is unflipped (origin bottom-left); window top is at
            // parent.bounds.height. Center the button in `toolbarHeight` from
            // the top.
            let targetY = parent.bounds.height - (Self.toolbarHeight + h) / 2
            if abs(b.frame.origin.y - targetY) > 0.5 {
                var f = b.frame
                f.origin.y = targetY
                b.frame = f
            }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    let gridModel = TerminalGridModel()
    private var monitors: [Any] = []
    /// Locked true for the entire duration of a primary-axis trackpad gesture
    /// (horizontal in horizontal mode, vertical in vertical mode) + momentum.
    private var isPrimaryAxisScroll = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupWindow()
        setupKeyboardShortcuts()
        setupScrollInterception()
        setupFocusTracking()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any pending debounced save so the very latest cwd/layout
        // makes it to disk before the PTYs are torn down by the system.
        gridModel.saveNow()
    }

    // MARK: Main menu (required for ⌘Q, ⌘H, etc.)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (Infinity Terminal)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Infinity Terminal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Infinity Terminal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Infinity Terminal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: Window

    private func setupWindow() {
        let contentView = ContentView()
            .environmentObject(gridModel)
            .ignoresSafeArea()

        window = CenteredTrafficLightWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Infinity Terminal"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.backgroundColor = NSColor(red: 0.059, green: 0.067, blue: 0.090, alpha: 1.0)


        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setFrameAutosaveName("InfinityTerminal.main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        (window as? CenteredTrafficLightWindow)?.recenterTrafficLights()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Keyboard shortcuts
    //
    // onKeyPress never fires while the terminal NSView has focus, so we
    // intercept globally here. Returning nil consumes the event.

    private func setupKeyboardShortcuts() {
        let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
        monitors.append(m!)
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let f  = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let cs: NSEvent.ModifierFlags = [.command, .shift]
        let co: NSEvent.ModifierFlags = [.command, .option]
        let ch = event.charactersIgnoringModifiers?.lowercased()

        // Escape — close shortcuts panel (onKeyPress won't fire while terminal has focus)
        if event.keyCode == 53 && gridModel.showShortcuts {
            DispatchQueue.main.async { self.gridModel.showShortcuts = false }
            return nil
        }

        if f == cs {
            switch event.keyCode {
            case 123:   // ⌘⇧← — add column left and scroll to it
                DispatchQueue.main.async {
                    self.gridModel.addColumnLeft()
                    NotificationCenter.default.post(name: .jumpToStart, object: nil)
                }
                return nil
            case 124:   // ⌘⇧→ — add column right and scroll to it
                DispatchQueue.main.async {
                    self.gridModel.addColumnRight()
                    NotificationCenter.default.post(name: .jumpToEnd, object: nil)
                }
                return nil
            default: break
            }
            switch ch {
            case "r": DispatchQueue.main.async { self.confirmAndReset() }; return nil
            case "m": DispatchQueue.main.async { self.gridModel.toggleMinimap() }; return nil
            case "h": DispatchQueue.main.async {
                NotificationCenter.default.post(name: .jumpToHome, object: nil)
            }; return nil
            default: break
            }
        }

        if f == co {
            switch event.keyCode {
            case 123:   // ⌥⌘← — step one column left
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .scrollColumnLeft, object: nil)
                }
                return nil
            case 124:   // ⌥⌘→ — step one column right
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .scrollColumnRight, object: nil)
                }
                return nil
            default: break
            }
        }

        if f == .command && ch == "/" {
            DispatchQueue.main.async { self.gridModel.toggleShortcuts() }
            return nil
        }

        // Cmd+C / Cmd+V — route through the responder chain so SwiftTerm's
        // built-in copy/paste actions fire on whichever terminal has focus.
        if f == .command {
            switch ch {
            case "c":
                NSApp.sendAction(#selector(NSText.copy(_:)),  to: nil, from: nil)
                return nil
            case "v":
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                return nil
            case "=", "+":   // ⌘= / ⌘+ — increase font size
                DispatchQueue.main.async {
                    self.gridModel.fontSize = min(self.gridModel.fontSize + 1, TerminalGridModel.fontSizeMax)
                }
                return nil
            case "-":        // ⌘- — decrease font size
                DispatchQueue.main.async {
                    self.gridModel.fontSize = max(self.gridModel.fontSize - 1, TerminalGridModel.fontSizeMin)
                }
                return nil
            case "0":        // ⌘0 — reset font size
                DispatchQueue.main.async { self.gridModel.fontSize = 13 }
                return nil
            case "r":        // ⌘R — unbound; swallow it so the user doesn't
                             // get a system "no command" beep when reaching
                             // for the browser-reload muscle memory.
                return nil
            default: break
            }
        }

        return event
    }

    // MARK: - Horizontal scroll interception
    //
    // SwiftTerm's scrollWheel is not `open` so we can't override it in a
    // subclass. Instead, intercept scroll events here: when the delta is
    // predominantly horizontal, walk the view hierarchy from the hit-tested
    // view to its nearest NSScrollView ancestor and forward the event there
    // (which is our SwiftUI ScrollView). Returning nil removes the event from
    // the terminal's input queue.

    private func setupScrollInterception() {
        let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }

            // The grid scrolls horizontally; the terminal owns vertical
            // scrollback. Forward predominantly-horizontal gestures to the grid.
            let primaryDelta   = abs(event.scrollingDeltaX)
            let secondaryDelta = abs(event.scrollingDeltaY)

            // ── Direction locking ────────────────────────────────────────────
            // Lock primary/secondary at the START of each trackpad gesture so
            // we don't flip the forwarding target mid-gesture (would jitter).
            if event.phase == .began {
                self.isPrimaryAxisScroll = primaryDelta >= secondaryDelta
            } else if event.phase == .cancelled {
                self.isPrimaryAxisScroll = false
            }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                self.isPrimaryAxisScroll = false
            }

            // For mechanical mice there is no phase info — decide per-event.
            let shouldForward: Bool
            if event.phase.isEmpty && event.momentumPhase.isEmpty {
                shouldForward = primaryDelta > secondaryDelta
            } else {
                shouldForward = self.isPrimaryAxisScroll
            }
            guard shouldForward else { return event }

            // ── Find the outermost NSScrollView ──────────────────────────────
            // Walking to the *first* ancestor might stop at SwiftTerm's own
            // internal scroll view. Keep going all the way to the root so we
            // always land on the SwiftUI horizontal ScrollView.
            let pt = event.locationInWindow
            guard let hit = self.window?.contentView?.hitTest(pt) else { return event }

            var outermost: NSScrollView?
            var v: NSView? = hit
            while let cur = v {
                if let sv = cur as? NSScrollView { outermost = sv }
                v = cur.superview
            }

            if let sv = outermost {
                sv.scrollWheel(with: event)
                return nil
            }
            return event
        }
        monitors.append(m!)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Reset confirmation
    //
    // Cmd+Shift+R wipes every open pane and overwrites the saved session, so
    // gate it behind a modal so an accidental three-key combo can't destroy
    // a working layout.

    private func confirmAndReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Infinity Terminal?"
        alert.informativeText = "This closes every open terminal and clears the saved session. Running commands (vim, npm run dev, claude, etc.) will be terminated."
        alert.addButton(withTitle: "Cancel")   // default — Return / Esc cancels
        alert.addButton(withTitle: "Reset")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { self.gridModel.reset() }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .jumpToStartInstant, object: nil)
        }
    }

    // MARK: - Active pane tracking
    //
    // LocalProcessTerminalView's mouseDown / becomeFirstResponder aren't
    // `open`, so we can't intercept them in our subclass. Instead we sit on
    // a global mouseDown monitor (same pattern as scroll interception) and
    // walk up from the hit-tested view until we find the InfinityTerminalNSView
    // — that view's `sessionID` becomes the new active pane.

    private func setupFocusTracking() {
        let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let pt = event.locationInWindow
            guard let hit = self.window?.contentView?.hitTest(pt) else { return event }
            var v: NSView? = hit
            while let cur = v {
                if let term = cur as? InfinityTerminalNSView, let sid = term.sessionID {
                    if self.gridModel.activeSessionID != sid {
                        self.gridModel.activeSessionID = sid
                        self.gridModel.scheduleSave()
                    }
                    break
                }
                v = cur.superview
            }
            return event
        }
        monitors.append(m!)
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }
}

// MARK: - Notifications

extension Notification.Name {
    static let jumpToStart        = Notification.Name("InfinityTerminal.jumpToStart")
    static let jumpToEnd          = Notification.Name("InfinityTerminal.jumpToEnd")
    static let jumpToHome         = Notification.Name("InfinityTerminal.jumpToHome")
    static let scrollColumnLeft   = Notification.Name("InfinityTerminal.scrollColumnLeft")
    static let scrollColumnRight  = Notification.Name("InfinityTerminal.scrollColumnRight")
    /// Like jumpToStart but snaps instantly via NSScrollView (used after reset).
    static let jumpToStartInstant = Notification.Name("InfinityTerminal.jumpToStartInstant")
}

// MARK: - Entry point

let delegate = AppDelegate()
app.delegate = delegate
app.run()
