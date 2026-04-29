# Changelog

All notable changes to this project are documented here. Dates are in YYYY-MM-DD.

## 0.2.8 — 2026-04-29

- Reload shortcuts (Cmd/Ctrl+R, Cmd/Ctrl+Shift+R, F5) now show a confirmation
  dialog before resetting the window, so accidentally hitting Cmd+R while
  Infinity Terminal is focused on another screen no longer wipes open
  terminals, columns, and scrollback.

## 0.2.1 — 2025-09-15

- Added Reset shortcut: Cmd/Ctrl + Shift + R.
- Updated shortcuts modal to document the new shortcut.
- Built and published unsigned macOS arm64 DMG/ZIP artifacts.

## 0.2.0 — 2025-09-15

- Fix: Quit now exits cleanly. PTYs are terminated on quit and
  IPC sends are guarded to avoid "Object has been destroyed" errors.
- UI: Window opens normally (no forced fullscreen) and shows macOS traffic lights.
- Style: Title bar matches the dark theme; toolbar blends with the title bar.
- Layout: Toolbar avoids overlap with traffic lights using a spacer and reclaims space in fullscreen.
  Final windowed spacer width: 65px.
- Menu: Standard app menu with a working Quit item.
- Build: Unsigned macOS DMG/ZIP published (arm64).

