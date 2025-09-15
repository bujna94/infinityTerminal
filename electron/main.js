const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const os = require('os');
const pty = require('node-pty');

const isMac = process.platform === 'darwin';

/** @type {Map<string, import('node-pty').IPty>} */
const ptys = new Map();

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    fullscreen: true,
    simpleFullscreen: true,
    fullscreenable: true,
    titleBarStyle: 'hiddenInset',
    icon: path.join(__dirname, '..', 'resources', 'appLogo.png'),
    webPreferences: {
      contextIsolation: false,
      nodeIntegration: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  win.loadFile(path.join(__dirname, '..', 'src', 'index.html'));

  // Optional: open devtools if needed
  // win.webContents.openDevTools({ mode: 'detach' });

  // Ensure fullscreen after ready-to-show
  win.once('ready-to-show', () => {
    try { win.setFullScreen(true); } catch (_) {}
  });
  win.on('focus', () => {
    try { if (!win.isFullScreen()) win.setFullScreen(true); } catch (_) {}
  });
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', function () {
  if (!isMac) app.quit();
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

  proc.onData((data) => {
    event.sender.send('pty:data', { id, data });
  });

  proc.onExit(({ exitCode, signal }) => {
    event.sender.send('pty:exit', { id, exitCode, signal });
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
