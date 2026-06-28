# Spectral bundle workflows

This document explains how the shared Spectral rules bundle is built, validated, retained by CI, and published as an immutable release.

## Design

The canonical inputs live under `spectral/`:

- `spectral-rules.yml` and `rules/` contain the ruleset sources.
- `scripts/bundle-spectral.js` generates the browser-compatible bundle.
- `scripts/verify-bundle.js` verifies that the generated module is self-contained and exports a ruleset.
- `package.json` and `package-lock.json` define the reproducible Node.js build.

`spectral/dist/` is generated output and is ignored on normal branches. In particular, `main` does not require or retain `dist/spectral.js`.

There are two workflows:

- `.github/workflows/spectral-ci.yml` validates changes and retains a temporary build.
- `.github/workflows/spectral-release.yml` creates an immutable tagged bundle and the next development version.

## Spectral CI

Spectral CI runs for relevant pull requests and pushes to `main`, and it can also be started manually.

The job:

1. Checks out the exact source commit.
2. Verifies that `spectral/package-lock.json` exists.
3. Installs the pinned Node.js version and restores the npm cache.
4. Runs `npm ci`.
5. Generates `spectral/dist/spectral.js`.
6. Runs the bundle verification command.
7. Generates `spectral/dist/spectral.js.sha256`.
8. Runs the fixture lint suite when the package defines one.
9. Uploads the bundle and checksum as the workflow artifact `spectral-bundle-{commit-sha}`.

The workflow artifact is retained for seven days. It is intended for inspection, debugging, and testing of that CI run. It is not a release and production consumers must not depend on it.

CI does not compare against a committed bundle. A successful build proves that the bundle can be generated and verified from the committed sources and lock file.

## Spectral release

The release workflow is started manually with a single input:

- `version`: the release version, for example `0.1.0`.

`spectral/package.json` carries no `version` field. Nothing reads it: the bundle is built purely from `spectral-rules.yml`, `validate-artifact.sh` always rebuilds from source, and the two distribution channels below key off the git tag name, not any committed version metadata. The release version only ever exists as the manually supplied `version` input and the resulting tag/release name.

### Release sequence

The workflow performs these operations directly on `main`'s current commit, with no intermediate branches or pull requests:

1. Check out `main`.
2. Validate that `version` is valid semantic versioning and that tag `spectral/v{version}` does not already exist.
3. Run `npm ci`, build the bundle, and verify it.
4. Generate the checksum.
5. Commit the built `spectral/dist/spectral.js` and `spectral/dist/spectral.js.sha256` on top of the checked-out `main` commit, then create and push the annotated tag `spectral/v{version}` pointing at that commit. This commit is only pushed as the tag ref, never as a branch update, so it never joins `main`'s history.
6. Create the GitHub Release from that tag, uploading the bundle and checksum.

The job only needs `contents: write` to push the tag — no pull request is created, so no branch-protection or "Allow GitHub Actions to create and approve pull requests" setting is involved.

## What is stored where

| Location | Contains `dist/spectral.js` | Lifetime |
| --- | --- | --- |
| `main` | No | Repository history |
| Spectral CI artifact | Yes | Seven days |
| `spectral/v{version}` tag | Yes | Until the tag is deleted |
| GitHub Release asset | Yes, with checksum | Until the GitHub Release or asset is deleted |

## Accessing a released bundle

A release publishes the same bundle through two stable channels.

### Raw tagged file

For a public repository:

```text
https://raw.githubusercontent.com/{owner}/{repository}/refs/tags/spectral/v{version}/spectral/dist/spectral.js
```

Example:

```text
https://raw.githubusercontent.com/arcadia-editions/api-product-workflows/refs/tags/spectral/v0.1.0/spectral/dist/spectral.js
```

The raw URL resolves through the tag, not through a branch. Deleting a temporary branch does not affect it. Deleting or moving the tag would affect it, so release tags must be treated as immutable.

### GitHub Release assets

Each GitHub Release contains:

- `spectral.js`
- `spectral.js.sha256`

The release is created with `--latest=false`, so a Spectral release does not replace the repository-wide API-product release as the latest release.

## Local build

The CI build can be reproduced locally:

```bash
cd spectral
npm ci
npm run bundle
npm run verify:bundle
cd dist
sha256sum spectral.js > spectral.js.sha256
```

The generated `dist/` directory remains ignored and should not be committed from normal development branches.

## Invariants

- `main` never requires `spectral/dist/spectral.js`.
- The workflow commits the built bundle so the tag's tree contains it, but that commit is only ever reachable via the tag ref — it is never pushed to `main` or any branch.
- CI artifacts are temporary and are not promoted to releases.
- A release rebuilds from the selected `main` source commit and tags a new commit built on top of it.
- `spectral/package.json` carries no version field; the release version exists only as the workflow input and the resulting tag/release name.
- Release tags are immutable distribution references.
