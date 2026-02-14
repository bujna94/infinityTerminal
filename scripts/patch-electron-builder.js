const fs = require('fs');
const path = require('path');

const target = path.join(
  __dirname,
  '..',
  'node_modules',
  'app-builder-lib',
  'out',
  'node-module-collector',
  'npmNodeModulesCollector.js'
);

const marker = '/* infinity-terminal: robust-npm-tree-parse */';

function main() {
  if (!fs.existsSync(target)) {
    console.log('[patch-electron-builder] target file not found, skipping');
    return;
  }

  let src = fs.readFileSync(target, 'utf8');

  const replacement = `    parseDependenciesTree(jsonBlob) {\n        ${marker}\n        const tryParse = (text) => {\n            if (!text) return null;\n            try { return JSON.parse(text); } catch (_) {}\n            const start = text.indexOf('{');\n            const end = text.lastIndexOf('}');\n            if (start >= 0 && end > start) {\n                try { return JSON.parse(text.slice(start, end + 1)); } catch (_) {}\n            }\n            return null;\n        };\n\n        const initial = tryParse(String(jsonBlob || '').trim());\n        if (initial) return initial;\n\n        const fs = require('fs');\n        const path = require('path');\n        const lockPath = path.join(this.rootDir, 'package-lock.json');\n        if (!fs.existsSync(lockPath)) {\n            throw new Error('Unable to parse npm dependency tree JSON');\n        }\n\n        const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));\n        const packages = lock && lock.packages ? lock.packages : {};\n        const rootMeta = packages[''] || {};\n        const rootDeps = Object.assign({}, rootMeta.dependencies || {}, rootMeta.optionalDependencies || {});\n\n        const visiting = new Set();\n        const cache = new Map();\n\n        const buildNode = (name) => {\n            if (cache.has(name)) return cache.get(name);\n\n            const key = 'node_modules/' + name;\n            const pkg = packages[key] || {};\n            const version = pkg.version || '';\n            const nodePath = path.join(this.rootDir, key);\n            const rawDeps = Object.assign({}, pkg.dependencies || {});\n\n            const node = {\n                name,\n                version,\n                path: nodePath,\n                dependencies: {},\n                optionalDependencies: pkg.optionalDependencies || {},\n                _dependencies: rawDeps,\n            };\n            cache.set(name, node);\n\n            const cycleKey = name + '@' + version;\n            if (visiting.has(cycleKey)) return node;\n            visiting.add(cycleKey);\n\n            for (const childName of Object.keys(rawDeps)) {\n                node.dependencies[childName] = buildNode(childName);\n            }\n\n            visiting.delete(cycleKey);\n            return node;\n        };\n\n        const dependencies = {};\n        for (const depName of Object.keys(rootDeps)) {\n            dependencies[depName] = buildNode(depName);\n        }\n\n        return {\n            name: rootMeta.name || lock.name || 'app',\n            version: rootMeta.version || lock.version || '0.0.0',\n            path: this.rootDir,\n            dependencies,\n            optionalDependencies: rootMeta.optionalDependencies || {},\n            _dependencies: rootDeps,\n        };\n    }`;

  const blockRegex = /    parseDependenciesTree\(jsonBlob\) \{[\s\S]*?\n    \}/m;
  if (!blockRegex.test(src)) {
    throw new Error('parseDependenciesTree block not found in npmNodeModulesCollector.js');
  }

  src = src.replace(blockRegex, replacement);
  fs.writeFileSync(target, src);
  console.log('[patch-electron-builder] applied');
}

main();
