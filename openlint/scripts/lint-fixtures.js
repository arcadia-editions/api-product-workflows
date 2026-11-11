const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const rootDir = path.resolve(__dirname, '..');
const bundlePath = path.join(rootDir, 'dist', 'openlint.js');
const fixtures = [
  path.join(rootDir, 'fixtures', 'openapi.yml'),
  path.join(rootDir, 'fixtures', 'catalog-products-api', 'asyncapi.yml'),
];

function main() {
  const cli = path.join(rootDir, '..', 'tools', 'node_modules', 'openlint', 'dist', 'index.js');
  if (!fs.existsSync(cli)) {
    throw new Error('Locked OpenLint CLI is missing. Run npm ci --ignore-scripts in tools/.');
  }
  const result = spawnSync(
    process.execPath,
    [cli, 'lint', '--fail-severity=error', '-r', bundlePath, ...fixtures],
    {
      stdio: 'inherit',
      // The service-identity rule compares GITHUB_REPOSITORY with the provider
      // repository derived from the AsyncAPI id. Pin it to the fixture's
      // provider so the result does not depend on where the fixtures run.
      env: { ...process.env, GITHUB_REPOSITORY: 'arcadia-editions/catalog-products-api' },
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    process.exitCode = result.status === null ? 1 : result.status;
  }
}

try {
  main();
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
