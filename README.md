Terminal Grid (2xN horizontally scrollable)

Overview
- Fullscreen Electron app showing a grid of terminals: always 2 rows, unlimited columns.
- Scroll horizontally with a trackpad (two-finger swipe) to navigate columns.
- Each column holds two terminals (top and bottom). Start with 2 columns (4 terminals).

Prerequisites
- macOS (works on Windows/Linux too).
- Node.js 18+ and npm.

Install
1. cd into this folder
2. npm install
3. npm run rebuild:pty   # rebuild node-pty for your Electron
4. npm start

Usage
- App launches fullscreen; toolbar at top:
  - 🏠 Home: scroll to the original two columns (keeps all terminals). Shortcut: Cmd+Shift+H (mac) or Ctrl+Shift+H (win/linux).
  - ⬅️/➡️ Add Column: keyboard shortcuts to add columns without clicking:
    - Add Left: Cmd+Shift+Left (mac) or Ctrl+Shift+Left (win/linux)
    - Add Right: Cmd+Shift+Right (mac) or Ctrl+Shift+Right (win/linux)
  - ↺ Reset: recreate the original two columns (disposes current terminals and PTYs).
  - ＋ New Column: adds another pair of terminals.
- Scroll horizontally (two-finger swipe) to move across columns.
- Each pane resizes automatically; scrollback defaults to 5,000 lines.

Notes
- The app uses @xterm/xterm for terminal rendering and node-pty for pseudo-terminal processes.
- Fit is implemented without @xterm/addon-fit to avoid peer/version issues.

Project Structure
- electron/main.js: Electron app, PTY management, IPC.
- electron/preload.js: secure bridge exposing PTY APIs to the renderer.
- src/index.html, src/styles.css: UI and layout.
- src/renderer.js: xterm.js setup, 2xN grid logic.

Customization
- Change default number of initial columns in `src/renderer.js`.
- Adjust theme/fonts in `src/renderer.js` and `src/styles.css`.

Troubleshooting
- If terminals are blank, ensure node modules installed: `npm install`.
- If Electron shows a native module mismatch for node-pty, run `npm run rebuild:pty` (it auto-detects your installed Electron version), then `npm start` again.
