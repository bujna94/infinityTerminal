// Renderer logic: manage 2xN horizontally scrollable terminals.
// Terminal can come from preload (window.xterm.Terminal) or classic script (window.Terminal).
let TerminalCtor = (window.xterm && window.xterm.Terminal) || window.Terminal;

const grid = document.getElementById('grid');
const sshBtn = document.getElementById('sshBtn');
const homeBtn = document.getElementById('homeBtn');
const resetBtn = document.getElementById('resetBtn');
const shortcutsBtn = document.getElementById('shortcutsBtn');
const shortcutsModal = document.getElementById('shortcutsModal');
const shortcutsOverlay = document.getElementById('shortcutsOverlay');
const shortcutsClose = document.getElementById('shortcutsClose');
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

sshBtn.addEventListener('click', async () => {
  const target = prompt('SSH target (e.g. user@host):');
  if (!target) return;
  const idx = currentRightVisibleIndex();
  const index = idx != null ? idx : (columns.length ? columns.length - 1 : addColumnRight());
  const col = columns[index];
  await col.top.runSSH(target);
  col.bottom.focus();
});

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
    theme: {
      background: '#0f1117'
    },
  });

  const id = makeId();
  const termEl = paneEl.querySelector('.term');
  term.open(termEl);

  let disposed = false;

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
  dataHandlers.set(id, (data) => term.write(data));
  exitHandlers.set(id, (exitCode) => {
    term.write(`\r\n\x1b[31m[process exited with code ${exitCode}]\x1b[0m\r\n`);
  });

  term.onData((data) => {
    pty.write(id, data);
  });

  term.onResize(({ cols, rows }) => {
    pty.resize(id, cols, rows);
  });

  async function runLocalShell() {
    await pty.create({ id });
    fit();
    term.focus();
  }

  async function runSSH(target) {
    const isWin = (typeof process !== 'undefined' && process.platform === 'win32') || window.platform?.name === 'win32';
    const sshCmd = isWin ? 'ssh.exe' : 'ssh';
    await pty.create({ id, cmd: sshCmd, args: [target] });
    fit();
    term.focus();
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

  return { id, term, runLocalShell, runSSH, fit, focus, dispose };
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
  return index;
}

function addColumnLeft() {
  const { node, top, bottom } = createColumnNode();
  grid.insertBefore(node, leftEdgeEl.nextSibling);
  // Keep viewport stable after prepending
  // Do not nudge scrollLeft so the left + remains visible when revealed
  columns.unshift({ top, bottom, el: node });
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
    // Edge cell buttons
    addLeftBtn.addEventListener('click', () => {
      // Add to the left and keep the + off-screen after creation
      addColumnLeft();
      updateEdgeSnapState();
    });
    addRightBtn.addEventListener('click', () => {
      // Add to the right, then ensure the right + hides just outside the last column
      addColumnRight(true);
      hideRightEdge(false);
      updateEdgeSnapState();
    });
    // Toolbar Home button
    if (homeBtn) homeBtn.addEventListener('click', () => { scrollHome(true); });
    // Toolbar Reset button
    if (resetBtn) resetBtn.addEventListener('click', () => { resetToHome(true); });
    // Toolbar Shortcuts popup
    function openShortcuts() {
      try { shortcutsOverlay.classList.remove('hidden'); } catch (_) {}
      try { shortcutsModal.classList.remove('hidden'); } catch (_) {}
    }
    function closeShortcuts() {
      try { shortcutsOverlay.classList.add('hidden'); } catch (_) {}
      try { shortcutsModal.classList.add('hidden'); } catch (_) {}
    }
    if (shortcutsBtn) shortcutsBtn.addEventListener('click', openShortcuts);
    if (shortcutsOverlay) shortcutsOverlay.addEventListener('click', closeShortcuts);
    if (shortcutsClose) shortcutsClose.addEventListener('click', closeShortcuts);
    window.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeShortcuts(); }, { capture: true });
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

// Toggle scroll snapping near edges so + buttons can remain visible once revealed
function updateEdgeSnapState() { /* stickiness disabled */ }

// Re-evaluate snapping as user scrolls and gently continue to hide + when nudged inward
grid.addEventListener('scroll', () => {
  updateEdgeSnapState();
  if (_programmaticScroll) { _lastScrollLeft = grid.scrollLeft; return; }
  // Stickiness disabled: only track and exit
  _lastScrollLeft = grid.scrollLeft; return;

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
