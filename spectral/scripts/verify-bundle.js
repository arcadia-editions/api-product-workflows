const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const rootDir = path.resolve(__dirname, '..');
const bundlePath = path.join(rootDir, 'dist', 'spectral.js');

async function main() {
  const code = await fs.promises.readFile(bundlePath, 'utf8');
  const remoteImports = code.match(/^\s*import\s+.+from\s+['"]https?:\/\/.+['"];?/gm) || [];

  if (remoteImports.length > 0) {
    throw new Error(`Bundle contains remote ESM imports:\n${remoteImports.join('\n')}`);
  }

  const rulesetModule = await import(pathToFileURL(bundlePath).href);

  if (!rulesetModule.default || typeof rulesetModule.default !== 'object') {
    throw new Error('Bundle default export is not a ruleset object.');
  }

  console.log(`Verified ${path.relative(rootDir, bundlePath)}`);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
