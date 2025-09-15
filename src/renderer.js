// Renderer logic: manage 2xN horizontally scrollable terminals.
// Terminal can come from preload (window.xterm.Terminal) or classic script (window.Terminal).
let TerminalCtor = (window.xterm && window.xterm.Terminal) || window.Terminal;

const grid = document.getElementById('grid');
const sshBtn = document.getElementById('sshBtn');
const addLeftBtn = document.getElementById('addLeftBtn');
const addRightBtn = document.getElementById('addRightBtn');

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
let isAdding = false;

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
  grid.appendChild(node);
  const index = columns.push({ top, bottom, el: node }) - 1;
  if (scrollIntoView) node.scrollIntoView({ behavior: 'smooth', inline: 'end', block: 'nearest' });
  return index;
}

function addColumnLeft() {
  const { node, top, bottom } = createColumnNode();
  const first = grid.firstChild;
  grid.insertBefore(node, first);
  // Keep viewport stable after prepending
  const w = node.offsetWidth || Math.floor(grid.clientWidth / 2);
  grid.scrollLeft += w;
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
  const offset = (addLeftBtn && addLeftBtn.offsetWidth) || 0;
  const start = Math.floor(Math.max(0, grid.scrollLeft - offset) / w);
  const perView = Math.max(1, Math.round(grid.clientWidth / w));
  const right = Math.min(columns.length - 1, start + perView - 1);
  return isFinite(right) ? right : null;
}

function updateEdgeButtons() {
  const threshold = 16;
  const atLeft = grid.scrollLeft <= threshold;
  const atRight = grid.scrollLeft + grid.clientWidth >= grid.scrollWidth - threshold;
  addLeftBtn.style.display = atLeft ? 'flex' : 'none';
  addRightBtn.style.display = atRight ? 'flex' : 'none';
}

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
    // Seed with two visible columns (four terminals)
    addColumnRight(false);
    addColumnRight(false);
    // Overlay edge buttons visibility and handlers
    grid.addEventListener('scroll', updateEdgeButtons, { passive: true });
    window.addEventListener('resize', updateEdgeButtons);
    updateEdgeButtons();
    addLeftBtn.addEventListener('click', () => { addColumnLeft(); updateEdgeButtons(); });
    addRightBtn.addEventListener('click', () => { addColumnRight(true); updateEdgeButtons(); });
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
});
