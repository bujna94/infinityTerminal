#!/usr/bin/env node
const { execSync, spawnSync } = require('child_process');
const path = require('path');

function getElectronVersion() {
  try {
    // Read the installed electron package version
    const pkg = require('electron/package.json');
    return pkg.version.replace(/^v/, '');
  } catch (e) {
    try {
      // Fallback to npx electron --version
      const out = execSync('npx --yes electron --version', { stdio: ['ignore', 'pipe', 'inherit'] })
        .toString()
        .trim();
      return out.replace(/^v/, '');
    } catch (err) {
      console.error('Could not determine Electron version. Ensure electron is installed in dependencies.');
      process.exit(1);
    }
  }
}

function needsRebuild() {
  try {
    const electronBin = require.resolve('electron/cli.js');
    const res = spawnSync(process.execPath, [electronBin, '-e', "require('node-pty'); process.exit(0)"], {
      env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
      stdio: 'ignore',
    });
    return res.status !== 0;
  } catch (e) {
    return true;
  }
}

if (!needsRebuild()) {
  console.log('[rebuild-pty] node-pty is already compatible with Electron.');
  process.exit(0);
}

const target = getElectronVersion();
console.log(`[rebuild-pty] Rebuilding node-pty for Electron ${target}`);

const env = { ...process.env };
env.npm_config_target = target;
env.npm_config_runtime = 'electron';
env.npm_config_disturl = 'https://electronjs.org/headers';
env.npm_config_build_from_source = 'true';

try {
  // Clean stale native builds first to avoid ABI confusion
  try {
    const buildPath = path.join(process.cwd(), 'node_modules', 'node-pty', 'build');
    execSync(`rm -rf "${buildPath}"`);
  } catch (_) {}

  execSync('npm rebuild node-pty --build-from-source', {
    stdio: 'inherit',
    env,
  });
  console.log('[rebuild-pty] Success');
} catch (e) {
  console.error('[rebuild-pty] Failed to rebuild node-pty');
  process.exit(1);
}
