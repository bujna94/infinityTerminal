const { app, BrowserWindow, ipcMain, Menu, dialog, shell, nativeImage, net } = require('electron');
const path = require('path');
const os = require('os');
const pty = require('node-pty');
const https = require('https');

const isMac = process.platform === 'darwin';
const isLinux = process.platform === 'linux';
let _latestUpdatePayload = null; // cache last update info to resend after load
let isQuitting = false;

/** @type {Map<string, import('node-pty').IPty>} */
const ptys = new Map();

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    fullscreenable: true,
    ...(isLinux ? { title: 'Infinity Terminal', backgroundColor: '#0f1117', autoHideMenuBar: true, frame: false } : {}),
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
  if (!isMac) {
    try { win.setMenuBarVisibility(false); } catch (_) {}
  }

  // Notify renderer whether macOS traffic lights are visible (not in fullscreen)
  const sendTrafficState = () => {
    const visible = isMac && !win.isFullScreen();
    try { win.webContents.send('window:traffic-visible', visible); } catch (_) {}
  };
  win.webContents.on('did-finish-load', sendTrafficState);
  win.on('enter-full-screen', sendTrafficState);
  win.on('leave-full-screen', sendTrafficState);

  // If we already discovered an update, notify this window after it finishes loading
  win.webContents.on('did-finish-load', () => {
    if (_latestUpdatePayload) {
      try { win.webContents.send('update:available', _latestUpdatePayload); } catch (_) {}
    }
  });

  // Optional: open devtools if needed
  // win.webContents.openDevTools({ mode: 'detach' });
}

app.whenReady().then(() => {
  if (isMac) {
    try { app.setName('Infinity Terminal'); } catch (_) {}
    try {
      // Ensure About panel shows app version and our app icon (.icns is preferred on macOS)
      app.setAboutPanelOptions({
        applicationName: 'Infinity Terminal',
        applicationVersion: app.getVersion ? app.getVersion() : undefined,
        iconPath: path.join(__dirname, '..', 'resources', 'appLogoSmaller.icns'),
      });
    } catch (_) {}
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
    {
      label: 'Help',
      submenu: [
        {
          label: 'Check for Updates…',
          click: () => { try { checkForUpdatesManual(); } catch (_) {} },
        },
        { type: 'separator' },
        { label: 'About Infinity Terminal', click: () => showAbout() },
      ],
    },
  ];
  const menu = Menu.buildFromTemplate(template);
  Menu.setApplicationMenu(isMac ? menu : null);

  createWindow();

  app.on('activate', function () {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });

  // Check for updates on startup (GitHub latest release)
  try { checkForUpdates(); } catch (_) {}
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
  const { id, cmd, args = [], cwd = os.homedir(), env = {} } = payload;
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

ipcMain.on('window:control', (_event, payload) => {
  const { action } = payload || {};
  const win = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0];
  if (!win || !action) return;
  if (action === 'minimize') return win.minimize();
  if (action === 'maximize') return win.maximize();
  if (action === 'restore') return win.restore();
  if (action === 'close') return win.close();
});

ipcMain.on('app:check-updates', () => {
  try { checkForUpdatesManual(); } catch (_) {}
});

ipcMain.on('app:about', () => {
  try { showAbout(); } catch (_) {}
});

function defaultShell() {
  if (process.platform === 'win32') {
    return process.env.COMSPEC || 'cmd.exe';
  }
  return process.env.SHELL || '/bin/bash';
}

// Simple update checker using GitHub Releases API
function checkForUpdates() {
  const current = (app.getVersion && app.getVersion()) || '0.0.0';
  fetchLatestVersion(current).then((info) => {
    if (!info) return;
    const { version, tag, url } = info;
    if (isNewerVersion(version, current)) {
      const payload = { version, tag, url, name: tag, body: '', currentVersion: current };
      _latestUpdatePayload = payload;
      for (const w of BrowserWindow.getAllWindows()) {
        try { w.webContents.send('update:available', payload); } catch (_) {}
      }
    }
  }).catch(() => {});
}

function isNewerVersion(a, b) {
  const pa = String(a || '0').split('.').map(n => parseInt(n, 10) || 0);
  const pb = String(b || '0').split('.').map(n => parseInt(n, 10) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const xa = pa[i] || 0; const xb = pb[i] || 0;
    if (xa > xb) return true;
    if (xa < xb) return false;
  }
  return false;
}

function showAbout() {
  const name = (app.getName && app.getName()) || 'Infinity Terminal';
  const version = (app.getVersion && app.getVersion()) || '0.0.0';
  const icon = (() => {
    try { return nativeImage.createFromPath(path.join(__dirname, '..', 'resources', 'appLogoSmaller.png')); }
    catch (_) { return undefined; }
  })();
  dialog.showMessageBox({
    type: 'info',
    buttons: ['OK'],
    title: `About ${name}`,
    message: `${name}`,
    detail: `Version ${version}\n\nBuilt with ❤️ by Pavol Bujna`,
    icon,
  }).catch(() => {});
}

function checkForUpdatesManual() {
  const current = (app.getVersion && app.getVersion()) || '0.0.0';
  fetchLatestVersion(current)
    .then((info) => {
      if (!info) throw new Error('no info');
      const { version, tag, url } = info;
      if (isNewerVersion(version, current)) {
        const payload = { version, tag, url, name: tag, body: '', currentVersion: current };
        const win = BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0];
        if (win) { try { win.webContents.send('update:available', payload); } catch (_) {} }
      } else {
        dialog.showMessageBox({
          type: 'info', buttons: ['OK'], title: 'You’re up to date',
          message: `Infinity Terminal ${current} is the latest version.`,
        }).catch(() => {});
      }
    })
    .catch(() => {
      dialog.showMessageBox({
        type: 'warning',
        buttons: ['Open Releases Page', 'Cancel'],
        defaultId: 0,
        cancelId: 1,
        title: 'Update Check Failed',
        message: 'Could not check for updates right now.',
        detail: 'You can open the Releases page to download the latest version.',
      }).then((resDlg) => {
        if (resDlg.response === 0) {
          try { shell.openExternal('https://github.com/bujna94/infinityTerminal/releases/latest'); } catch (_) {}
        }
      }).catch(() => {});
    });
}

// Try API first, then web redirect/HTML fallback
function fetchLatestVersion(current) {
  return new Promise((resolve, reject) => {
    tryApiLatest(current).then((info) => {
      if (info) return resolve(info);
      return tryWebLatest(current).then(resolve).catch(reject);
    }).catch(() => {
      tryWebLatest(current).then(resolve).catch(reject);
    });
  });
}

function tryApiLatest(current) {
  return new Promise((resolve) => {
    const url = 'https://api.github.com/repos/bujna94/infinityTerminal/releases/latest';
    const headers = {
      'User-Agent': `InfinityTerminal/${current} (+https://github.com/bujna94/infinityTerminal)`,
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28'
    };
    // Prefer Electron net (proxy/system settings), fallback to https
    let settled = false;
    try {
      const req = net.request({ method: 'GET', url, headers });
      req.on('response', (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          if (settled) return;
          settled = true;
          try {
            if (res.statusCode !== 200) return resolve(null);
            const json = JSON.parse(data);
            const tag = (json.tag_name || '').trim();
            const version = tag.replace(/^v/i, '');
            const url2 = json.html_url || `https://github.com/bujna94/infinityTerminal/releases/tag/${encodeURIComponent(tag)}`;
            resolve({ version, tag, url: url2 });
          } catch (_) { resolve(null); }
        });
      });
      req.on('error', () => { if (!settled) { settled = true; resolve(null); } });
      req.setHeader('Accept', headers['Accept']);
      req.end();
      setTimeout(() => { if (!settled) { settled = true; try { req.abort(); } catch (_) {} resolve(null); } }, 6000);
    } catch (_) {
      // Fallback
      const opts = {
        hostname: 'api.github.com',
        path: '/repos/bujna94/infinityTerminal/releases/latest',
        method: 'GET', headers
      };
      const r = https.request(opts, (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          try {
            if (res.statusCode !== 200) return resolve(null);
            const json = JSON.parse(data);
            const tag = (json.tag_name || '').trim();
            const version = tag.replace(/^v/i, '');
            const url2 = json.html_url || `https://github.com/bujna94/infinityTerminal/releases/tag/${encodeURIComponent(tag)}`;
            resolve({ version, tag, url: url2 });
          } catch (_) { resolve(null); }
        });
      });
      r.on('error', () => resolve(null));
      r.setTimeout(6000, () => { try { r.destroy(new Error('timeout')); } catch (_) {} });
      r.end();
    }
  });
}

function tryWebLatest(current) {
  return new Promise((resolve) => {
    const url = 'https://github.com/bujna94/infinityTerminal/releases/latest';
    const headers = { 'User-Agent': `InfinityTerminal/${current}` };
    let settled = false;
    try {
      const req = net.request({ method: 'GET', url, headers });
      req.on('response', (res) => {
        const loc = res.headers && (res.headers.location || res.headers.Location);
        if (!settled && typeof loc === 'string') {
          settled = true;
          const m = /\/releases\/tag\/v?(\d+\.\d+\.\d+)/.exec(loc);
          if (m) return resolve({ version: m[1], tag: `v${m[1]}`, url: `https://github.com${loc}` });
        }
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          if (settled) return;
          settled = true;
          try {
            const m = data && data.match(/\/releases\/tag\/v?(\d+\.\d+\.\d+)/);
            if (m) return resolve({ version: m[1], tag: `v${m[1]}`, url: `https://github.com/bujna94/infinityTerminal/releases/tag/v${m[1]}` });
            resolve(null);
          } catch (_) { resolve(null); }
        });
      });
      req.on('error', () => { if (!settled) { settled = true; resolve(null); } });
      req.end();
      setTimeout(() => { if (!settled) { settled = true; try { req.abort(); } catch (_) {} resolve(null); } }, 6000);
    } catch (_) {
      const opts = {
        hostname: 'github.com',
        path: '/bujna94/infinityTerminal/releases/latest', method: 'GET', headers
      };
      const r = https.request(opts, (res) => {
        const loc = res.headers && (res.headers.location || res.headers.Location);
        if (typeof loc === 'string') {
          const m = /\/releases\/tag\/v?(\d+\.\d+\.\d+)/.exec(loc);
          if (m) return resolve({ version: m[1], tag: `v${m[1]}`, url: `https://github.com${loc}` });
        }
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          try {
            const m = data && data.match(/\/releases\/tag\/v?(\d+\.\d+\.\d+)/);
            if (m) return resolve({ version: m[1], tag: `v${m[1]}`, url: `https://github.com/bujna94/infinityTerminal/releases/tag/v${m[1]}` });
            resolve(null);
          } catch (_) { resolve(null); }
        });
      });
      r.on('error', () => resolve(null));
      r.setTimeout(6000, () => { try { r.destroy(new Error('timeout')); } catch (_) {} });
      r.end();
    }
  });
}
