# Repository Guidelines

## Project Structure & Module Organization
- `Sources/InfinityTerminal/main.swift` — `NSApplication` bootstrap.
- `Sources/InfinityTerminal/Models/` — grid + session models (`TerminalGridModel`, `TerminalColumn`, `TerminalSession`).
- `Sources/InfinityTerminal/Views/` — AppKit views: `ContentView`, `ToolbarView`, `TerminalColumnView`, `TerminalPaneView`, `MinimapView`, `ShortcutsView`.
- `Sources/InfinityTerminal/Resources/` — bundled icon and logo.
- `Package.swift` — SwiftPM manifest; target depends on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
- `build-app.sh` — packaging, code signing, notarization (Hardened Runtime + Developer ID).

## Build, Test, and Development Commands
- `swift build` — debug build (`.build/debug/InfinityTerminal`).
- `swift build -c release` — release build (`.build/release/InfinityTerminal`).
- `./build-app.sh` — wrap release build into `.build/InfinityTerminal.app` (signed, ad-hoc if no Developer ID).
- `./build-app.sh --dmg` — sign + notarize + produce a DMG. Requires `APPLE_ID`, `APPLE_PASSWORD` (app-specific), `APPLE_TEAM` (env or `.env`).

## Coding Style & Naming Conventions
- Swift 5.9, target macOS 14.
- 4-space indent, trailing commas where useful, no force-unwraps in production paths.
- Naming: `PascalCase` types, `camelCase` properties / methods, `lowercase` file matches type name.
- Keep view logic in `Views/`, state in `Models/`. NSView subclasses own their resize/focus behavior; the model is the source of truth for layout.

## Testing Guidelines
- No test suite yet. When adding tests, use SwiftPM's `.testTarget(...)` in `Package.swift` and put files under `Tests/InfinityTerminalTests/`.
- Run with `swift test`.

## Commit & Pull Request Guidelines
- Commits: short imperative subject; include the bug or feature name. Conventional Commits welcome (`feat:`, `fix:`, `build:`).
- PRs: short description, screenshots for UI changes, repro steps for bugs.
- Bump `VERSION` and `BUILD_NUMBER` in `build-app.sh` when releasing.

## Security & Configuration Tips
- Code signing identity: `Developer ID Application: Pavol Bujna (334EJ7NNV2)`.
- Hardened Runtime entitlements are generated inline by `build-app.sh` (no sandbox — full PTY support requires it).
- Notarization credentials belong in `.env` (gitignored). Never commit `.env*`, `.p12`, `.p8`, or any signing artifact.
