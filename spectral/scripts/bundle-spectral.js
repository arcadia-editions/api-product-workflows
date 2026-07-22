const fs = require('node:fs');
const path = require('node:path');
const esbuild = require('esbuild');
const { migrateRuleset } = require('@stoplight/spectral-ruleset-migrator');

const rootDir = path.resolve(__dirname, '..');
const inputYml = path.join(rootDir, 'spectral-rules.yml');
const outputJs = path.join(rootDir, 'dist', 'spectral.js');

// Stub Node.js built-ins that some Spectral deps reference but that are
// never exercised in the browser ruleset execution path.
function browserCompatStubs() {
  return {
    name: 'browser-compat-stubs',
    setup(build) {
      build.onResolve({ filter: /^(fs|node:fs)$/ }, () => ({ path: 'fs-stub', namespace: 'stub' }));
      build.onLoad({ filter: /^fs-stub$/, namespace: 'stub' }, () => ({
        contents: 'export default {}; export const promises = {};',
        loader: 'js',
      }));

      build.onResolve({ filter: /^(buffer|node:buffer)$/ }, () => ({ path: 'buffer-stub', namespace: 'stub' }));
      build.onLoad({ filter: /^buffer-stub$/, namespace: 'stub' }, () => ({
        contents: [
          'export class Buffer extends Uint8Array {',
          '  static from(v) { return new TextEncoder().encode(String(v)); }',
          '  static isBuffer() { return false; }',
          '}',
          'export default { Buffer };',
        ].join('\n'),
        loader: 'js',
      }));
    },
  };
}

async function main() {
  // Step 1: Convert the YAML ruleset (and all its local extends/functions) to
  // an in-memory ESM string.  migrateRuleset is the canonical Spectral tool for
  // this; it handles YAML parsing, extends resolution, and function wiring.
  const migratedSource = await migrateRuleset(inputYml, { format: 'esm', fs });

  // Step 2: Bundle everything into a single self-contained browser ESM file.
  // esbuild resolves:
  //   - relative .js function imports  (resolveDir)
  //   - npm packages (spectral-rulesets, jsonpath-plus, …) from node_modules
  //   - CJS ↔ ESM interop for all of the above
  const { outputFiles } = await esbuild.build({
    stdin: {
      contents: migratedSource,
      resolveDir: rootDir,
      sourcefile: '.spectral.virtual.js',
      loader: 'js',
    },
    bundle: true,
    platform: 'browser',
    format: 'esm',
    target: ['es2020'],
    write: false,
    logLevel: 'warning',
    mainFields: ['browser', 'module', 'main'],
    conditions: ['browser', 'import', 'default'],
    banner: { js: 'globalThis.self ??= globalThis; globalThis.window ??= globalThis;' },
    plugins: [browserCompatStubs()],
  });

  await fs.promises.mkdir(path.dirname(outputJs), { recursive: true });
  await fs.promises.writeFile(outputJs, outputFiles[0].text, 'utf8');

  console.log(`Bundled ${path.relative(rootDir, inputYml)} -> ${path.relative(rootDir, outputJs)}`);
}

main().catch(err => { console.error(err); process.exitCode = 1; });
