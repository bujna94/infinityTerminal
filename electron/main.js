const { app, BrowserWindow, ipcMain, Menu, dialog, shell, nativeImage, net } = require('electron');
const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFile } = require('child_process');
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

  // Intercept Cmd/Ctrl+R and F5 so the user can't kill running processes by
  // mistakenly hitting Cmd+R for Chrome on another screen. Cmd+Shift+R is the
  // renderer's reset shortcut and is intentionally allowed through.
  win.webContents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return;
    if (input.shift) return;
    const key = (input.key || '').toLowerCase();
    const mod = isMac ? input.meta : input.control;
    const isReload = (mod && key === 'r') || key === 'f5';
    if (!isReload) return;
    event.preventDefault();
    dialog.showMessageBox(win, {
      type: 'warning',
      buttons: ['Cancel', 'Reload'],
      defaultId: 0,
      cancelId: 0,
      title: 'Reload Infinity Terminal?',
      message: 'Reload Infinity Terminal?',
      detail: 'Layout and working directories will be restored, but any running commands (vim, npm run dev, claude, etc.) will be terminated and scrollback cleared.',
    }).then(async (res) => {
      if (res.response !== 1) return;
      // Flush a session save first so the reload restores fresh cwds.
      try { await requestRendererFinalSave(win, 600); } catch (_) {}
      try { win.webContents.reloadIgnoringCache(); } catch (_) { try { win.webContents.reload(); } catch (_) {} }
    }).catch(() => {});
  });

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

// Ask the renderer to flush a final session save and wait (capped) for its
// ack. Used both by Cmd+R reload and by app quit, so cwds get captured before
// PTYs die or the renderer is reloaded.
function requestRendererFinalSave(win, timeoutMs = 800) {
  return new Promise((resolve) => {
    if (!win || win.isDestroyed()) return resolve();
    let settled = false;
    const onResponse = () => { if (settled) return; settled = true; ipcMain.removeListener('session:final-save-done', onResponse); resolve(); };
    ipcMain.on('session:final-save-done', onResponse);
    setTimeout(() => { if (!settled) { settled = true; ipcMain.removeListener('session:final-save-done', onResponse); resolve(); } }, timeoutMs);
    try { win.webContents.send('session:final-save'); } catch (_) { onResponse(); }
  });
}

// Ensure we terminate all child PTYs when quitting, so Quit actually exits.
// Before killing PTYs (which would zero out their cwds), give the renderer a
// brief window to flush a final session save with up-to-date cwds.
let _finalSaveDone = false;
app.on('before-quit', (event) => {
  if (_finalSaveDone) { isQuitting = true; killAllPtys(); return; }
  event.preventDefault();
  const wins = BrowserWindow.getAllWindows();
  const proceed = () => {
    _finalSaveDone = true;
    isQuitting = true;
    killAllPtys();
    app.quit();
  };
  if (!wins.length) return proceed();
  Promise.all(wins.map((w) => requestRendererFinalSave(w, 800))).finally(proceed);
});

// IPC: PTY lifecycle
ipcMain.handle('pty:create', (event, payload) => {
  const { id, cmd, args = [], env = {} } = payload;
  let { cwd } = payload;
  // Fall back to home if a restored cwd no longer exists (deleted dir,
  // unmounted drive). Empty/missing cwd → home as well.
  if (!cwd || typeof cwd !== 'string') cwd = os.homedir();
  else { try { if (!fs.statSync(cwd).isDirectory()) cwd = os.homedir(); } catch (_) { cwd = os.homedir(); } }
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

// Best-effort lookup of the shell's current working directory. node-pty only
// records the *initial* cwd, but the kernel tracks the live cwd of the spawned
// process, so we read it via lsof (mac) or /proc (linux). Used by session save.
ipcMain.handle('pty:get-cwd', async (_event, { id }) => {
  const proc = ptys.get(id);
  if (!proc || !proc.pid) return null;
  return getCwdForPid(proc.pid);
});

function getCwdForPid(pid) {
  if (process.platform === 'linux') {
    return new Promise((resolve) => {
      fs.readlink(`/proc/${pid}/cwd`, (err, link) => resolve(err ? null : link));
    });
  }
  if (process.platform === 'darwin') {
    return new Promise((resolve) => {
      execFile('lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'], { timeout: 1500 }, (err, stdout) => {
        if (err || !stdout) return resolve(null);
        const line = stdout.split('\n').find((l) => l.startsWith('n'));
        resolve(line ? line.slice(1) : null);
      });
    });
  }
  return Promise.resolve(null);
}

// Session persistence — layout/colors/cwds across launches. Stored as JSON in
// userData so it survives app updates (DMG replaces the .app, leaves userData).
function sessionPath() {
  return path.join(app.getPath('userData'), 'session.json');
}

ipcMain.handle('session:save', async (_event, state) => {
  try {
    const file = sessionPath();
    await fs.promises.mkdir(path.dirname(file), { recursive: true });
    await fs.promises.writeFile(file, JSON.stringify(state, null, 2), 'utf8');
    return true;
  } catch (_) { return false; }
});

ipcMain.handle('session:load', async () => {
  try {
    const data = await fs.promises.readFile(sessionPath(), 'utf8');
    return JSON.parse(data);
  } catch (_) { return null; }
});

ipcMain.handle('session:clear', async () => {
  try { await fs.promises.unlink(sessionPath()); } catch (_) {}
  return true;
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
