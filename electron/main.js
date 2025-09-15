const { app, BrowserWindow, ipcMain, Menu } = require('electron');
const path = require('path');
const os = require('os');
const pty = require('node-pty');

const isMac = process.platform === 'darwin';
let isQuitting = false;

/** @type {Map<string, import('node-pty').IPty>} */
const ptys = new Map();

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    fullscreenable: true,
    ...(isMac ? { titleBarStyle: 'hiddenInset', titleBarOverlay: { color: '#0f1117', symbolColor: '#e5e9f0', height: 42 } } : {}),
    icon: path.join(__dirname, '..', 'resources', 'appLogo.png'),
    webPreferences: {
      // Match existing renderer code which uses both preload and fallback require
      contextIsolation: false,
      nodeIntegration: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  win.loadFile(path.join(__dirname, '..', 'src', 'index.html'));

  // Notify renderer whether macOS traffic lights are visible (not in fullscreen)
  const sendTrafficState = () => {
    const visible = isMac && !win.isFullScreen();
    try { win.webContents.send('window:traffic-visible', visible); } catch (_) {}
  };
  win.webContents.on('did-finish-load', sendTrafficState);
  win.on('enter-full-screen', sendTrafficState);
  win.on('leave-full-screen', sendTrafficState);

  // Optional: open devtools if needed
  // win.webContents.openDevTools({ mode: 'detach' });
}

app.whenReady().then(() => {
  if (isMac) {
    try { app.setName('Infinity Terminal'); } catch (_) {}
  }
  // Ensure app menu with working Quit on macOS and other platforms
  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        ...(isMac ? [{ role: 'close' }] : [{ role: 'quit' }]),
      ],
    },
    { role: 'windowMenu' },
  ];
  const menu = Menu.buildFromTemplate(template);
  Menu.setApplicationMenu(menu);

  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

function killAllPtys() {
  try {
    for (const [id, proc] of ptys.entries()) {
      try { proc.kill(); } catch (_) {}
      ptys.delete(id);
    }
  } catch (_) {}
}

app.on('window-all-closed', function () {
  // Clean up PTYs when no windows remain
  killAllPtys();
  if (!isMac) app.quit();
});

// Ensure we terminate all child PTYs when quitting, so Quit actually exits
app.on('before-quit', () => {
  isQuitting = true;
  killAllPtys();
});

// IPC: PTY lifecycle
ipcMain.handle('pty:create', (event, payload) => {
  const { id, cmd, args = [], cwd = process.cwd(), env = {} } = payload;
  if (!id) throw new Error('pty:create requires id');
  if (ptys.has(id)) throw new Error(`PTY with id ${id} already exists`);

  const shell = cmd || defaultShell();
  const cols = 80;
  const rows = 24;

  const proc = pty.spawn(shell, args, {
    name: 'xterm-256color',
    cols,
    rows,
    cwd,
    env: {
      ...process.env,
      TERM: 'xterm-256color',
      COLORTERM: 'truecolor',
      CLICOLOR: '1',
      ...env,
    },
  });

  ptys.set(id, proc);

  const contents = event.sender;
  const safeSend = (channel, payload) => {
    if (isQuitting) return;
    try {
      if (!contents || contents.isDestroyed()) return;
      contents.send(channel, payload);
    } catch (_) {}
  };

  proc.onData((data) => {
    safeSend('pty:data', { id, data });
  });

  proc.onExit(({ exitCode, signal }) => {
    safeSend('pty:exit', { id, exitCode, signal });
    ptys.delete(id);
  });

  return { ok: true };
});

ipcMain.on('pty:write', (event, { id, data }) => {
  const proc = ptys.get(id);
  if (proc) proc.write(data);
});

ipcMain.on('pty:resize', (event, { id, cols, rows }) => {
  const proc = ptys.get(id);
  if (proc && cols > 0 && rows > 0) proc.resize(cols, rows);
});

ipcMain.on('pty:kill', (event, { id }) => {
  const proc = ptys.get(id);
  if (proc) {
    try { proc.kill(); } catch (_) {}
    ptys.delete(id);
  }
});

function defaultShell() {
  if (process.platform === 'win32') {
    return process.env.COMSPEC || 'cmd.exe';
  }
  return process.env.SHELL || '/bin/bash';
}
