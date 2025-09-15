// Renderer logic: manage 2xN horizontally scrollable terminals.
// Terminal can come from preload (window.xterm.Terminal) or classic script (window.Terminal).
let TerminalCtor = (window.xterm && window.xterm.Terminal) || window.Terminal;

const grid = document.getElementById('grid');
const homeBtn = document.getElementById('homeBtn');
const resetBtn = document.getElementById('resetBtn');
const shortcutsBtn = document.getElementById('shortcutsBtn');
const minimapBtn = document.getElementById('minimapBtn');
// overview removed
const shortcutsModal = document.getElementById('shortcutsModal');
const shortcutsOverlay = document.getElementById('shortcutsOverlay');
const shortcutsClose = document.getElementById('shortcutsClose');

function openShortcuts() {
  try { shortcutsOverlay.classList.remove('hidden'); } catch (_) {}
  try { shortcutsModal.classList.remove('hidden'); } catch (_) {}
}
function closeShortcuts() {
  try { shortcutsOverlay.classList.add('hidden'); } catch (_) {}
  try { shortcutsModal.classList.add('hidden'); } catch (_) {}
}
function isShortcutsOpen() {
  try { return !shortcutsModal.classList.contains('hidden'); } catch (_) { return false; }
}
const leftEdgeEl = document.querySelector('.edge-cell.left');
const rightEdgeEl = document.querySelector('.edge-cell.right');
const addLeftBtn = document.getElementById('addLeftCell');
const addRightBtn = document.getElementById('addRightCell');

let pty = null;
try {
  // Prefer preload bridge if available
  if (window.pty) pty = window.pty;
} catch (e) { console.error('Failed to access window.pty:', e); }
if (!pty) {
  try {
    // Fallback to direct ipcRenderer when nodeIntegration is enabled
    const { ipcRenderer } = require('electron');
    pty = {
      create: (opts) => ipcRenderer.invoke('pty:create', opts),
      write: (id, data) => ipcRenderer.send('pty:write', { id, data }),
      resize: (id, cols, rows) => ipcRenderer.send('pty:resize', { id, cols, rows }),
      kill: (id) => ipcRenderer.send('pty:kill', { id }),
      onData: (cb) => ipcRenderer.on('pty:data', (_evt, payload) => cb(payload)),
      onExit: (cb) => ipcRenderer.on('pty:exit', (_evt, payload) => cb(payload)),
    };
  } catch (e) { console.error('Failed to create IPC fallback bridge:', e); }
}

const columns = []; // [{top: TermRef, bottom: TermRef, el: HTMLElement}]
let homeLeftNode = null; // DOM node for the first created column
let homeRightNode = null; // DOM node for the second created column
let isAdding = false;
let _programmaticScroll = false; // guard to avoid feedback loops
let _lastScrollLeft = 0;
let _hideEdgeTimer = null;
let _holdDir = 0; // -1 left, 1 right
let _holdRAF = null;
let _holdLastTs = 0;
let _holdStartTs = 0;
let _lastScrollTime = (typeof performance !== 'undefined' ? performance.now() : Date.now());
let _fastScrolling = false;
let _fastOffTimer = null;
let _ovTimer = null; // overview refresh timer
let _ovInvalidateTimer = null; // coalesced refresh timer

// Host coloring for SSH sessions
const DEFAULT_BG = '#0f1117';
const hostColorMap = new Map(); // host -> color (hex)
const usedColors = new Set();
function hslToHex(h, s, l) {
  // h in [0,360), s,l in [0,1]
  s = Math.max(0, Math.min(1, s));
  l = Math.max(0, Math.min(1, l));
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hp = (h % 360) / 60;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  let r1 = 0, g1 = 0, b1 = 0;
  if (hp >= 0 && hp < 1) { r1 = c; g1 = x; }
  else if (hp < 2) { r1 = x; g1 = c; }
  else if (hp < 3) { g1 = c; b1 = x; }
  else if (hp < 4) { g1 = x; b1 = c; }
  else if (hp < 5) { r1 = x; b1 = c; }
  else { r1 = c; b1 = x; }
  const m = l - c / 2;
  const r = Math.round((r1 + m) * 255);
  const g = Math.round((g1 + m) * 255);
  const b = Math.round((b1 + m) * 255);
  const toHex = (n) => n.toString(16).padStart(2, '0');
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}
function pickColorForHost(host) {
  const key = String(host || '').trim().toLowerCase();
  if (hostColorMap.has(key)) return hostColorMap.get(key);
  // 32-bit FNV-1a hash for stable seed
  let h = 2166136261 >>> 0;
  for (let i = 0; i < key.length; i++) {
    h ^= key.charCodeAt(i);
    h = (h * 16777619) >>> 0;
  }
  // Map hash to hue, with good separation across the wheel
  let hue = h % 360;
  const saturation = 0.35; // keep dark but distinct
  const lightness = 0.17;  // dark backgrounds for contrast with light fg
  let color = hslToHex(hue, saturation, lightness);
  // Avoid rare collisions by nudging hue until we hit an unused color
  let tries = 0;
  while (usedColors.has(color) && tries < 12) {
    hue = (hue + 37) % 360; // add a prime-ish step
    color = hslToHex(hue, saturation, lightness);
    tries++;
  }
  usedColors.add(color);
  hostColorMap.set(key, color);
  return color;
}

// Single IPC listeners with per-terminal dispatch to avoid MaxListeners warnings
let listenersInitialized = false;
const dataHandlers = new Map();
const exitHandlers = new Map();
function initIpcDispatch() {
  if (listenersInitialized) return;
  try {
    const { ipcRenderer } = require('electron');
    ipcRenderer.setMaxListeners(0);
    ipcRenderer.on('pty:data', (_evt, { id, data }) => {
      const h = dataHandlers.get(id);
      if (h) h(data);
    });
    ipcRenderer.on('pty:exit', (_evt, { id, exitCode }) => {
      const h = exitHandlers.get(id);
      if (h) h(exitCode);
    });
    listenersInitialized = true;
  } catch (_) {
    // If require isn't available, we’ll rely on preload bridge (already avoids adding many listeners now)
  }
}

function ensureBridge() {
  if (!pty) {
    console.error('window.pty bridge not available');
    const warn = document.createElement('div');
    warn.textContent = 'Preload bridge missing (pty).';
    warn.style.position = 'fixed';
    warn.style.top = '50px';
    warn.style.left = '12px';
    warn.style.color = '#f66';
    document.body.appendChild(warn);
    return false;
  }
  return true;
}

function waitForXterm(maxMs = 3000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    function tick() {
      const ctor = (window.xterm && window.xterm.Terminal) || window.Terminal;
      if (ctor) return resolve(ctor);
      if (Date.now() - start > maxMs) return reject(new Error('xterm not available'));
      setTimeout(tick, 50);
    }
    tick();
  });
}


// Utility to create a terminal in a given pane element
function makeId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  return 't-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
}

function createTerminal(paneEl) {
  const Ctor = TerminalCtor || (window.xterm && window.xterm.Terminal) || window.Terminal;
  if (!Ctor) throw new Error('xterm Terminal constructor not available');
  const term = new Ctor({
    cursorBlink: true,
    scrollback: 5000,
    fontSize: 13,
    fontFamily: 'Menlo, Monaco, Consolas, monospace',
    rendererType: 'canvas',
    theme: {
      background: '#0f1117',
      foreground: '#e5e9f0',
      selectionBackground: 'rgba(79,115,255,0.25)'
    },
  });

  const id = makeId();
  const termEl = paneEl.querySelector('.term');
  term.open(termEl);
  // Ensure initial per-pane CSS var is set to default bg
  try { paneEl.style.setProperty('--term-bg', DEFAULT_BG); } catch (_) {}

  let disposed = false;
  let exited = false;
  let overlayEl = null;

  function measureCharSize(el) {
    // Create an offscreen measurer to estimate char cell size
    const measurer = document.createElement('span');
    measurer.textContent = 'MMMMMMMMMM'; // 10 chars for precision
    measurer.style.position = 'absolute';
    measurer.style.visibility = 'hidden';
    measurer.style.fontFamily = 'Menlo, Monaco, Consolas, monospace';
    measurer.style.fontSize = '13px';
    measurer.style.lineHeight = 'normal';
    el.appendChild(measurer);
    const cw = measurer.getBoundingClientRect().width / 10;
    const ch = measurer.getBoundingClientRect().height;
    el.removeChild(measurer);
    return { cw: Math.max(1, cw), ch: Math.max(1, ch) };
  }

  function fit() {
    if (disposed) return;
    const container = paneEl.getBoundingClientRect();
    const { cw, ch } = measureCharSize(paneEl);
    const cols = Math.max(2, Math.floor(container.width / cw));
    const rows = Math.max(2, Math.floor(container.height / ch));
    try { term.resize(cols, rows); } catch (_) {}
    pty.resize(id, cols, rows);
  }

  const ro = new ResizeObserver(() => fit());
  ro.observe(paneEl);

  // Register handlers in maps; single global IPC listeners dispatch here
  // Track SSH connection lifecycle to color backgrounds per host
  let currentHost = null;      // active connected host
  let pendingHost = null;      // host we are attempting to connect to
  const FAIL_PATTERNS = [
    /permission denied/i,
    /could not resolve hostname/i,
    /name or service not known/i,
    /connection timed out/i,
    /operation timed out/i,
    /no route to host/i,
    /connection refused/i,
    /kex_exchange_identification/i,
    /host key verification failed/i,
    /too many authentication failures/i,
    /ssh:\s*connect to host .* port .*:/i,
  ];
  const CLOSE_PATTERNS = [
    /connection to .* closed/i,
    /shared connection to .* closed/i,
    /connection closed by remote host/i,
    /connection reset by peer/i,
    /^logout\b/i,
  ];
  const SUCCESS_PATTERNS = [
    /last login/i,
    /welcome to/i,
  ];
  function onConnected(host) {
    currentHost = host;
    pendingHost = null;
    const color = pickColorForHost(host);
    applyBackground(color);
  }
  function onDisconnected() {
    currentHost = null;
    pendingHost = null;
    applyBackground(DEFAULT_BG);
  }
  dataHandlers.set(id, (data) => {
    term.write(data);
    try {
      if (typeof data === 'string') {
        const s = data;
        // Failure while connecting
        if (pendingHost && FAIL_PATTERNS.some(r => r.test(s))) {
          pendingHost = null;
          applyBackground(DEFAULT_BG);
        }
        // Connection closed
        if (currentHost && CLOSE_PATTERNS.some(r => r.test(s))) {
          onDisconnected();
        }
        // Success cues
        if (pendingHost && SUCCESS_PATTERNS.some(r => r.test(s))) {
          onConnected(pendingHost);
        }
      }
    } catch (_) {}
    scheduleOverviewRefresh();
  });
  exitHandlers.set(id, (exitCode) => {
    term.write(`\r\n\x1b[31m[process exited with code ${exitCode}]\x1b[0m\r\n`);
    exited = true;
    // Reset to local style
    try { applyBackground(DEFAULT_BG); currentHost = null; pendingHost = null; } catch (_) {}
    scheduleOverviewRefresh();
    showRestartOverlay(`Process exited (${exitCode}). Press Enter to restart.`);
  });

  // Capture typed lines to detect ssh commands
  let typedLine = '';
  function parseSshHostFromCommand(cmd) {
    const s = cmd.trim();
    if (!s) return null;
    const tokens = s.split(/\s+/);
    if (!tokens.length || tokens[0] !== 'ssh') return null;
    let host = null;
    for (let i = 1; i < tokens.length; i++) {
      const t = tokens[i];
      if (t.startsWith('-')) {
        if (t === '-p' && (i + 1) < tokens.length) { i++; continue; }
        continue;
      }
      // Found the destination token
      host = t.includes('@') ? t.split('@').pop() : t;
      // Strip any trailing colon or path
      host = host.replace(/:.*$/, '');
      break;
    }
    return host || null;
  }
  function applyBackground(color) {
    const theme = Object.assign({}, term.options?.theme || {}, { background: color });
    try { term.setOption('theme', theme); } catch (_) { try { term.options.theme = theme; } catch (_) {} }
    try { paneEl.style.setProperty('--term-bg', color); } catch (_) {}
  }
  term.onData((data) => {
    if (exited) {
      // Wait for Enter to restart a local shell in this pane
      if (typeof data === 'string' && (data.includes('\r') || data.includes('\n'))) {
        hideRestartOverlay();
        exited = false;
        typedLine = '';
        pendingHost = null;
        currentHost = null;
        applyBackground(DEFAULT_BG);
        runLocalShell();
      }
      return; // swallow keystrokes while exited
    }
    pty.write(id, data);
    // Build a simple editable command line buffer
    try {
      if (typeof data === 'string') {
        for (let i = 0; i < data.length; i++) {
          const ch = data[i];
          if (ch === '\r' || ch === '\n') {
            // Evaluate the command line
            const host = parseSshHostFromCommand(typedLine);
            if (host) {
              // Begin connection attempt; apply color only after strict success
              pendingHost = host;
            }
            typedLine = '';
          } else if (ch === '\u0008' || ch === '\b' || ch === '\u007f') {
            // backspace
            typedLine = typedLine.slice(0, -1);
          } else if (ch >= ' ' && ch <= '~') {
            // printable
            typedLine += ch;
          } else {
            // ignore other control codes
          }
        }
      }
    } catch (_) {}
    scheduleOverviewRefresh();
  });

  term.onResize(({ cols, rows }) => {
    pty.resize(id, cols, rows);
    scheduleOverviewRefresh();
  });

  async function runLocalShell() {
    await pty.create({ id });
    fit();
    term.focus();
    scheduleOverviewRefresh();
  }

  function focus() { term.focus(); }

  function dispose() {
    disposed = true;
    try { ro.disconnect(); } catch (_) {}
    try { pty.kill(id); } catch (_) {}
    try { term.dispose(); } catch (_) {}
    dataHandlers.delete(id);
    exitHandlers.delete(id);
  }

  function showRestartOverlay(msg) {
    try { hideRestartOverlay(); } catch (_) {}
    const ov = document.createElement('div');
    ov.textContent = msg || 'Process exited. Press Enter to restart.';
    ov.style.position = 'absolute';
    ov.style.inset = '0';
    ov.style.display = 'flex';
    ov.style.alignItems = 'center';
    ov.style.justifyContent = 'center';
    ov.style.background = 'rgba(0,0,0,0.35)';
    ov.style.color = '#e5e9f0';
    ov.style.fontSize = '13px';
    ov.style.zIndex = '2';
    ov.style.pointerEvents = 'none';
    paneEl.appendChild(ov);
    overlayEl = ov;
  }
  function hideRestartOverlay() {
    if (overlayEl && overlayEl.parentElement) overlayEl.parentElement.removeChild(overlayEl);
    overlayEl = null;
  }
  // Click to restart when exited
  paneEl.addEventListener('click', () => {
    if (!exited) return;
    hideRestartOverlay();
    exited = false;
    typedLine = '';
    pendingHost = null;
    currentHost = null;
    applyBackground(DEFAULT_BG);
    runLocalShell();
  });

  return { id, term, runLocalShell, fit, focus, dispose, pane: paneEl };
}

function createColumnNode() {
  const tpl = document.getElementById('column-template');
  const node = tpl.content.firstElementChild.cloneNode(true);
  const topRef = createTerminal(node.querySelector('.pane.top'));
  const bottomRef = createTerminal(node.querySelector('.pane.bottom'));
  topRef.runLocalShell();
  bottomRef.runLocalShell();
  return { node, top: topRef, bottom: bottomRef };
}

function addColumnRight(scrollIntoView = false) {
  const { node, top, bottom } = createColumnNode();
  grid.insertBefore(node, rightEdgeEl);
  const index = columns.push({ top, bottom, el: node }) - 1;
  if (scrollIntoView) node.scrollIntoView({ behavior: 'smooth', inline: 'end', block: 'nearest' });
  if (isMinimapOpen()) {
    try { renderOverview(); updateOverviewViewport(); updateOverviewSnapshots(); } catch (_) {}
  }
  return index;
}

function addColumnLeft() {
  const { node, top, bottom } = createColumnNode();
  grid.insertBefore(node, leftEdgeEl.nextSibling);
  // Keep viewport stable after prepending
  // Do not nudge scrollLeft so the left + remains visible when revealed
  columns.unshift({ top, bottom, el: node });
  if (isMinimapOpen()) {
    try { renderOverview(); updateOverviewViewport(); updateOverviewSnapshots(); } catch (_) {}
  }
  return 0;
}

function columnWidth() {
  const first = grid.querySelector('.column');
  return (first && first.offsetWidth) || Math.max(1, Math.floor(grid.clientWidth / 2));
}

function currentRightVisibleIndex() {
  const w = columnWidth();
  if (!w) return null;
  const offset = (leftEdgeEl && leftEdgeEl.offsetWidth) || 0;
  const start = Math.floor(Math.max(0, grid.scrollLeft - offset) / w);
  const perView = Math.max(1, Math.round(grid.clientWidth / w));
  const right = Math.min(columns.length - 1, start + perView - 1);
  return isFinite(right) ? right : null;
}

function updateEdgeCellsVisibility() { /* no-op: edges always visible */ }

function waitForPty(maxMs = 3000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    function tick() {
      if (!pty && window.pty) {
        pty = window.pty;
      }
      if (pty) return resolve(true);
      if (Date.now() - start > maxMs) return reject(new Error('pty bridge not available'));
      setTimeout(tick, 50);
    }
    tick();
  });
}

// Initialize with two columns (4 terminals)
document.addEventListener('DOMContentLoaded', async () => {
  try {
    await waitForPty(4000);
  } catch (e) {
    ensureBridge();
    return;
  }
  try {
    TerminalCtor = await waitForXterm(4000);
    // Seed with two visible columns (four terminals) and mark as Home
    const idx1 = addColumnRight(false);
    const idx2 = addColumnRight(false);
    homeLeftNode = columns[idx1]?.el || null;
    homeRightNode = columns[idx2]?.el || null;
    // Hide left edge by default so + is off-screen initially
    try {
      grid.scrollLeft = (leftEdgeEl?.offsetWidth || 0);
      _lastScrollLeft = grid.scrollLeft;
      _lastScrollTime = (typeof performance !== 'undefined' ? performance.now() : Date.now());
    } catch (_) {}
    updateEdgeSnapState();
    // Prepare overview minimap (start when toggled visible)
    try { initOverviewInteractions(); } catch (_) {}
    // Edge cell buttons
    addLeftBtn.addEventListener('click', () => {
      // Add to the left and keep the + off-screen after creation
      addColumnLeft();
      try { renderOverview(); updateOverviewViewport(); } catch (_) {}
      updateEdgeSnapState();
    });
    addRightBtn.addEventListener('click', () => {
      // Add to the right, then ensure the right + hides just outside the last column
      addColumnRight(true);
      hideRightEdge(false);
      try { renderOverview(); updateOverviewViewport(); } catch (_) {}
      updateEdgeSnapState();
    });
    // Toolbar Home button
    if (homeBtn) homeBtn.addEventListener('click', () => { scrollHome(true); });
    // Toolbar Reset button
    if (resetBtn) resetBtn.addEventListener('click', () => { resetToHome(true); });
    if (shortcutsBtn) shortcutsBtn.addEventListener('click', openShortcuts);
    if (minimapBtn) minimapBtn.addEventListener('click', () => { toggleMinimap(); });
    if (shortcutsOverlay) shortcutsOverlay.addEventListener('click', closeShortcuts);
    if (shortcutsClose) shortcutsClose.addEventListener('click', closeShortcuts);
    window.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeShortcuts(); }, { capture: true });
    // Overview button removed
    initIpcDispatch();
  } catch (e) {
    console.error('Failed to initialize xterm:', e);
    const warn = document.createElement('div');
    warn.textContent = 'Failed to load xterm. Check scripts/preload.';
    warn.style.position = 'fixed';
    warn.style.top = '50px';
    warn.style.left = '12px';
    warn.style.color = '#f66';
    document.body.appendChild(warn);
  }
});

// Trackpad horizontal scrolling works by default via overflow-x: auto.
// Ensure full-screen columns refit on window resize
window.addEventListener('resize', () => {
  for (const col of columns) { col.top.fit(); col.bottom.fit(); }
  updateEdgeSnapState();
  if (isMinimapOpen()) { try { renderOverview(); updateOverviewViewport(); } catch (_) {} }
});

// Home: scroll back to the initially created two columns
function scrollHome(_smooth = false) {
  const leftEdge = (leftEdgeEl?.offsetWidth || 0);
  const w = columnWidth();
  let idx = columns.findIndex(c => c.el === homeLeftNode);
  if (idx < 0) idx = 0;
  const target = Math.max(0, leftEdge + (idx * w));
  _programmaticScroll = true;
  try { grid.classList.add('no-snap'); } catch (_) {}
  try { grid.scrollTo({ left: target, behavior: 'auto' }); }
  catch (_) { grid.scrollLeft = target; }
  _lastScrollLeft = target;
  setTimeout(() => { _programmaticScroll = false; updateEdgeSnapState(); }, 50);
}

// Reset to Home: dispose all and recreate the two original columns, update home anchors
function resetToHome(scrollToStart = false) {
  try {
    for (const col of columns) {
      try { col.top.dispose(); } catch (_) {}
      try { col.bottom.dispose(); } catch (_) {}
      try { col.el.remove(); } catch (_) {}
    }
  } finally {
    columns.length = 0;
  }
  if (scrollToStart) {
    try { grid.scrollLeft = 0; _lastScrollLeft = grid.scrollLeft; } catch (_) {}
  }
  const idx1 = addColumnRight(false);
  const idx2 = addColumnRight(false);
  homeLeftNode = columns[idx1]?.el || null;
  homeRightNode = columns[idx2]?.el || null;
  if (isMinimapOpen()) { try { renderOverview(); updateOverviewViewport(); } catch (_) {} }
  if (scrollToStart && homeLeftNode && homeLeftNode.isConnected) {
    try { homeLeftNode.scrollIntoView({ behavior: 'auto', inline: 'start', block: 'nearest' }); _lastScrollLeft = grid.scrollLeft; } catch (_) {}
  }
}

// Keyboard shortcut: Home (Command+Shift+H on macOS, Ctrl+Shift+H elsewhere)
(() => {
  const isMac = (window.platform && window.platform.isMac) ||
                (typeof process !== 'undefined' && process.platform === 'darwin');
  window.addEventListener('keydown', (e) => {
    const t = e.target;
    const isXtermTextarea = !!(t && t.tagName === 'TEXTAREA' && t.classList && t.classList.contains('xterm-helper-textarea'));
    const inEditable = !isXtermTextarea && !!(t && (
      t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable === true
    ));
    if (inEditable) return; // allow global shortcuts when focused in xterm's helper textarea
    // Toggle Shortcuts: Cmd/Ctrl + / (accepts '?' or '/' key)
    const modSlash = (isMac ? e.metaKey : e.ctrlKey) && (e.key === '/' || e.key === '?');
    if (modSlash) {
      e.preventDefault();
      if (isShortcutsOpen()) closeShortcuts(); else openShortcuts();
      return;
    }
    // Toggle Minimap: Cmd/Ctrl + Shift + M
    const modMinimap = (isMac ? e.metaKey : e.ctrlKey) && e.shiftKey && (e.key === 'm' || e.key === 'M');
    if (modMinimap) {
      e.preventDefault();
      toggleMinimap();
      return;
    }

    // Toggle Overview popup: Cmd/Ctrl + Shift + V
    // Overview shortcut removed

    // Add Column shortcuts
    const mod = isMac ? e.metaKey : e.ctrlKey;
    const addLeftCombo = mod && e.shiftKey && e.key === 'ArrowLeft';
    const addRightCombo = mod && e.shiftKey && e.key === 'ArrowRight';
    if (addLeftCombo) {
      e.preventDefault();
      addColumnLeft();
      hideLeftEdge(false);
      return;
    }
    if (addRightCombo) {
      e.preventDefault();
      addColumnRight(true);
      hideRightEdge(false);
      return;
    }
    // Shift+Arrow: no-op (reserved for selection). Navigation uses Option+Command+Arrow on macOS.

    // macOS: Option+Command+Left/Right navigation
    if (isMac && e.metaKey && e.altKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
      e.preventDefault();
      const dir = (e.key === 'ArrowRight') ? 1 : -1;
      if (!e.repeat) {
        // Single press: move exactly one column, do not start holding yet
        scrollByColumns(dir);
        stopHoldScroll();
      } else {
        // On key repeat while still holding, start/continue smooth scrolling
        startHoldScroll(dir);
      }
      return;
    }
    // Home shortcut
    const hKey = e.key === 'h' || e.key === 'H';
    const homeCombo = isMac ? (e.metaKey && e.shiftKey && hKey) : (e.ctrlKey && e.shiftKey && hKey);
    if (homeCombo) {
      e.preventDefault();
      scrollHome(true);
    }
  }, { capture: true });
  window.addEventListener('keyup', (e) => {
    // Stop hold scroll when releasing any relevant key
    if (e.key === 'Meta' || e.key === 'Alt' || e.key === 'Option' || e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      stopHoldScroll();
    }
  }, { capture: true });
})();

function startHoldScroll(dir) {
  _holdDir = dir;
  if (_holdRAF) return;
  _programmaticScroll = true;
  _holdLastTs = (typeof performance !== 'undefined' ? performance.now() : Date.now());
  _holdStartTs = _holdLastTs;
  const step = (ts) => {
    if (_holdDir === 0) { _holdRAF = null; return; }
    const now = ts || (typeof performance !== 'undefined' ? performance.now() : Date.now());
    const dt = Math.max(1, now - _holdLastTs);
    _holdLastTs = now;
    // Ramp speed: 1200 -> 2600 px/sec over ~350ms (ease-out)
    const elapsed = Math.max(0, now - _holdStartTs);
    const t = Math.min(1, elapsed / 350);
    const easeOut = t * (2 - t); // quadratic ease-out
    const speedPps = 1200 + (2600 - 1200) * easeOut; // pixels per second
    const deltaPx = _holdDir * speedPps * (dt / 1000);
    const maxLeft = Math.max(0, grid.scrollWidth - grid.clientWidth);
    let target = Math.max(0, Math.min(grid.scrollLeft + deltaPx, maxLeft));
    try { grid.scrollLeft = target; } catch (_) { /* no-op */ }
    _lastScrollLeft = grid.scrollLeft;
    _holdRAF = requestAnimationFrame(step);
  };
  _holdRAF = requestAnimationFrame(step);
}

function stopHoldScroll() {
  _holdDir = 0;
  if (_holdRAF) { cancelAnimationFrame(_holdRAF); _holdRAF = null; }
  _programmaticScroll = false;
}

function hideRightEdge(smooth = false) {
  const behavior = smooth ? 'smooth' : 'auto';
  const rightEdge = (rightEdgeEl?.offsetWidth || 0);
  const target = Math.max(0, grid.scrollWidth - grid.clientWidth - rightEdge);
  _programmaticScroll = true;
  try { grid.scrollTo({ left: target, behavior }); } catch (_) { grid.scrollLeft = target; }
  setTimeout(() => { _programmaticScroll = false; updateEdgeSnapState(); }, 120);
  updateEdgeSnapState();
}

function hideLeftEdge(smooth = false) {
  const behavior = smooth ? 'smooth' : 'auto';
  const leftEdge = (leftEdgeEl?.offsetWidth || 0);
  const target = Math.max(0, leftEdge);
  _programmaticScroll = true;
  try { grid.scrollTo({ left: target, behavior }); } catch (_) { grid.scrollLeft = target; }
  setTimeout(() => { _programmaticScroll = false; updateEdgeSnapState(); }, 120);
  updateEdgeSnapState();
}

function scrollByColumns(delta) {
  const leftEdge = (leftEdgeEl?.offsetWidth || 0);
  const w = columnWidth();
  const maxLeft = Math.max(0, grid.scrollWidth - grid.clientWidth);
  const current = grid.scrollLeft;
  const idx = Math.round(Math.max(0, (current - leftEdge)) / Math.max(1, w));
  const targetIdx = Math.max(0, Math.min(columns.length - 1, idx + delta));
  let target = leftEdge + targetIdx * w;
  target = Math.max(0, Math.min(target, maxLeft));
  _programmaticScroll = true;
  try { grid.scrollTo({ left: target, behavior: 'smooth' }); } catch (_) { grid.scrollLeft = target; }
  setTimeout(() => { _programmaticScroll = false; _lastScrollLeft = grid.scrollLeft; }, 160);
}

// Overview strip support
const overview = document.getElementById('overview');
const ovTrack = document.getElementById('overviewTrack');
const ovViewport = document.getElementById('overviewViewport');
const ovResizer = document.getElementById('overviewResizer');

function isMinimapOpen() {
  try { return document.body.classList.contains('minimap-open'); } catch (_) { return false; }
}
function openMinimap() {
  try { document.body.classList.add('minimap-open'); } catch (_) {}
  try { renderOverview(); updateOverviewViewport(); updateOverviewSnapshots(); } catch (_) {}
  startOverviewLoop();
}
function closeMinimap() {
  try { document.body.classList.remove('minimap-open'); } catch (_) {}
  stopOverviewLoop();
}
function toggleMinimap() { if (isMinimapOpen()) closeMinimap(); else openMinimap(); }

// Minimap vertical resize handling
let _ovResizeActive = false;
let _ovResizePendingH = null;
let _ovResizeRAF = null;
function setMinimapHeight(px) {
  const h = Math.round(px);
  document.documentElement.style.setProperty('--overview-h', h + 'px');
  try { updateOverviewViewport(); updateOverviewSnapshots(); } catch (_) {}
}
function startResizeAt(clientY) {
  _ovResizeActive = true;
  document.body.style.cursor = 'ns-resize';
}
function onResizeMove(clientY) {
  if (!_ovResizeActive) return;
  const winH = window.innerHeight || document.documentElement.clientHeight;
  let newH = Math.max(40, Math.min(Math.floor(winH * 0.66), Math.floor(winH - clientY))); // clamp 40px..66% of window
  _ovResizePendingH = newH;
  if (_ovResizeRAF) return;
  _ovResizeRAF = requestAnimationFrame(() => {
    _ovResizeRAF = null;
    if (_ovResizePendingH != null) setMinimapHeight(_ovResizePendingH);
    _ovResizePendingH = null;
  });
}
function endResize() {
  if (!_ovResizeActive) return;
  _ovResizeActive = false;
  document.body.style.cursor = '';
}
if (ovResizer) {
  ovResizer.addEventListener('mousedown', (e) => { e.preventDefault(); startResizeAt(e.clientY); });
  window.addEventListener('mousemove', (e) => { if (_ovResizeActive) onResizeMove(e.clientY); });
  window.addEventListener('mouseup', endResize);
  // Touch support
  ovResizer.addEventListener('touchstart', (e) => { const t = e.touches && e.touches[0]; if (!t) return; e.preventDefault(); startResizeAt(t.clientY); }, { passive: false });
  window.addEventListener('touchmove', (e) => { if (!_ovResizeActive) return; const t = e.touches && e.touches[0]; if (!t) return; onResizeMove(t.clientY); }, { passive: false });
  window.addEventListener('touchend', endResize);
}

function renderOverview() {
  if (!ovTrack) return;
  const vp = ovViewport && ovViewport.parentElement === ovTrack ? ovViewport : null;
  if (vp) ovTrack.removeChild(vp);
  while (ovTrack.firstChild) ovTrack.removeChild(ovTrack.firstChild);
  const n = columns.length;
  if (!n) return;
  const trackW = ovTrack.clientWidth || ovTrack.offsetWidth || 1;
  const colWidths = columns.map(c => Math.max(1, c?.el?.offsetWidth || 0));
  const totalW = colWidths.reduce((a,b)=>a+b,0) || 1;
  let acc = 0;
  for (let i = 0; i < n; i++) {
    const el = document.createElement('div');
    el.className = 'ov-col';
    el.dataset.index = String(i);
    const leftPx = Math.round((acc / totalW) * trackW);
    const widthPx = Math.max(2, Math.round((colWidths[i] / totalW) * trackW));
    el.style.left = leftPx + 'px';
    el.style.width = widthPx + 'px';
    const pTop = document.createElement('div');
    pTop.className = 'ov-pane top';
    const cTop = document.createElement('canvas');
    cTop.className = 'ov-canvas';
    pTop.appendChild(cTop);
    const pBottom = document.createElement('div');
    pBottom.className = 'ov-pane bottom';
    const cBot = document.createElement('canvas');
    cBot.className = 'ov-canvas';
    pBottom.appendChild(cBot);
    el.appendChild(pTop);
    el.appendChild(pBottom);
    ovTrack.appendChild(el);
    acc += colWidths[i];
  }
  if (ovViewport) ovTrack.appendChild(ovViewport);
}

function updateOverviewViewport() {
  if (!ovTrack || !ovViewport || !overview) return;
  const trackRect = ovTrack.getBoundingClientRect();
  let trackW = Math.max(0, trackRect.width);
  if (trackW === 0) { requestAnimationFrame(updateOverviewViewport); return; }
  const leftEdge = (leftEdgeEl?.offsetWidth || 0);
  const rightEdge = (rightEdgeEl?.offsetWidth || 0);
  const totalContent = Math.max(1, grid.scrollWidth - leftEdge - rightEdge);
  const visible = Math.max(1, Math.min(totalContent, grid.clientWidth));
  const leftContent = Math.max(0, Math.min(grid.scrollLeft - leftEdge, totalContent - visible));
  const vpLeft = (leftContent / totalContent) * trackW;
  const vpW = Math.max(24, (visible / totalContent) * trackW);
  ovViewport.style.left = Math.round(vpLeft) + 'px';
  ovViewport.style.width = Math.round(vpW) + 'px';
}

function initOverviewInteractions() {
  if (!ovTrack || !overview) return;
  let dragging = false;
  function toTrackX(clientX) {
    const r = ovTrack.getBoundingClientRect();
    return Math.max(0, Math.min(clientX - r.left, r.width));
  }
  function scrollToTrackPos(trackX) {
    const leftEdge = (leftEdgeEl?.offsetWidth || 0);
    const rightEdge = (rightEdgeEl?.offsetWidth || 0);
    const totalContent = Math.max(1, grid.scrollWidth - leftEdge - rightEdge);
    const visible = Math.max(1, Math.min(totalContent, grid.clientWidth));
    const trackW = Math.max(1, ovTrack.getBoundingClientRect().width);
    const desiredLeftContent = (trackX / trackW) * totalContent - (visible / 2);
    const maxLeftContent = Math.max(0, totalContent - visible);
    const targetContent = Math.max(0, Math.min(desiredLeftContent, maxLeftContent));
    const target = leftEdge + targetContent;
    _programmaticScroll = true;
    try { grid.scrollTo({ left: target, behavior: 'auto' }); } catch (_) { grid.scrollLeft = target; }
    _programmaticScroll = false;
    _lastScrollLeft = grid.scrollLeft;
    updateOverviewViewport();
  }
  ovTrack.addEventListener('mousedown', (e) => {
    dragging = true;
    document.body.style.cursor = 'grabbing';
    scrollToTrackPos(toTrackX(e.clientX));
  });
  window.addEventListener('mousemove', (e) => {
    if (!dragging) return;
    scrollToTrackPos(toTrackX(e.clientX));
  });
  window.addEventListener('mouseup', () => {
    if (!dragging) return;
    dragging = false;
    document.body.style.cursor = '';
  });
}

function startOverviewLoop() { if (_ovTimer) return; _ovTimer = setInterval(() => { if (overview && !overview.classList.contains('hidden')) { updateOverviewViewport(); updateOverviewSnapshots(); } }, 120); }

function stopOverviewLoop() { if (_ovTimer) { clearInterval(_ovTimer); _ovTimer = null; } }

// Update snapshots for each overview column from live xterm canvases
function updateOverviewSnapshots() {
  if (!ovTrack) return;
  const items = ovTrack.querySelectorAll('.ov-col');
  items.forEach((el) => {
    const i = Number(el.dataset.index || '-1');
    if (!(i >= 0 && i < columns.length)) return;
    const col = columns[i];
    const topPane = el.querySelector('.ov-pane.top');
    const botPane = el.querySelector('.ov-pane.bottom');
    const topCanvas = topPane && topPane.querySelector('canvas');
    const botCanvas = botPane && botPane.querySelector('canvas');
    // Sync pane backgrounds to terminal backgrounds
    try {
      const topBg = getPaneBgColor(columns[i]?.top?.pane) || DEFAULT_BG;
      if (topPane) topPane.style.background = topBg;
      const botBg = getPaneBgColor(columns[i]?.bottom?.pane) || DEFAULT_BG;
      if (botPane) botPane.style.background = botBg;
    } catch (_) {}
    function collectSourceCanvases(paneEl) {
      const termEl = paneEl?.querySelector('.term');
      if (!termEl) return [];
      const cvs = Array.from(termEl.querySelectorAll('canvas'));
      return cvs.filter(c => (c.width || c.getBoundingClientRect().width));
    }
    const srcTop = collectSourceCanvases(col?.top?.pane);
    const srcBot = collectSourceCanvases(col?.bottom?.pane);
    if (srcTop.length && topCanvas) compositeAndScale(srcTop, topCanvas); else if (topCanvas) drawTextMinimap(col?.top?.term, topCanvas);
    if (srcBot.length && botCanvas) compositeAndScale(srcBot, botCanvas); else if (botCanvas) drawTextMinimap(col?.bottom?.term, botCanvas);
  });
}

function getPaneBgColor(paneEl) {
  try {
    const inline = paneEl && paneEl.style && paneEl.style.getPropertyValue('--term-bg');
    if (inline) return inline.trim();
    const cs = paneEl ? window.getComputedStyle(paneEl) : null;
    if (cs) {
      const v = cs.getPropertyValue('--term-bg');
      if (v && v.trim()) return v.trim();
    }
  } catch (_) {}
  return DEFAULT_BG;
}

function compositeAndScale(srcCanvases, destCanvas) {
  try {
    const d = destCanvas;
    const rect = d.getBoundingClientRect();
    const wCss = Math.max(2, Math.floor(rect.width));
    const hCss = Math.max(2, Math.floor(rect.height));
    const dpr = Math.max(1, Math.floor(window.devicePixelRatio || 1));
    const w = wCss * dpr;
    const h = hCss * dpr;
    if (d.width !== w) d.width = w;
    if (d.height !== h) d.height = h;
    const ctx = d.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); // draw in CSS pixels at HiDPI resolution
    ctx.imageSmoothingEnabled = true;
    try { ctx.imageSmoothingQuality = 'high'; } catch (_) {}
    // Composite all source canvases onto an offscreen canvas at source resolution
    let sw = 0, sh = 0;
    srcCanvases.forEach(c => { sw = Math.max(sw, c.width || c.getBoundingClientRect().width); sh = Math.max(sh, c.height || c.getBoundingClientRect().height); });
    sw = Math.max(1, sw); sh = Math.max(1, sh);
    const off = document.createElement('canvas'); off.width = sw; off.height = sh;
    const offctx = off.getContext('2d'); if (!offctx) return;
    offctx.imageSmoothingEnabled = true;
    try { offctx.imageSmoothingQuality = 'high'; } catch (_) {}
    offctx.clearRect(0, 0, sw, sh);
    srcCanvases.forEach(c => { if (c.width && c.height) offctx.drawImage(c, 0, 0); });
    // Now scale composite
    ctx.clearRect(0, 0, wCss, hCss);
    ctx.drawImage(off, 0, 0, sw, sh, 0, 0, wCss, hCss);
  } catch (_) { /* ignore */ }
}

function drawTextMinimap(term, destCanvas) {
  if (!term || !destCanvas) return;
  try {
    const d = destCanvas;
    const rect = d.getBoundingClientRect();
    const wCss = Math.max(30, Math.floor(rect.width));
    const hCss = Math.max(14, Math.floor(rect.height));
    const dpr = Math.max(1, Math.floor(window.devicePixelRatio || 1));
    const w = wCss * dpr;
    const h = hCss * dpr;
    if (d.width !== w) d.width = w;
    if (d.height !== h) d.height = h;
    const ctx = d.getContext('2d'); if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.imageSmoothingEnabled = true;
    try { ctx.imageSmoothingQuality = 'high'; } catch (_) {}
    // Match parent pane background color
    let bg = '#0d1321';
    try { const cs = window.getComputedStyle(d.parentElement); if (cs) bg = cs.backgroundColor || bg; } catch (_) {}
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, wCss, hCss);
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, wCss, hCss);
    ctx.clip();
    ctx.fillStyle = '#9fb3ff';
    // Choose font and spacing to avoid overlap: compute rows from step size
    const padding = 2;
    const availH = Math.max(4, hCss - padding * 2);
    const minFont = 6, maxFont = 10, gap = 1;
    // Start with a target font size scaled to height, then recompute rows to fit with gap
    let fontPx = Math.min(maxFont, Math.max(minFont, Math.floor(availH / 6)));
    let lineStep = fontPx + gap;
    let rows = Math.max(3, Math.floor(availH / lineStep));
    // Adjust font down a bit if too tight
    if (rows < 3) { rows = 3; fontPx = Math.max(minFont, Math.floor((availH - (rows - 1) * gap) / rows)); lineStep = fontPx + gap; }
    const buf = term.buffer?.active;
    const bufLen = (buf && typeof buf.length === 'number') ? buf.length : (term.rows || 24);
    const viewportY = (buf && typeof buf.viewportY === 'number') ? buf.viewportY : null;
    const cursorY = (buf && typeof buf.cursorY === 'number') ? buf.cursorY : (term._core?.buffer?.y ?? 0);
    const baseY = (buf && typeof buf.baseY === 'number') ? buf.baseY : 0;
    // Prefer current viewport start; fallback to approximate bottom-aligned window
    let startY = viewportY;
    if (startY == null) startY = Math.max(0, baseY + cursorY - (term.rows || rows) + 1);
    for (let r = 0; r < rows; r++) {
      const y = Math.max(0, Math.min(bufLen - 1, startY + r));
      let text = '';
      try { text = buf?.getLine ? (buf.getLine(y)?.translateToString(true) || '') : ''; } catch (_) { text = ''; }
      const yPix = padding + Math.floor(r * lineStep);
      ctx.font = `${fontPx}px Menlo, Monaco, Consolas, monospace`;
      ctx.textBaseline = 'top';
      ctx.fillStyle = '#9fb3ff';
      const maxChars = Math.max(6, Math.floor((wCss - 4) / Math.max(3, Math.floor(fontPx * 0.6))));
      if (text) ctx.fillText(text.slice(0, maxChars), 2, yPix);
    }
    ctx.restore();
  } catch (_) { /* ignore */ }
}

// Toggle scroll snapping near edges so + buttons can remain visible once revealed
function updateEdgeSnapState() { /* stickiness disabled */ }

// Re-evaluate snapping as user scrolls and gently continue to hide + when nudged inward
grid.addEventListener('scroll', () => {
  updateEdgeSnapState();
  try { updateOverviewViewport(); } catch (_) {}
  if (_programmaticScroll) { _lastScrollLeft = grid.scrollLeft; return; }
  // Stickiness disabled
  _lastScrollLeft = grid.scrollLeft;
  return;

  const leftEdge = (leftEdgeEl?.offsetWidth || 0);
  const rightEdge = (rightEdgeEl?.offsetWidth || 0);
  const maxScrollLeft = Math.max(0, grid.scrollWidth - grid.clientWidth);
  const now = (typeof performance !== 'undefined' ? performance.now() : Date.now());
  const delta = grid.scrollLeft - _lastScrollLeft;
  const dt = Math.max(1, now - _lastScrollTime);
  const speed = Math.abs(delta) / dt; // px/ms
  _lastScrollLeft = grid.scrollLeft;
  _lastScrollTime = now;

  // Disable snapping during fast flicks; restore shortly after it slows/settles
  const FAST_THRESH = 0.7; // px per ms
  if (speed > FAST_THRESH) {
    _fastScrolling = true;
    if (_fastOffTimer) clearTimeout(_fastOffTimer);
    _fastOffTimer = setTimeout(() => { _fastScrolling = false; updateEdgeSnapState(); }, 160);
  }

  function scheduleHide(target) {
    if (_hideEdgeTimer) clearTimeout(_hideEdgeTimer);
    _hideEdgeTimer = setTimeout(() => {
      _programmaticScroll = true;
      try { grid.scrollTo({ left: target, behavior: 'smooth' }); } catch (_) { grid.scrollLeft = target; }
      setTimeout(() => { _programmaticScroll = false; }, 120);
    }, 40);
  }

  // Left edge visible: if user scrolls right a bit, complete to hide
  if (delta > 0 && grid.scrollLeft > 0 && grid.scrollLeft < (leftEdge - 2)) {
    scheduleHide(leftEdge);
    return;
  }

  // Right edge visible: if user scrolls left a bit, complete to hide
  const rightBandStart = Math.max(0, maxScrollLeft - rightEdge);
  if (delta < 0 && grid.scrollLeft > (rightBandStart + 2)) {
    scheduleHide(rightBandStart);
    return;
  }
});
// Overview removed
function scheduleOverviewRefresh() {
  if (!isMinimapOpen()) return;
  if (_ovInvalidateTimer) return;
  _ovInvalidateTimer = setTimeout(() => {
    _ovInvalidateTimer = null;
    try { updateOverviewSnapshots(); updateOverviewViewport(); } catch (_) {}
  }, 80);
}
