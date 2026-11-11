![Infinity Terminal](resources/appLogoWithBackground_1200x630px.png)

# Infinity Terminal — Two Rows. Endless Columns.

A native macOS terminal app: a horizontally scrolling grid of terminals,
always two rows tall and as many columns wide as you want. Run several
Claude Code sessions next to your dev server and prod shells, name and
color every pane, and swipe between them. Built with Swift / AppKit and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

![Scrolling across an Infinity Terminal window with three Claude Code sessions, logs, a system monitor, and prod and staging shells](resources/demo.gif)

## Install

Download the signed, notarized DMG from
[Releases](https://github.com/bujna94/infinityTerminal/releases/latest)
or [infinityterminal.com](https://infinityterminal.com), or use Homebrew:

```sh
brew install --cask bujna94/tap/infinity-terminal
```

Requires Apple Silicon and macOS 14 or later.

## Screenshots

![App Screenshot 1](resources/screenshot.png)
![App Screenshot 2](resources/screenshot2.png)

## Keyboard shortcuts

Press <kbd>⌘</kbd><kbd>/</kbd> in the app for the same list.

### Moving around

| Shortcut | Action |
| --- | --- |
| <kbd>⌃</kbd><kbd>⇥</kbd> | Focus the next column (wraps at the end) |
| <kbd>⌃</kbd><kbd>⇧</kbd><kbd>⇥</kbd> | Focus the previous column (wraps at the start) |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>←</kbd> / <kbd>→</kbd> | Step one column; hold to smooth-scroll |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>↓</kbd> | Focus the pane above / below |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>H</kbd> | Home — back to the first two columns |

Keyboard navigation moves keyboard focus with it, so what you type lands in the
pane you just navigated to. Scrolling with the trackpad or dragging the minimap
deliberately leaves focus alone, so peeking at another column never pulls the
cursor out of a running command.

### Layout

| Shortcut | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>←</kbd> / <kbd>→</kbd> | Add a column to the left / right |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>R</kbd> | Reset to the original two columns |
| <kbd>⌘</kbd><kbd>⇧</kbd><kbd>M</kbd> | Toggle the minimap |
| <kbd>⌘</kbd><kbd>/</kbd> | Show the shortcuts panel (<kbd>Esc</kbd> closes it) |

### Text & appearance

| Shortcut | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd>C</kbd> / <kbd>⌘</kbd><kbd>V</kbd> | Copy / paste in the focused pane |
| <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> | Copy the selection as one line (fixes long commands that Claude Code wrapped) |
| <kbd>⌥</kbd><kbd>←</kbd> / <kbd>→</kbd> | Move the cursor by word |
| <kbd>⌥</kbd><kbd>⌫</kbd> | Delete the previous word |
| <kbd>⌘</kbd><kbd>=</kbd> / <kbd>⌘</kbd><kbd>-</kbd> / <kbd>⌘</kbd><kbd>0</kbd> | Font size up / down / reset |
| <kbd>⌘</kbd><kbd>⌥</kbd><kbd>O</kbd> | Toggle Option as Meta (off = <kbd>⌥</kbd><kbd>3</kbd> types #) |

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ command line tools (`xcode-select --install`)
- A Developer ID Application certificate is only needed for signed/notarized
  builds; debug builds run unsigned.

## Build & run

```sh
swift build -c release
open .build/release/InfinityTerminal      # or run from Xcode
```

For a fully packaged, signed, and notarized DMG:

```sh
# put APPLE_ID, APPLE_PASSWORD (app-specific), APPLE_TEAM in .env
./build-app.sh --dmg
```

`build-app.sh` produces `.build/InfinityTerminal.app` (always) and
`.build/InfinityTerminal-<version>.dmg` (with `--dmg`). Notarization is
skipped if the Apple credentials aren't present.

## Project layout

- `Sources/InfinityTerminal/` — Swift sources
  - `main.swift` — `NSApplication` bootstrap
  - `Models/` — grid + session model objects
  - `Views/` — AppKit views (toolbar, columns, panes, minimap, shortcuts)
  - `Resources/` — bundled icon + logo
- `Package.swift` — SwiftPM manifest (target depends on SwiftTerm)
- `build-app.sh` — packaging / signing / notarization
- `resources/` — README screenshots and the OG image used by the website

## Releases

Tagged `v1.x.y`. To release, bump `VERSION` and `BUILD_NUMBER` in
`build-app.sh`, write the notes in `RELEASE_NOTES.md`, then push the tag:
`release.yml` builds, signs, notarizes, and publishes the GitHub release, using
`RELEASE_NOTES.md` as its body (it overwrites the notes of a release created by
hand). The `update-web.yml` workflow then propagates the notes onto
[infinityterminal.com](https://infinityterminal.com).
