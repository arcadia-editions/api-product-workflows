const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const rootDir = path.resolve(__dirname, '..');
const bundlePath = path.join(rootDir, 'dist', 'openlint.js');

async function main() {
  const code = await fs.promises.readFile(bundlePath, 'utf8');
  const remoteImports = code.match(/^\s*import\s+.+from\s+['"]https?:\/\/.+['"];?/gm) || [];

  if (remoteImports.length > 0) {
    throw new Error(`Bundle contains remote ESM imports:\n${remoteImports.join('\n')}`);
  }

  // Import a .mjs copy so Node does not warn that the package has no "type".
  const tempBundle = path.join(os.tmpdir(), `openlint-ruleset-${process.pid}.mjs`);
  await fs.promises.copyFile(bundlePath, tempBundle);
  let rulesetModule;
  try {
    rulesetModule = await import(pathToFileURL(tempBundle).href);
  } finally {
    await fs.promises.rm(tempBundle, { force: true });
  }

  if (!rulesetModule.default || typeof rulesetModule.default !== 'object') {
    throw new Error('Bundle default export is not a ruleset object.');
  }

  const lint = spawnSync(process.execPath, [path.join(__dirname, 'lint-fixtures.js')], { stdio: 'inherit' });
  if (lint.error) {
    throw lint.error;
  }
  if (lint.status !== 0) {
    throw new Error(`Fixture lint exited with status ${lint.status}`);
  }

  console.log(`Verified ${path.relative(rootDir, bundlePath)}`);
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
