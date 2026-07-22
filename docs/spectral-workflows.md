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

The release workflow is started manually with two inputs:

- `version`: the release version, for example `0.1.0`.
- `development-version`: the next version ending in `-SNAPSHOT`, for example `0.2.0-SNAPSHOT`.

The version on `main` must initially match `{version}-SNAPSHOT`. For the example above, `main` must contain `0.1.0-SNAPSHOT`.

### Pull-request authentication

The workflow pushes the temporary `release/spectral/v{version}` branch, creates its pull request, and merges it using the job's `GITHUB_TOKEN`. No personal access token or separate release token is required.

The job grants `contents: write` and `pull-requests: write`. Repository or organization policy must also enable **Settings > Actions > General > Workflow permissions > Allow GitHub Actions to create and approve pull requests**. This policy is independent of the permissions declared in the workflow; when it is disabled, GitHub rejects `gh pr create` with the `createPullRequest` GraphQL error.

The workflow does not use GitHub's native auto-merge feature. It periodically attempts an immediate `gh pr merge --merge` and succeeds once branch-protection requirements are satisfied. If GitHub requires manual approval for workflow runs or pull-request reviews, the release job waits for that approval.

The workflow never commits or pushes directly to `main`. Both version commits are made directly on temporary branches. The `release/spectral/v{version}` branch reaches `main` only through its pull request, so branch protection remains authoritative.

### Branching model

The release commit and next-development commit are independent children of the same `main` base commit `B`:

```text
                           spectral/v0.1.0
                                  |
                                  v
                    R  release 0.1.0
                   /   package.json + package-lock.json
                  /    dist/spectral.js
                 /
                B  main: 0.1.0-SNAPSHOT, no dist
                 \
                  \
                   D  release/spectral/v0.1.0
                   |  prepare 0.2.0-SNAPSHOT, no dist
                    \
                     M  merge commit on main
```

`R` is never merged into `main`. It is retained by the `spectral/v0.1.0` tag.

`D` is created from `B`, not from `R`. It is committed directly on `release/spectral/v{version}` and merged into `main` through the normal pull-request and branch-protection process. A successful merge deletes this temporary branch. A stale branch left by a failed attempt must be deleted before retrying the same release. Consequently, neither `D` nor the resulting `main` contains `dist/spectral.js`, and no follow-up deletion commit is necessary.

### Release sequence

The workflow performs these operations:

1. Check out `main` and record its commit as `B`.
2. Validate the release version, next-development version, current package version, and absence of the target tag.
3. Create a temporary local release branch from `B`.
4. Change the package version to the release version.
5. Update the lock file, run `npm ci`, build the bundle, and verify it.
6. Force-add the ignored `spectral/dist/spectral.js` and create release commit `R`.
7. Return to `B` and create `release/spectral/v{version}`.
8. Change the package version to the requested next snapshot.
9. Update the lock file, build and verify again, and remove only the generated working-tree copy of the bundle.
10. Commit `package.json` and `package-lock.json` as `D`; `dist/` remains absent from the commit.
11. Push `release/spectral/v{version}` and merge its pull request into `main`.
12. Verify that `R` is a direct child of `B` and that `D` is present in the freshly fetched `main`.
13. Create and push the annotated tag `spectral/v{version}` pointing to `R`.
14. Check out `R`, generate the checksum, and create the GitHub Release.

The temporary release branch is local to the workflow runner and is never pushed. When the runner disappears, the tag continues to keep `R` and its bundle reachable.

## What is stored where

| Location | Version | Contains `dist/spectral.js` | Lifetime |
| --- | --- | --- | --- |
| Pull request or `main` | Snapshot | No | Repository history |
| Spectral CI artifact | Source commit under test | Yes | Seven days |
| `spectral/v{version}` tag | Release | Yes | Until the tag is deleted |
| GitHub Release asset | Release | Yes, with checksum | Until the GitHub Release or asset is deleted |

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
- The workflow never commits or pushes directly to `main`; only the `release/spectral/v{version}` pull-request merge changes `main`.
- CI artifacts are temporary and are not promoted to releases.
- A release rebuilds from the selected `main` source commit.
- The release tag points to the isolated release commit, not to `main`, the next-development commit, or the merge commit.
- The `release/spectral/v{version}` branch starts from the same `main` base as the isolated release commit.
- Only the tagged release commit contains the committed bundle.
- Release tags are immutable distribution references.
