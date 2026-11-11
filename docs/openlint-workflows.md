# OpenLint bundle workflows

This document explains how the shared OpenLint rules bundle is built, validated, retained by CI, and published as an immutable release.

The Spectral bundle workflows and `scripts/artifacts/validate-artifact.sh` stay in place. This path is additive until the artifact workflows are switched over.

## Design

The canonical inputs live under `openlint/`:

- `openlint-rules.yml` and `rules/` contain the ruleset sources.
- `scripts/bundle-openlint.js` generates the browser-compatible bundle.
- `scripts/verify-bundle.js` verifies that the generated module is self-contained, exports a ruleset, and lints the fixtures.
- `scripts/lint-fixtures.js` lints `fixtures/openapi.yml` and `fixtures/catalog-products-api/asyncapi.yml` in one OpenLint invocation. It uses the CLI installed from `tools/`.
- `package.json` and `package-lock.json` define the reproducible bundle build. `esbuild`, the ruleset migrator, and `@openlint/openlint-rulesets` are pinned there. The rulesets package is inlined into the bundle. The OpenLint CLI that runs the bundle is pinned in `tools/package.json`, which is the only CLI version.

`openlint/dist/` is generated output and is ignored on normal branches. In particular, `main` does not require or retain `dist/openlint.js`.

There are two workflows:

- `.github/workflows/openlint-ci.yml` validates changes and retains a temporary build.
- `.github/workflows/openlint-release.yml` creates an immutable tagged bundle.

## What the bundle lints

`openlint-rules.yml` extends both rule files:

- `rules/openapi/openapi-rules.yml` extends `[openlint:openapi, recommended]` and sets `oas3-valid-schema-example` to warn.
- `rules/asyncapi/asyncapi-rules.yml` enables the eight Arcadia `EDA-*` functions. It does not extend the built-in AsyncAPI recommended ruleset.

OpenAPI documents receive the OpenAPI rules. AsyncAPI documents receive the AsyncAPI rules. One published file, `openlint.js`, is the ruleset for both.

`tools/package.json` is the only place that pins the OpenLint CLI and the AsyncAPI CLI. `lib.sh` does not carry those versions. Artifact workflows install that lockfile with `npm ci --ignore-scripts` and call `tools/node_modules/.bin`.

`scripts/artifacts/lint-openlint.sh` downloads `OPENLINT_BUNDLE_URL`, checks it with `sha256sum -c` against `OPENLINT_BUNDLE_SHA256`, and then runs `openlint lint --fail-severity=error` on the local file. It accepts one or more document paths and lints them in a single invocation.

`scripts/artifacts/validate-artifact-openlint.sh` is the parallel of `validate-artifact.sh`:

- `openapi` is linted with OpenLint only. Redocly is not invoked.
- `asyncapi` and `asyncapi-client` are validated with the locked AsyncAPI CLI, then linted with the same OpenLint command. Provider `asyncapi` documents still JSON-parse each referenced `.avsc`.
- `zdl` and `zfl` still use `DslTool`.

`execute-plan.sh` still calls `validate-artifact.sh`. That script now uses the locked AsyncAPI CLI as well. Spectral and Redocly on that path still install through `npx`. Pointing `execute-plan.sh` at `validate-artifact-openlint.sh` is the later swap. That swap passes `OPENLINT_BUNDLE_URL` and `OPENLINT_BUNDLE_SHA256`. OpenLint requires Node.js 22, or 24 and later. The artifact workflows already install Node.js `22.17.0` for the locked CLIs.

## OpenLint CI

OpenLint CI runs for relevant pull requests and pushes to `main`, and it can also be started manually.

The job:

1. Checks out the exact source commit.
2. Verifies that `openlint/package-lock.json` and `tools/package-lock.json` exist.
3. Installs Node.js `22.17.0` and restores the npm cache.
4. Runs `npm ci --ignore-scripts` in `openlint/` and in `tools/`.
5. Generates `openlint/dist/openlint.js`.
6. Runs the bundle verification command, which also lints the fixtures.
7. Generates `openlint/dist/openlint.js.sha256`.
8. Runs `npm run lint:fixtures`.
9. Uploads the bundle and checksum as the workflow artifact `openlint-bundle-{commit-sha}`.

The workflow artifact is retained for seven days. It is intended for inspection, debugging, and testing of that CI run. It is not a release and production consumers must not depend on it.

CI does not compare against a committed bundle. A successful build proves that the bundle can be generated and verified from the committed sources and lock file.

## OpenLint release

The release workflow is started manually with a single input:

- `version`: the release version, for example `0.1.0`.

`openlint/package.json` carries no `version` field. The bundle is built from `openlint-rules.yml`. The release version only ever exists as the manually supplied `version` input and the resulting tag and release name. The first release is `0.1.0`. Its rule source matches Spectral bundle `spectral/v0.1.3`, including Command and Response message suffixes. Tags stay on the `openlint/v*` prefix.

### Release sequence

The workflow performs these operations directly on `main`'s current commit, with no intermediate branches or pull requests:

1. Check out `main`.
2. Validate that `version` is valid semantic versioning and that tag `openlint/v{version}` does not already exist.
3. Run `npm ci --ignore-scripts` in `openlint/` and in `tools/`, build the bundle, and verify it.
4. Generate the checksum.
5. Attest build provenance for `openlint/dist/openlint.js`.
6. Commit the built `openlint/dist/openlint.js` and `openlint/dist/openlint.js.sha256` on top of the checked-out `main` commit, then create and push the annotated tag `openlint/v{version}` pointing at that commit. This commit is only pushed as the tag ref, never as a branch update, so it never joins `main`'s history.
7. Create the GitHub Release from that tag, uploading the bundle and checksum. The release notes include `OPENLINT_BUNDLE_SHA256`.

The release job needs `contents: write` to push the tag, and `id-token: write` plus `attestations: write` to attest the bundle. No pull request is created.

## What is stored where

| Location | Contains `dist/openlint.js` | Lifetime |
| --- | --- | --- |
| `main` | No | Repository history |
| OpenLint CI artifact | Yes | Seven days |
| `openlint/v{version}` tag | Yes | Until the tag is deleted |
| GitHub Release asset | Yes, with checksum | Until the GitHub Release or asset is deleted |

## Accessing a released bundle

A release publishes the same bundle through two stable channels.

### Raw tagged file

For a public repository:

```text
https://raw.githubusercontent.com/{owner}/{repository}/refs/tags/openlint/v{version}/openlint/dist/openlint.js
```

Example:

```text
https://raw.githubusercontent.com/arcadia-editions/api-product-workflows/refs/tags/openlint/v0.1.0/openlint/dist/openlint.js
```

The raw URL resolves through the tag, not through a branch. `lint-openlint.sh` does not trust that URL by itself. It downloads the file and requires `OPENLINT_BUNDLE_SHA256` to match before OpenLint reads it.

Set these organization variables for the `*-api` repositories when the artifact workflows are switched:

- `OPENLINT_BUNDLE_URL` is the raw tag URL.
- `OPENLINT_BUNDLE_SHA256` is the 64-character hex digest from the release notes, or the first field of `openlint.js.sha256`.

Leave `SPECTRAL_BUNDLE_URL` pointed at `spectral/v0.1.3` until that switch has a green full validation.

### Tag protection

Protect `openlint/v*` with a repository tag ruleset that blocks tag updates and tag deletion. Do not restrict creation: the release workflow creates the tag once. If the repository can use immutable releases, enable that too so a published asset cannot be replaced. This checkout does not change those repository settings.

### GitHub Release assets

Each GitHub Release contains:

- `openlint.js`
- `openlint.js.sha256`

The release is created with `--latest=false`, so an OpenLint release does not replace the repository-wide API-product release as the latest release.

## Local build

The CI build can be reproduced locally:

```bash
npm ci --ignore-scripts --prefix openlint
npm ci --ignore-scripts --prefix tools
npm run bundle --prefix openlint
npm run verify:bundle --prefix openlint
sha256sum openlint/dist/openlint.js > openlint/dist/openlint.js.sha256
```

The generated `dist/` directory remains ignored and should not be committed from normal development branches.

Fixture lint uses the CLI from `tools/node_modules`. To lint documents with a bundle you just built, pass that file to the locked CLI. `lint-openlint.sh` is for a published bundle: it requires `OPENLINT_BUNDLE_URL` and `OPENLINT_BUNDLE_SHA256`.

## Invariants

- `main` never requires `openlint/dist/openlint.js`.
- The workflow commits the built bundle so the tag's tree contains it, but that commit is only ever reachable via the tag ref. It is never pushed to `main` or any branch.
- CI artifacts are temporary and are not promoted to releases.
- A release rebuilds from the selected `main` source commit and tags a new commit built on top of it.
- `openlint/package.json` carries no version field. The release version exists only as the workflow input and the resulting tag and release name.
- The OpenLint CLI version and the AsyncAPI CLI version are pinned only in `tools/package.json`.
- Release tags are immutable distribution references.
- `spectral/v*` tags and `docs/spectral-workflows.md` stay as they are.
