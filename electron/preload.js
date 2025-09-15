const { contextBridge, ipcRenderer, shell } = require('electron');
const path = require('path');
const { pathToFileURL } = require('url');

contextBridge.exposeInMainWorld('pty', {
  create: (opts) => ipcRenderer.invoke('pty:create', opts),
  write: (id, data) => ipcRenderer.send('pty:write', { id, data }),
  resize: (id, cols, rows) => ipcRenderer.send('pty:resize', { id, cols, rows }),
  kill: (id) => ipcRenderer.send('pty:kill', { id }),
  onData: (cb) => ipcRenderer.on('pty:data', (_evt, payload) => cb(payload)),
  onExit: (cb) => ipcRenderer.on('pty:exit', (_evt, payload) => cb(payload)),
});

contextBridge.exposeInMainWorld('platform', {
  isMac: process.platform === 'darwin',
  name: process.platform,
});

// Window state/Chrome hints
contextBridge.exposeInMainWorld('windowState', {
  onTrafficVisible: (cb) => ipcRenderer.on('window:traffic-visible', (_evt, visible) => {
    try { cb(!!visible); } catch (_) {}
  }),
});

// Updates bridge: notify renderer when a new version is available
contextBridge.exposeInMainWorld('updates', {
  onAvailable: (cb) => ipcRenderer.on('update:available', (_evt, payload) => {
    try { cb(payload); } catch (_) {}
  }),
  openExternal: (url) => { try { if (url) shell.openExternal(url); } catch (_) {} },
});

// Dynamically import xterm ESM and expose safely to the renderer
(async () => {
  try {
    const xtermPath = path.join(__dirname, '..', 'node_modules', '@xterm', 'xterm', 'lib', 'xterm.js');
    const xtermUrl = pathToFileURL(xtermPath).href;
    const mod = await import(xtermUrl);
    contextBridge.exposeInMainWorld('xterm', { Terminal: mod.Terminal });
  } catch (e) {
    // Expose a minimal marker so renderer can show a friendly message
    contextBridge.exposeInMainWorld('xterm', null);
    console.error('Failed to load xterm in preload:', e);
  }
})();
