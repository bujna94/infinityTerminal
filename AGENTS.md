# Repository Guidelines

## Project Structure & Module Organization
- `electron/main.js`: Electron entry; window lifecycle and PTY IPC.
- `electron/preload.js`: Safe bridge exposing `pty` and `xterm` to the renderer.
- `src/index.html`, `src/styles.css`, `src/renderer.js`: UI, layout, and 2xN terminal grid logic.
- `scripts/rebuild-pty.js`: Rebuilds `node-pty` for the installed Electron version.

## Build, Test, and Development Commands
- `npm install` — install dependencies.
- `npm run rebuild:pty` — rebuild native `node-pty` to match Electron ABI.
- `npm start` — rebuild `node-pty` if needed, then launch the app.
- `npm run dev` — launch Electron without the rebuild step (use after a successful rebuild).

## Coding Style & Naming Conventions
- Language: modern JavaScript (Node 18+/Electron).
- Indentation: 2 spaces; keep lines < 100 chars where reasonable.
- Strings: single quotes; always terminate with semicolons.
- Naming: `lowercase` filenames (use hyphens only if needed); `camelCase` for functions/variables; `PascalCase` for classes.
- Module boundaries: keep Electron (main/preload) logic separate from renderer code; add APIs via `preload` rather than enabling more renderer privileges.

## Testing Guidelines
- No test suite yet. If adding tests:
  - Unit: Vitest/Jest for pure functions; name files `*.test.js` colocated or in `__tests__/`.
  - E2E: Playwright to boot Electron and assert basic flows (window loads, terminals spawn, SSH prompt).
  - Add a `test` script in `package.json` and keep fast, deterministic tests.

## Commit & Pull Request Guidelines
- Commits: prefer Conventional Commits (e.g., `feat: add SSH prompt`, `fix(pty): resize guard`).
- PRs: include a short description, screenshots or short GIFs for UI changes, repro steps for bugs, and link related issues.
- Scope PRs narrowly; update README when behavior or commands change.

## Security & Configuration Tips
- Prefer the `preload` bridge (`window.pty`, `window.xterm`); avoid adding new `require` usage in the renderer.
- After upgrading Electron or `node-pty`, run `npm run rebuild:pty`.
- Keep `electron/main.js` IPC minimal and validate payloads (`id`, `cols`, `rows`).
