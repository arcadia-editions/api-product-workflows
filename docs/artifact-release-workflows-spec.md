# Arcadia Editions Artifact CI, Snapshot, and Release Workflows

- Status: implementation specification
- Pilot repository: `arcadia-editions/orders-checkout-api`
- Shared workflow repository: `arcadia-editions/api-product-workflows`

## 1. Purpose

This document specifies reusable GitHub Actions workflows for validating, packaging, snapshotting, and releasing the independently versioned artifacts stored in Arcadia Editions `*-api` repositories.

The workflows are themselves maintained in `api-product-workflows`. Each API-product repository contains only thin caller workflows, artifact source files, and the minimum local version metadata that cannot be embedded in an artifact.

The pilot implementation targets `orders-checkout-api`. It must be proven there before being rolled out to the other API-product repositories.

Normative terms such as **MUST**, **MUST NOT**, **SHOULD**, and **MAY** describe implementation requirements.

## 2. Goals

- Release ZDL, OpenAPI, AsyncAPI plus Avro, and the complete API-product repository on independent release trains.
- Use prefixed Git tags so releases of different artifact families can coexist in one Git repository.
- Validate only the artifact families affected by a change.
- Publish snapshots only from a trusted branch after CI succeeds.
- Build Maven-compatible JARs with the JDK `jar` command, without introducing project POMs.
- Install and deploy those JARs with `maven-install-plugin:install-file` and `maven-deploy-plugin:deploy-file`.
- Resolve Maven coordinates from `zenwave-architecture.yml` using `manifest-core` semantics.
- Keep Artifactory generic repositories as a documented publication placeholder for versioned, browsable trees of repository-relative files until a server is available for integration testing.
- Register OpenAPI and AsyncAPI artifacts in Apicurio Registry using the Maven plugin in CLI mode.
- Use the API document's `info.version` as the Apicurio version source.
- Create GitHub Releases for immutable releases.
- Update released versions in `arcadia-editions-docs/zenwave-architecture.yml` through a cross-repository pull request.
- Build, verify, version, and publish the shared Spectral rules bundle.
- Generate and publish separate development and released EventCatalog sites from the complete architecture manifest.
- Keep release mechanics common while isolating artifact-specific validation, versioning, packaging, and publication behavior.
- Apply least privilege to GitHub permissions and publication credentials.

## 3. Non-goals

- CI and release workflows MUST NOT generate OpenAPI, AsyncAPI, Avro, or committed application source code from ZDL.
- The workflows MUST NOT modify generated API files as a side effect of validation.
- ZDL-to-API generation remains an explicit developer-triggered activity outside these workflows.
- Future Spring Boot services that implement the APIs are outside this specification.
- Kafka and Terraform provisioning remains a separate deployment lifecycle. It may consume a released AsyncAPI artifact, but it is not part of an artifact release transaction.
- This specification does not require a Maven project or committed POM in an API-product repository. Minimal POM metadata generated transiently by Maven install/deploy goals is allowed.
- Publishing to Maven Central is outside the pilot scope.
- Production deployment to an Artifactory server is outside the pilot acceptance gate until a test server exists; file-backed Maven repository deployment is required instead.
- Automatically merging architecture-manifest pull requests is outside the pilot scope.

## 4. Terminology

- **API-product repository**: a repository such as `orders-checkout-api` containing domain and API artifacts. It is not a Spring Boot service implementation.
- **Service or full-repository release**: the `api-product` release family containing the curated API-product repository. This is the only family eligible for GitHub's repository-wide latest marker.
- **Artifact family**: one independently versioned and released product: `zdl`, `openapi`, `asyncapi`, or `api-product`.
- **AsyncAPI bundle**: `asyncapi.yml`, optional `asyncapi-client.yml`, and every owned, tracked Avro schema matching `**/*.avsc`, regardless of its containing folder.
- **Release version**: a semantic version without a leading `v`, for example `1.2.0` or `1.2.0-rc.1`.
- **Development version**: the next version ending in `-SNAPSHOT`, for example `1.3.0-SNAPSHOT`.
- **Snapshot**: a mutable development publication from the trusted branch. It is never represented in the architecture manifest.
- **Release**: an immutable publication identified by a prefixed Git tag and GitHub Release.
- **Development catalog**: the full EventCatalog generated from the latest trusted Git content for every service in the manifest.
- **Released catalog**: the full EventCatalog generated from manifest-selected released Maven artifacts, with Git fallback only for content that has no Maven-capable source, such as service documentation. Apicurio remains a parallel publication target, not the catalog's authoritative content source.

## 5. Core architectural decisions

### 5.1 Workflows are separated by lifecycle, not duplicated by artifact

The implementation MUST provide common reusable workflow engines for:

1. CI validation and packaging.
2. Snapshot publication.
3. Manual release orchestration.
4. Architecture-manifest pull requests.

Artifact type is controlled data supplied to those engines. Artifact-specific behavior is implemented by shared scripts or actions selected from a closed mapping. The workflows MUST NOT accept arbitrary commands, paths, tag prefixes, registry types, or publication destinations from a caller.

CI and trusted-branch snapshot workflows infer **all** affected artifact families from the changed files and process them through one parameterized runner loop. They MUST NOT create separate copied workflows or statically expanded blocks per artifact family. A dynamic GitHub Actions matrix is not the primary execution model for the pilot; the shared runner performs the loop inside one job so common setup, validation gates, packaging, and publication ordering remain visible as one lifecycle run.

Manual release is intentionally different: it releases exactly one artifact family per invocation. The release caller MUST require an `artifact` choice and MUST NOT infer or automatically add other release trains, even when other families have unreleased changes. This preserves independent versions, tags, GitHub Releases, and manifest updates without duplicating the release implementation.

### 5.2 CI and release remain separate security boundaries

Pull-request CI is read-only and receives no publication credentials. Snapshot and release publication execute only from trusted repository content. Release jobs receive credentials only after validation and any configured GitHub Environment approval.

### 5.3 `main` is the pilot's trusted development branch

The pilot uses `main` as its pull-request target and snapshot branch. The artifact workflows do not introduce a `develop` branch. Existing Kafka provisioning behavior for `develop` is a separate concern and is not changed by this specification.

### 5.4 The repository stores development versions

After a release, the selected artifact family is advanced to its next `-SNAPSHOT` version in source control. The release tag points to the preceding release-version commit.

### 5.5 Manifest versions are authoritative for released architecture content

The published ZenWave architecture schema supports `artifact.version`. It does not support an artifact `tag` property. The architecture update therefore stores only the released version. The tag is deterministic from the artifact family and version.

### 5.6 Maven coordinates come from the architecture manifest

The workflows MUST use the same coordinate precedence and expression evaluation as `manifest-core`:

```text
groupId    = service.groupId, otherwise config.groupIdExpression
artifactId = artifact.artifactId, otherwise config.artifactIdExpression
```

For the current Arcadia manifest this normally produces:

```text
groupId    = com.arcadiaeditions.${service.id}
artifactId = ${artifact.fileNameWithoutExtension}
```

The workflow MUST NOT duplicate these expressions in shell code or derive coordinates independently. A pinned `manifest-core`-based resolver MUST load the manifest, select the service and artifact, and return the resolved group ID, artifact ID, manifest effective version, and artifact path.

`manifest-core` resolves an artifact's effective consumer version in this order: artifact, service, subdomain, then domain. That inherited version is authoritative when consuming the released architecture. It is intentionally **not** the version used while producing a new release, because the central manifest still names the previous release until the synchronization PR is merged. Producer workflows use the selected artifact's canonical source version as the Maven deployment version and verify that the manifest PR will make the consumer-side effective version equal to it.

### 5.7 Event catalogs are fully regenerated in two channels

The ZenWave `EventCatalogPlugin` reads the complete architecture manifest and enriches the catalog with AsyncAPI, OpenAPI, ZDL, and service documentation. Both catalogs are full rebuilds in the pilot. Partial regeneration is deferred until full regeneration proves too slow.

- The development catalog follows trusted `main` content through the manifest's Git source.
- The released catalog follows versions recorded in the manifest and loads artifact content from Maven before falling back to Git for non-versioned documentation. Apicurio publication is independently verified during release.

## 6. Artifact catalog

| Family | Pilot source set | Canonical version source | Tag | Maven artifacts | Apicurio |
| --- | --- | --- | --- | --- | --- |
| `zdl` | `domain-model.zdl` | `.arcadia/versions/zdl.version` | `zdl/v{version}` | Manifest `zdl` artifact | No |
| `openapi` | `openapi.yml` | `openapi.yml#/info/version` | `openapi/v{version}` | Manifest `openapi` artifact | `OPENAPI` |
| `asyncapi` | `asyncapi.yml`, `asyncapi-client.yml`, `**/*.avsc` | `asyncapi.yml#/info/version` | `asyncapi/v{version}` | Manifest `asyncapi` and `asyncapi-client` artifacts | `ASYNCAPI` |
| `api-product` | Complete curated repository source package plus `.arcadia/api-product.yml` | `.arcadia/api-product.yml#/version` | `api-product/v{version}` | Manifest `api-product` artifact | No |
| `spectral` | `spectral/spectral-rules.yml`, `spectral/rules/**`, bundle scripts | `spectral/package.json#/version` | `spectral/v{version}` | None in the pilot | No |

For the AsyncAPI family, `asyncapi-client.yml#/info/version` MUST equal `asyncapi.yml#/info/version`. The release workflow updates both. One release operation produces an `asyncapi` JAR containing `asyncapi.yml` and all owned files matching `**/*.avsc` at their repository-relative paths, plus a separate `asyncapi-client` JAR when that manifest artifact exists. This matches `manifest-core`, which resolves each manifest artifact from its own Maven coordinate.

Avro schemas do not have an independent release train in the pilot. A change to any owned Avro schema releases and versions the AsyncAPI bundle.

Avro discovery MUST operate on the trusted commit's source-file inventory, not on a hard-coded directory or an unrestricted post-build filesystem walk. It includes tracked source files matching `**/*.avsc` and preserves each match's repository-relative path. Generated or ignored files appearing later under directories such as `target/`, `build/`, or `node_modules/` MUST NOT enter validation or packaging accidentally. Additions, modifications, renames, and deletions of matching files participate in change detection.

Before enabling snapshot publication in the pilot, implementation MUST audit existing tags and published artifacts and establish explicit initial development versions. It MUST NOT guess that the currently checked-in versions have already been released.

## 7. Expected repository structure

### 7.1 Shared workflow repository

The implementation is expected to add the following logical components to `api-product-workflows`:

```text
.github/workflows/
  artifact-ci.yml
  artifact-snapshot.yml
  artifact-release.yml
  architecture-manifest-pr.yml
  spectral-ci.yml
  spectral-release.yml
  event-catalog.yml

scripts/artifacts/
  detect-changes.sh
  resolve-artifact.sh
  read-version.sh
  set-version.sh
  validate-artifact.sh
  resolve-manifest-coordinates.sh
  package-maven-jar.sh
  deploy-maven-artifact.sh
  publish-apicurio.sh
  generate-event-catalog.sh
  verify-release-inputs.sh
  update-architecture-manifest.sh
```

File names MAY change during implementation, but the responsibilities and boundaries MUST remain.

### 7.2 Pilot repository

The pilot is expected to add:

```text
.arcadia/versions/
  zdl.version

.arcadia/
  api-product.yml

.github/workflows/
  artifacts.yml
  release-artifact.yml

release-notes/                  # optional; created only when human-authored notes exist
  openapi/
    release-notes.v1.2.0.md
  asyncapi/
    release-notes.v1.2.0.md
```

`artifacts.yml` is the thin pull-request, push, and snapshot caller. `release-artifact.yml` is the thin manual release caller. Both call immutable versions of workflows in `api-product-workflows`.

Caller workflows MUST pin the shared workflow by a full commit SHA or immutable release tag. Production callers MUST NOT use `@main`.

### 7.3 Architecture repository

`arcadia-editions-docs` adds only a thin receiver/caller:

```text
.github/workflows/
  event-catalog.yml
```

It handles the repository-local triggers and delegates generation to the immutable reusable workflow in `api-product-workflows`. EventCatalog generation logic MUST NOT be copied into the docs repository.

## 8. Change detection

### 8.1 Path mapping

The shared CI workflow MUST detect changes relative to the pull-request base SHA or push-before SHA and produce a JSON array of affected artifact families.

| Changed path | Affected family |
| --- | --- |
| `domain-model.zdl` | `zdl`, `api-product` |
| `.arcadia/versions/zdl.version` | `zdl`, `api-product` |
| `openapi.yml` | `openapi`, `api-product` |
| `asyncapi.yml` | `asyncapi`, `api-product` |
| `asyncapi-client.yml` | `asyncapi`, `api-product` |
| `**/*.avsc` | `asyncapi`, `api-product` |
| `.arcadia/api-product.yml` | `api-product` |
| `README.md`, `SUMMARY.md`, `CHANGELOG.md` | `api-product` |
| `release-notes/**` | No artifact family; release-readiness validation only |
| API-product packaging metadata | `api-product` |

Workflow-only changes in the pilot MUST run all validation routines but MUST NOT publish snapshots unless artifact content or a canonical artifact version changed.

### 8.2 Detection requirements

- Renames, additions, modifications, and deletions MUST be detected.
- For a merge or push to `main`, the plan is built from the complete `github.event.before..github.sha` diff, so all files introduced by the merged pull request or pushed commit range participate in the same run.
- An all-zero push-before SHA MUST fall back to comparing the pushed commit with its first parent or the merge base with the default branch.
- Change detection MUST be implemented in the trusted shared workflow repository, not in mutable pull-request scripts.
- Detected types MUST be deduplicated, put in the stable order `zdl`, `openapi`, `asyncapi`, `api-product`, and validated against that closed set before execution.
- Multiple affected families MUST all be validated. The validation loop records each result and fails only after attempting every selected family, so one validation failure does not hide another.
- If any validation fails, the workflow MUST skip packaging and publication for the entire detected plan.

### 8.3 Artifact execution plan

Change detection produces one trusted JSON execution plan rather than a single inferred type. For example, a merged pull request that changes `openapi.yml`, `asyncapi.yml`, and Avro schemas produces the equivalent of:

```json
[
  { "type": "openapi", "changedFiles": ["openapi.yml"] },
  { "type": "asyncapi", "changedFiles": ["asyncapi.yml", "schemas/events/OrderCreated.avsc"] },
  { "type": "api-product", "changedFiles": ["openapi.yml", "asyncapi.yml", "schemas/events/OrderCreated.avsc"] }
]
```

The aggregate `api-product` entry is included because its curated package changed. This inclusion applies to CI and snapshots only; it does not implicitly create an API-product release.

The shared repository owns a closed descriptor for each type containing its source paths, canonical version reader, validator, JAR inclusion rules, generic-tree inclusion rules, Apicurio artifact definitions, tag prefix, and manifest update selector. Plan data names a type and changed files only; it MUST NOT contain executable commands supplied by the caller.

The executor implements conceptual lifecycle functions such as:

```bash
for artifact in "${affected_artifacts[@]}"; do
  validate_artifact "$artifact" || record_validation_failure "$artifact"
done
assert_no_validation_failures

for artifact in "${affected_artifacts[@]}"; do
  package_maven_jar "$artifact"
  stage_generic_tree "$artifact"
done
```

GitHub Actions cannot dynamically repeat arbitrary YAML steps without expanding jobs. The implementation therefore keeps orchestration in a reviewed shared script or composite action and invokes the artifact-specific functions using the trusted descriptor. Logs and step summaries MUST still report results separately for each artifact family.

## 9. CI workflow

### 9.1 Triggers

The pilot caller runs CI on:

- `pull_request` targeting `main` for relevant paths.
- `push` to `main` for relevant paths.
- `workflow_dispatch` for a full validation rerun without publication.

### 9.2 Common CI sequence

1. Check out the exact caller commit without persisted credentials.
2. Check out the pinned `api-product-workflows` revision into a separate directory.
3. Detect all affected artifact families and construct the stable execution plan.
4. Resolve trusted artifact descriptors from the shared mapping.
5. Loop over every planned family and run validation, collecting all validation failures.
6. Stop the lifecycle before packaging if any family failed validation.
7. Loop over every planned family, resolve its Maven coordinates through the pinned manifest resolver, and create its JAR package with the JDK `jar` command.
8. Loop over the produced JARs, deploy them to an isolated file-backed Maven repository with `maven-deploy-plugin:deploy-file`, and resolve their declared paths through `manifest-core` as an integration test.
9. Loop over the planned families and stage their selected files in the proposed generic Artifactory tree layout without performing a remote upload.
10. Upload CI packages and staged generic trees as short-lived GitHub Actions artifacts for inspection.
11. Return the complete validated artifact-family list and package paths to the caller.

CI MUST NOT create commits, tags, GitHub Releases, remote registry versions, remote Maven objects, generic Artifactory objects, or architecture-manifest pull requests. Deployment to an isolated file-backed Maven repository is a local integration test, not publication.

### 9.3 Artifact-specific validation

#### ZDL

- Confirm the canonical file exists and is non-empty.
- Parse it with a pinned ZenWave ZDL parser or validator.
- Fail on syntax or semantic validation errors supported by that validator.
- MUST NOT run ZDL-to-OpenAPI or ZDL-to-AsyncAPI generation.
- MUST NOT compare generated APIs with checked-in APIs.

If no standalone pinned ZDL validator is available during pilot implementation, that is a blocking dependency for claiming ZDL semantic validation. The implementation MUST NOT silently substitute API generation as validation.

#### OpenAPI

- Parse the document as YAML.
- Confirm `openapi.yml#/info/version` is present and is a valid release or `-SNAPSHOT` semantic version.
- Run Spectral using the bundle built from the pinned shared-workflow revision.
- Resolve local references and fail on missing files or invalid JSON Pointers.
- Produce an OpenAPI-only Maven JAR with `openapi.yml` stored at its manifest-declared path.

#### AsyncAPI and Avro

- Parse `asyncapi.yml` and optional `asyncapi-client.yml` as YAML.
- Confirm both AsyncAPI versions match when the client file exists.
- Run Spectral on each AsyncAPI document.
- Discover and parse every owned, tracked `**/*.avsc` file as JSON, without assuming an `avro/` directory.
- Resolve every local Avro `$ref` from the referencing AsyncAPI document's location and fail if the referenced file is missing. Resolution MUST accept any matching repository-relative `**/*.avsc` path and MUST NOT prepend or require an `avro/` directory.
- Reject unreferenced owned schemas only if that policy is explicitly enabled; warnings are sufficient for the pilot.
- Produce an `asyncapi` Maven JAR containing `asyncapi.yml` and owned Avro schemas at their repository-relative paths.
- Produce a separate `asyncapi-client` Maven JAR when that manifest artifact exists.

#### API product

- Confirm the expected artifact files and documentation files exist.
- Read and validate all four canonical versions.
- Generate `META-INF/arcadia/artifact-metadata.json` describing the repository commit and contained artifact versions.
- Produce a curated source JAR. It MUST exclude `.git/`, `.github/`, `target/`, `.terraform/`, IDE files, secrets, generated plans, and local environment files.

## 10. Snapshot publication

### 10.1 Trigger and trust boundary

Snapshot publication runs only after CI succeeds for a `push` to `main`, or through an explicitly authorized manual dispatch against `main`.

The snapshot runner MUST consume the affected artifact list produced by CI. It MUST NOT recompute changes from untrusted scripts in the API-product repository.

### 10.2 Snapshot requirements

Snapshot publication consumes the complete CI execution plan and uses the same single-job loop. It MUST first validate every family, then package every family, and only then enter the publication phase. The publication loop processes each family exactly once in stable plan order.

For each selected family:

- Its canonical version MUST end in `-SNAPSHOT`.
- Snapshots MUST NOT create Git tags or GitHub Releases.
- Snapshots MUST NOT update `zenwave-architecture.yml`.
- Maven snapshots are mutable by design. Until a remote Maven repository is available, the workflow deploys them into a fresh file-backed Maven repository and uploads that repository as a workflow artifact for verification.
- The workflow also stages the generic file tree. If generic snapshot publication is later enabled, it uploads that tree to the configured snapshot repository; otherwise the tree remains a workflow artifact only.
- Every snapshot JAR MUST include the source commit SHA in `META-INF/arcadia/artifact-metadata.json`.
- Snapshot publication MUST use an environment or credentials distinct from immutable release publication.
- A snapshot rerun for the same commit and version MUST be idempotent.

External publication cannot be made atomic across Maven, generic Artifactory, and Apicurio or across multiple artifact families. If publication fails after another family was published, the run fails with a per-family publication summary. A rerun MUST safely skip identical completed outputs and continue the incomplete work; it MUST NOT roll back valid snapshots from another family.

### 10.3 Apicurio snapshot behavior

For OpenAPI and AsyncAPI snapshots, the workflow invokes the pinned Apicurio Registry Maven Plugin directly from the CLI. No POM is required.

The workflow MUST use:

- `artifacts.versionStrategy=API_INFO_VERSION`
- `artifacts.ifExists=FIND_OR_CREATE_VERSION`
- `artifacts.autoRefs=true`
- `artifacts.artifactType=OPENAPI` or `ASYNCAPI` from the trusted mapping

With `API_INFO_VERSION`, an `info.version` ending in `-SNAPSHOT` is registered without that suffix as a `DRAFT`. Repeated snapshots update that draft. The release of the same base version promotes the content to `ENABLED`.

The AsyncAPI iteration of the snapshot runner registers `asyncapi.yml` and, when present, `asyncapi-client.yml` as separate Apicurio artifacts with the same bundle version. Owned Avro references are handled according to the pinned plugin's `autoRefs` behavior. Absolute references outside the configured registry remain external and MUST NOT be rewritten by CI.

## 11. Release workflow

### 11.1 Manual inputs

An immutable release begins only when an authorized user intentionally opens the API-product repository's **Actions** page, selects the artifact release workflow, chooses `main`, supplies all required inputs, and clicks **Run workflow**. The caller is triggered by `workflow_dispatch`; merges, pushes, CI completion, snapshots, and detected file changes MUST NOT start an immutable release automatically.

The pilot release caller MUST require exactly these inputs:

| Input | Required | Description |
| --- | --- | --- |
| `artifact` | Yes | The single artifact type to release. Choice: `zdl`, `openapi`, `asyncapi`, `api-product` |
| `version` | Yes | Release version without `v` or family prefix |
| `development-version` | Yes | Explicit next development version ending in `-SNAPSHOT` |

The caller supplies fixed service metadata such as `orders-checkout-api` and `orders.checkout.orders-checkout`; users MUST NOT type these values for each release.

The workflow MUST NOT derive or default either version. Requiring the user to enter the release version and next development version preserves the intentional two-version release model used by the ZenWave workflows and makes the planned version transition visible before any write occurs.

`artifact` is always explicit for a release. The workflow performs one release transaction for that selected type and its owned package set. For example, selecting `asyncapi` also packages the associated Avro schemas and `asyncapi-client` artifact, but it does not release `openapi` or `api-product`. If the branch contains unreleased changes for other families, the workflow reports them as informational warnings and leaves them for separate intentional release runs.

The release workflow MUST NOT consume the multi-family CI plan as a request to release every detected family. It reruns validation for the selected family and may run read-only cross-artifact consistency checks, but it creates exactly one version transition, tag prefix, GitHub Release, and architecture-manifest update per invocation.

### 11.2 Validation

Before any write, the reusable workflow MUST:

- Require execution from the trusted default branch.
- Validate the artifact choice against the closed mapping.
- Normalize and validate semantic versions.
- Require the development version to end in `-SNAPSHOT` and be greater than the release version.
- Verify that the requested release version is not already tagged.
- Verify that no GitHub Release exists for the target tag.
- Verify that no stale `release/{artifact}/{version}` branch exists.
- Verify the current canonical version is a development version compatible with the requested release.
- Run the complete artifact-specific CI validation.
- Check that immutable Maven and Apicurio release coordinates do not contain different content when remote repositories are configured.
- When generic Artifactory publication is enabled, check every target file and reject any different content already stored at the immutable release path.

### 11.3 Release commit model

The release process follows the two-commit model used by the ZenWave release workflow:

1. Create `release/{artifact}/{version}` from the validated default-branch SHA.
2. Update only the selected artifact family's canonical version to the release version.
3. For OpenAPI or AsyncAPI, update the relevant `info.version` fields; do not generate content.
4. Commit `Release {artifact} {version}`.
5. Capture this exact commit SHA as the release commit.
6. Update the selected artifact family to `development-version`.
7. Commit `Prepare {artifact} {development-version}`.
8. Push the temporary branch and open a pull request to `main`.
9. Merge through the normal branch-protection path after required checks succeed. The pilot MUST use a merge commit rather than squash or rebase so the captured release commit is preserved in `main` history.
10. Push `{artifact}/v{version}` pointing to the captured release commit, not to the merge commit or next-snapshot commit.

The workflow MUST NOT bypass branch protection by pushing version changes directly to `main`.

### 11.4 Publication sequence

After the release PR is merged and the tag exists:

1. Check out the immutable release commit with no persisted credentials.
2. Re-run validation.
3. Resolve all selected Maven coordinates with `manifest-core` and build the release JARs and checksums.
4. Deploy each JAR with `maven-deploy-plugin:deploy-file`. The pilot uses a file-backed Maven repository; a remote Artifactory Maven repository is enabled later through configuration only.
5. Build the family-qualified generic file tree and publish it when generic Artifactory publication is configured; otherwise upload the proposed tree only as a workflow artifact.
6. For OpenAPI or AsyncAPI, publish to Apicurio.
7. Create the GitHub Release and attach the JARs and checksums.
8. Open the architecture-manifest pull request and add its URL to the GitHub Release body.
9. Explicitly dispatch snapshot publication for the selected next development version.

The GitHub Release MUST NOT be announced before required external publication succeeds.

### 11.5 Release notes

Release notes follow the ZenWave convention of a deterministic, version-named Markdown file committed before the release. Because one API-product repository has independent artifact release trains, the path includes the artifact type:

```text
release-notes/{artifact}/release-notes.v{version}.md
```

Examples:

```text
release-notes/openapi/release-notes.v1.2.0.md
release-notes/asyncapi/release-notes.v1.2.0.md
```

The release-notes file is optional and is discovered from the validated `artifact` and `version` inputs; it is not a workflow input. If the file exists at the trusted release commit, the workflow MUST reject a symlink or empty file, SHOULD verify that it mentions the release version, and MUST use its contents as the human-authored portion of the GitHub Release text.

If the deterministic file does not exist, release validation continues. The workflow generates concise artifact-scoped notes from commits affecting the selected artifact's source set since the previous tag with the same prefix. The absence of a notes file MUST be shown in the workflow summary but MUST NOT fail or block the release.

In either case, the workflow creates a temporary final notes document by combining the human-authored or generated notes with a machine-generated provenance section. It passes that document to `gh release create --notes-file`; the temporary document is not committed. The release body MUST include:

- Artifact family and version.
- Source commit SHA.
- Maven coordinates, repository URL when configured, and checksum.
- Generic Artifactory tree root when that publisher is configured.
- Apicurio group, artifact identifiers, and version when applicable.
- Link to the architecture-manifest pull request when it has been created.

Versions containing a recognized prerelease component such as `-rc.1` MUST create a prerelease GitHub Release.

### 11.6 GitHub Releases in a multi-artifact repository

GitHub Releases remain useful because each one is anchored to the selected artifact family's prefixed tag and provides its scoped notes, checksums, and downloadable assets. They are artifact releases hosted in a shared repository, not releases of every artifact in that repository.

Each release MUST use:

```text
tag:   {artifact}/v{version}
title: {artifact} v{version}
```

The release attaches only assets produced by the selected artifact family. The release body links to the previous release with the same tag prefix, not merely the chronologically previous repository release.

GitHub has one repository-level concept of the “latest” release. In an API-product repository, that marker is reserved for the stable `api-product` release because it represents the complete repository/service edition:

| Released type | GitHub latest policy |
| --- | --- |
| Stable `api-product` | Create with `--latest=true` |
| Prerelease `api-product` | Create with `--prerelease --latest=false` |
| `zdl`, `openapi`, `asyncapi` | Create with `--latest=false` |

Publishing an individual artifact release MUST NOT replace the full repository/service release as latest. Consumers identify the latest version of an individual artifact family by its tag prefix, manifest version, Maven metadata, or registry metadata. The repository Releases page remains a chronological combined feed, with artifact-scoped titles providing the necessary distinction.

## 12. Maven JAR packaging and repository publication

### 12.1 JAR construction

Every package is a valid JAR built directly with the JDK `jar` command. The API-product repositories do not gain a project POM solely for packaging.

Each JAR MUST contain:

```text
META-INF/MANIFEST.MF
META-INF/arcadia/artifact-metadata.json
<artifact source files at their repository-relative paths>
```

The path declared by the corresponding manifest artifact MUST exist at exactly that path inside the JAR. This is required because `manifest-core` resolves Maven content as:

```text
{repository}/{groupPath}/{artifactId}/{version}/{artifactId}-{version}.jar!/{artifact.path}
```

`META-INF/arcadia/artifact-metadata.json` MUST contain at least:

```json
{
  "repository": "orders-checkout-api",
  "serviceId": "orders.checkout.orders-checkout",
  "artifactType": "openapi",
  "groupId": "com.arcadiaeditions.orders.checkout.orders-checkout",
  "groupPath": "com/arcadiaeditions/orders/checkout/orders-checkout",
  "artifactId": "openapi",
  "version": "1.2.0",
  "tag": "openapi/v1.2.0",
  "commit": "<full Git SHA>",
  "createdAt": "<release commit timestamp as UTC ISO-8601>"
}
```

The API-product JAR also includes a `components` object containing the canonical versions of ZDL, OpenAPI, and AsyncAPI found at the packaged commit.

JAR creation MUST be deterministic for a given source commit, manifest artifact, and version. Metadata timestamps are derived from the source commit, archive entries are sorted, and JAR metadata that varies by runner is normalized or omitted. Rebuilding an unchanged release MUST produce the same checksum.

The JAR basename and its staged/published path use Maven repository convention. The workflow converts the resolved `groupId` to `groupPath` by replacing every dot with a path separator:

```text
groupPath = groupId.replace('.', '/')

{groupPath}/{artifactId}/{version}/{artifactId}-{version}.jar
```

For the pilot OpenAPI example:

```text
com/arcadiaeditions/orders/checkout/orders-checkout/openapi/1.2.0/openapi-1.2.0.jar
```

The coordinate-relative directory prefix `{groupPath}/{artifactId}/{version}/` is mandatory in the staged Maven tree, file-backed test repository, and remote Maven repository. Immutable releases use the exact basename shown above. A Maven repository MAY replace a `-SNAPSHOT` basename with its standard timestamped snapshot filename, but it MUST retain the same group-derived directory prefix and Maven metadata. The workflow MUST validate every `groupId` segment before using it as a path and MUST reject slashes, empty segments, `.` segments, `..` segments, or characters outside the supported Maven identifier policy.

The pilot packages the following entries:

| Manifest artifact | Required JAR entries |
| --- | --- |
| `zdl` | `domain-model.zdl` |
| `openapi` | `openapi.yml` |
| `asyncapi` | `asyncapi.yml` and every owned, tracked `**/*.avsc` file |
| `asyncapi-client` | `asyncapi-client.yml` and explicitly mapped supporting files, if any |
| `api-product` | `.arcadia/api-product.yml`, the API definitions, Avro schemas, ZDL, and curated documentation |

The packaging script MUST create a clean content staging directory and the coordinate-derived Maven output directory, copy only the closed source mapping for that artifact, add `META-INF/arcadia/artifact-metadata.json`, generate the JAR manifest outside the content staging tree, normalize entry timestamps to the source commit timestamp, and invoke the JDK tool with the equivalent of:

```bash
jar --create \
  --file "target/maven-layout/${groupPath}/${artifactId}/${version}/${artifactId}-${version}.jar" \
  --manifest target/package-manifest.mf \
  -C target/staging .
```

The exact implementation MAY use a sorted `jar` argument file when required for stable entry ordering. It MUST use a pinned JDK version and MUST prove reproducibility by building the same fixture twice in separate directories and comparing SHA-256 checksums.

### 12.2 Coordinate resolution

Coordinate identity MUST be resolved through `manifest-core`, not reconstructed from filenames in the workflow:

```text
groupId                 = service.groupId ?: interpolate(config.groupIdExpression)
artifactId              = artifact.artifactId ?: interpolate(config.artifactIdExpression)
manifestEffectiveVersion = artifact.version ?: service.version ?: subdomain.version ?: domain.version
deploymentVersion       = canonical source version being built
```

The resolver output MUST preserve both version values under different field names. Release preparation fails if the proposed manifest update would not make `manifestEffectiveVersion` equal `deploymentVersion`. Snapshot publication never changes the manifest and uses only `deploymentVersion`.

With the current pilot manifest, expected artifact coordinates are:

| Manifest type | Artifact contents | Expected artifact ID before overrides |
| --- | --- | --- |
| `zdl` | `domain-model.zdl` | `domain-model` |
| `openapi` | `openapi.yml` | `openapi` |
| `asyncapi` | `asyncapi.yml`, `**/*.avsc` | `asyncapi` |
| `asyncapi-client` | `asyncapi-client.yml` and any owned supporting files | `asyncapi-client` |

The API-product package MUST be represented by a manifest artifact:

```yaml
- type: api-product
  path: ".arcadia/api-product.yml"
  artifactId: "orders-checkout-api"
```

It inherits the service-level released version in the central manifest. Its source descriptor contains the development version used by CI and release preparation.

### 12.3 Maven install and deploy

CI MUST first validate every generated JAR with:

1. `jar --list` and exact expected-entry checks.
2. `maven-install-plugin:install-file` into an isolated temporary local repository.
3. `maven-deploy-plugin:deploy-file` into an isolated file-backed Maven repository.
4. A `manifest-core` read from that deployed repository proving that the declared artifact path can be loaded from the JAR.

`maven-deploy-plugin:deploy-file` MUST receive the resolved group ID, artifact ID, version, packaging `jar`, generated JAR path, repository ID, and target URL. It MAY generate the minimal Maven POM required by repository clients, but that POM is transient deployment metadata and MUST NOT be committed or used to build the JAR.

The deployment command is equivalent to:

```bash
./mvnw -B -ntp \
  org.apache.maven.plugins:maven-deploy-plugin:${MAVEN_DEPLOY_PLUGIN_VERSION}:deploy-file \
  -Dfile="target/maven-layout/${groupPath}/${artifactId}/${version}/${artifactId}-${version}.jar" \
  -DgroupId="${groupId}" \
  -DartifactId="${artifactId}" \
  -Dversion="${version}" \
  -Dpackaging=jar \
  -DgeneratePom=true \
  -DrepositoryId="${repositoryId}" \
  -Durl="${repositoryUrl}"
```

If the caller repository has no Maven Wrapper, the shared action uses the provisioned Maven executable with the same fully qualified goal. The implementation MUST pass the configured CI settings file explicitly and MUST NOT read a developer's personal Maven settings. The install-file validation uses the same coordinates and an explicitly pinned `maven-install-plugin` version.

The Maven deploy plugin version MUST be pinned. Commands MUST run non-interactively and use an isolated settings file when credentials are required.

### 12.4 Remote Maven repository placeholder

The production Maven repository may later be an Artifactory Maven repository. Until one is available:

- No real Artifactory URL, repository key, or credential is required for pilot acceptance.
- Snapshot and release tests use file-backed Maven repositories.
- Generated Maven repository trees are uploaded as GitHub Actions artifacts.
- Remote deployment remains disabled unless all required repository variables are configured.

When a remote Maven repository is configured:

- Snapshot jobs use the configured snapshot repository URL and repository ID.
- Release jobs use the configured release repository URL and repository ID.
- Release deployment MUST refuse to overwrite different content at an existing coordinate.
- Re-running a release with an identical checksum MAY be treated as success.
- Credentials and repository URLs MUST come from environment-scoped variables and secrets.

### 12.5 Artifactory generic repository placeholder

In addition to the Maven repository, the design reserves an Artifactory **generic** repository for artifacts that should remain directly addressable as a tree of files over HTTP. This is a separate publication target from the Maven repository and MUST NOT use Maven coordinate layout or generated POM metadata.

Snapshots and immutable releases SHOULD use separate generic repository keys, supplied by `ARTIFACTORY_GENERIC_SNAPSHOT_REPOSITORY` and `ARTIFACTORY_GENERIC_RELEASE_REPOSITORY`, while retaining the same internal layout.

The default logical layout is:

```text
{server}/artifactory/{genericRepository}/
  {service.repository}/
    {artifactFamily}/
      {version}/
        {repository-relative-path}
        ...other files in the released artifact family
        .arcadia/artifact-metadata.json
        .arcadia/checksums.sha256
```

For example:

```text
orders-checkout-api/openapi/1.2.0/openapi.yml
orders-checkout-api/asyncapi/1.4.0/asyncapi.yml
orders-checkout-api/asyncapi/1.4.0/schemas/events/OrderCreated.avsc
orders-checkout-api/zdl/2.0.0/domain-model.zdl
orders-checkout-api/api-product/3.0.0/SUMMARY.md
```

This layout includes the artifact family because release trains are independent and may use the same semantic version for different content. Repository-relative paths remain unchanged below the version directory, so files are directly addressable over HTTP without opening a JAR.

The generic tree is a publication contract, not automatically a `manifest-core` content source. Its family-qualified layout cannot be represented for both artifacts and service documents by the current single Artifactory `contentUrlExpression`. If it is later required as a manifest source, the resolver mapping or an additional consolidated view MUST be designed and tested explicitly; the workflow MUST NOT silently activate an incompatible expression.

The implementation MUST treat the server, repository key, credentials, and exact retention policy as unresolved configuration. Until a generic repository exists:

- No remote generic-tree upload step is required by pilot acceptance.
- The workflow MAY build and upload the proposed tree as a GitHub Actions artifact for layout verification.
- Placeholder values MUST NOT be activated in `zenwave-architecture.yml`.
- Maven JAR deployment remains the primary package publication contract.

When enabled later, a shared generic-publication adapter MUST upload only the selected artifact family's closed source mapping, preserve repository-relative paths, publish metadata and SHA-256 checksums, and apply the same immutable-release/idempotent-snapshot rules as the Maven and Apicurio publishers. The generic tree MUST NOT become an alternative source of version numbers; canonical source versions and manifest versions remain authoritative.

## 13. Apicurio publication

### 13.1 CLI mode

The pilot invokes the fully qualified plugin goal, pinned to an exact supported version. The initial implementation target is `io.apicurio:apicurio-registry-maven-plugin:3.2.2`, subject to a pre-implementation verification that this released version contains the referenced CLI and version-strategy behavior.

Conceptually, publication supplies:

```text
apicurio.url
artifacts.groupId
artifacts.artifactId
artifacts.artifactType
artifacts.file
artifacts.versionStrategy=API_INFO_VERSION
artifacts.ifExists=FIND_OR_CREATE_VERSION
artifacts.autoRefs=true
```

### 13.2 Coordinates

- Apicurio `groupId` is the architecture `service.id`, for example `orders.checkout.orders-checkout`.
- `artifactId` is the manifest artifact path, for example `openapi.yml`, `asyncapi.yml`, or `asyncapi-client.yml`.
- The artifact type is `OPENAPI` or `ASYNCAPI` from the trusted artifact mapping.
- The version is read from `info.version`; the workflow MUST NOT pass a competing explicit artifact version.

### 13.3 Idempotency and compatibility

- Snapshot publication may update an existing draft.
- Release publication may promote the matching draft to enabled.
- Re-publishing identical enabled content is idempotent.
- Attempting to publish different content under an existing enabled version MUST fail.
- Registry compatibility failures MUST fail publication and prevent GitHub Release creation.
- Credentials MUST be present only in the Apicurio publication job.

## 14. Spectral bundle lifecycle

The operational walkthrough for these requirements is
[`docs/spectral-workflows.md`](spectral-workflows.md).

### 14.1 Source and distribution

The canonical sources remain under `api-product-workflows/spectral/`. The built file is `spectral/dist/spectral.js`.

The implementation MUST:

- Add and commit a lock file for reproducible `npm ci` installs.
- Add a semantic `version` to `spectral/package.json`.
- Ignore `spectral/dist/` on normal development branches, including `main`.
- Generate and verify `dist/spectral.js` in CI without requiring a committed copy.
- Commit `dist/spectral.js` only in the isolated release commit referenced by the immutable `spectral/v{version}` tag.
- Attach `spectral.js` and its checksum to each Spectral GitHub Release to provide a simple HTTP download URL.
- Require production consumers to pin an immutable Spectral tag, release asset, or release commit; consumers MUST NOT depend on a mutable branch or CI artifact.

The tagged bundle is available as repository content even though it is absent from `main`. For a public repository, its raw URL has this form:

```text
https://raw.githubusercontent.com/{owner}/{repository}/refs/tags/spectral/v{version}/spectral/dist/spectral.js
```

The tag is an independent Git reference. The temporary release branch does not need to be pushed, and deleting any branch does not affect the tagged release commit or its raw content.

### 14.2 Spectral CI

On changes to Spectral sources, scripts, package metadata, or the Spectral CI workflow:

1. Run `npm ci`.
2. Run the bundle command to generate `dist/spectral.js`.
3. Run the bundle verification command.
4. Run fixture lint tests for both OpenAPI and AsyncAPI rules.
5. Generate `dist/spectral.js.sha256`.
6. Upload `spectral.js` and `spectral.js.sha256` as a GitHub Actions artifact retained for seven days.

The CI artifact is diagnostic output for the workflow run. It is temporary, is not committed, and MUST NOT be promoted as the release artifact. A release rebuilds the bundle from the selected `main` source commit.

The implementation MUST add representative valid and invalid fixtures because the current package contains only an OpenAPI lint script reference and no committed fixture suite.

### 14.3 Spectral release

The Spectral release workflow takes an explicit release version and next-development version. If `B` is the checked-out `main` commit, it creates two independent child histories:

```text
             R  release version plus dist/spectral.js
            /   tag: spectral/v{version}
           B
            \
             D  next development version, no dist/spectral.js
                 merged into main through a pull request
```

The workflow uses its `GITHUB_TOKEN` with `contents: write` and `pull-requests: write`. Repository or organization policy MUST allow GitHub Actions to create pull requests. The workflow MUST periodically attempt an immediate merge after branch-protection requirements pass instead of depending on GitHub's optional native auto-merge feature.

The workflow MUST NOT commit or push directly to `main`. It commits directly only on the isolated local release-commit branch and the temporary `release/spectral/v{version}` branch. Only the `release/spectral/v{version}` pull-request merge may update `main`.

The workflow MUST:

1. Validate that `B` contains `{version}-SNAPSHOT`, that the next-development version ends in `-SNAPSHOT`, and that `spectral/v{version}` does not exist.
2. Create a temporary local release branch from `B`.
3. Set the release version, update the lock file, run `npm ci`, build and verify the bundle, and force-add the otherwise ignored `dist/spectral.js`.
4. Commit `spectral/package.json`, `spectral/package-lock.json`, and `spectral/dist/spectral.js` as release commit `R`.
5. Return to `B`, create `release/spectral/v{version}`, set the next-development version, update the lock file, and build and verify without adding `dist/`.
6. Commit only `spectral/package.json` and `spectral/package-lock.json` as next-development commit `D`.
7. Push `release/spectral/v{version}`, open its pull request against `main`, merge it through branch protection, and delete the merged branch. A stale branch from a failed attempt must be deleted before retrying the same version.
8. Verify that the parent of `R` is `B` and that `D` is an ancestor of the freshly fetched `main`.
9. Create and push annotated tag `spectral/v{version}` pointing to `R`.
10. Check out `R`, generate `spectral.js.sha256`, and create a GitHub Release with `--latest=false` containing both files.

The local release-commit branch containing `R` MUST NOT be merged into `main` and does not need to be pushed. The tag keeps `R` reachable after the runner and any temporary branch disappear. The pushed `release/spectral/v{version}` branch MUST start from `B`, not from `R`, so `main` never needs to add or subsequently delete `dist/spectral.js`.

Spectral releases do not update `zenwave-architecture.yml`.

## 15. EventCatalog generation and publication

### 15.1 Generator

Both catalog channels use the ZenWave SDK `EventCatalogPlugin` through JBang. The shared workflow invokes the pinned ZenWave SDK version with the equivalent of:

```bash
jbang zw -p EventCatalogPlugin \
  --inputFile zenwave-architecture.yml \
  --outputFolder target/event-catalog/<channel> \
  --preferredSource <source> \
  --allowFallback <true-or-false> \
  --linkSource <source>
```

The implementation MUST pin the JBang catalog/alias and ZenWave SDK version rather than resolving an unversioned latest release. The plugin generates the complete EventCatalog MDX source tree for domains, subdomains, services, channels, events, commands, queries, and entities.

Before invoking the plugin, the workflow MUST use the pinned `manifest-core` resolver to enumerate the complete manifest and load every declared artifact and service document under the channel's source policy. This preflight is mandatory because the current generator logs and skips some load failures. A failed preflight stops publication; a workflow MUST NOT mistake a partially enriched but successfully written catalog for a complete build.

- Develop preflight loads artifacts and documents from Git with fallback disabled.
- Released preflight loads every versioned artifact from Maven with fallback disabled, then loads service documents from Git with fallback disabled. The generic Artifactory tree is not an active manifest source in the pilot.
- Both preflights record the resolved source URI and checksum for every input in the generation metadata.

### 15.2 Central execution model

Catalog generation is centralized in `arcadia-editions-docs`, where `zenwave-architecture.yml` lives. API-product repositories do not generate or commit catalog output themselves.

The central repository contains a thin receiver workflow that calls the reusable `api-product-workflows/.github/workflows/event-catalog.yml`. Central execution provides one concurrency boundary for changes arriving from multiple service repositories.

### 15.3 Development catalog

The development catalog represents the latest trusted `main` content across every repository in the manifest.

Trigger sequence:

1. A relevant artifact or documentation change merges into `main` in any `*-api` repository.
2. Its successful CI workflow sends a cross-repository dispatch to `arcadia-editions-docs` with event type `event-catalog-develop`.
3. The central receiver coalesces concurrent requests and regenerates the complete catalog.

Generation options:

```text
channel         = develop
preferredSource = git
allowFallback   = false
linkSource      = git
```

The Git source in the manifest points to each repository's trusted `main` content. A failure to load any declared artifact or document fails the catalog build; the workflow MUST NOT publish a partial catalog.

### 15.4 Released catalog

The released catalog represents only versions recorded in `zenwave-architecture.yml`.

Trigger sequence:

1. An artifact release opens its architecture-manifest PR.
2. The PR is reviewed and merged.
3. A push to `arcadia-editions-docs/main` changing `zenwave-architecture.yml` invokes the released catalog workflow.
4. The workflow regenerates the complete released catalog.

Generation options:

```text
channel         = released
preferredSource = maven
allowFallback   = true
linkSource      = maven
```

Before this channel is enabled against a remote repository, the central manifest MUST activate and configure the Maven source in addition to its existing workspace and Git sources:

```yaml
config:
  contentResolution:
    - workspace
    - maven
    - git
  sources:
    maven:
      provider: artifactory
      server: "<MAVEN_REPOSITORY_SERVER_PLACEHOLDER>"
      repository: "<MAVEN_RELEASE_REPOSITORY_PLACEHOLDER>"
```

These placeholders document the required shape only. They MUST NOT be committed as active configuration until real values are available. The file-backed integration fixture supplies its own Maven source configuration. The production manifest change that activates Maven resolution is reviewed configuration, not an implicit workflow mutation.

Fallback is required because service documentation is not loaded from Maven artifacts. Before invoking the plugin, the preflight MUST resolve and read every declared versioned artifact from its Maven coordinate. This prevents a missing released artifact from silently falling back to mutable Git content. Git may supply service docs such as `SUMMARY.md` and `CHANGELOG.md`, but the catalog metadata and UI MUST label them as mutable documentation rather than released content.

The released workflow remains deployment-disabled until a reachable Maven repository is configured. Its generation logic MUST still be tested with a file-backed Maven repository and a representative manifest fixture.

### 15.5 Full rebuild policy

Both channels rebuild the whole catalog from the whole manifest. A changed-repository hint MAY be included in the dispatch payload for logging and future optimization, but it MUST NOT limit generation in the pilot.

Full regeneration is required because service relationships, consumers, shared events, links, and versioned pages cross repository boundaries. Partial regeneration may be designed later only if it produces byte-equivalent output to a full rebuild.

### 15.6 Publication outputs

Each successful run produces:

- Generated EventCatalog source tree.
- Built static EventCatalog site when the site scaffold is configured.
- Generation metadata containing channel, manifest commit, ZenWave SDK version, source policy, and triggering repositories.
- A checksum file for the generated archive.

Logical publication channels are independent:

```text
event-catalog-develop
event-catalog-released
```

Until a hosting target is selected, the workflow uploads both generated source and built-site output as named GitHub Actions artifacts. The eventual hosting adapter, such as GitHub Pages, MUST publish the channels under distinct URLs and MUST NOT let a development build overwrite the released catalog.

### 15.7 Permissions and dispatch credentials

- API-product CI needs no catalog publication credentials.
- The cross-repository dispatch job uses a GitHub App installation token scoped only to `arcadia-editions-docs` and authorized for the selected dispatch API. If `repository_dispatch` is used, grant the minimum `contents: write` permission required by that endpoint; if `workflow_dispatch` is used instead, grant only the corresponding Actions workflow permission.
- Catalog generation has `contents: read` and receives no Artifactory or Apicurio write credentials.
- Static-site deployment, when enabled, uses a separate environment and only the permissions required by the selected host.
- Develop concurrency is `event-catalog-develop`; new requests cancel an obsolete in-progress build.
- Released concurrency is `event-catalog-released`; builds are serialized and not cancelled.

## 16. Architecture-manifest pull request

### 16.1 Timing

The manifest PR is created only after remote Maven publication, required Apicurio publication, any enabled generic Artifactory publication, and GitHub Release creation succeed. This prevents the architecture from advertising a version that cannot be resolved by the released catalog or reporting an enabled publication target that is incomplete.

While only the file-backed Maven test repository is configured, release workflows run in packaging/dry-run mode and MUST NOT open a live manifest PR. They may generate and upload the proposed manifest patch for review.

Failure to create the manifest PR marks the final synchronization job as failed but MUST NOT delete an already published release. The manifest update MUST be independently rerunnable for repair.

### 16.2 Update mapping

In `arcadia-editions-docs/zenwave-architecture.yml`, locate the service by exact `repository: orders-checkout-api` and update:

| Released family | Manifest update |
| --- | --- |
| `zdl` | Set `artifacts[type=zdl].version` |
| `openapi` | Set `artifacts[type=openapi].version` |
| `asyncapi` | Set both `artifacts[type=asyncapi].version` and, when present, `artifacts[type=asyncapi-client].version` |
| `api-product` | Set service-level `version`; ensure the service has the `api-product` artifact declaration used for Maven coordinates |

The workflow MUST NOT add a `tag` property because the current published schema sets `additionalProperties: false` and supports only `name`, `artifactId`, `type`, `path`, and `version` for an artifact.

Because `manifest-core` lets an artifact inherit `service.version`, every independently released ZDL, OpenAPI, AsyncAPI, and AsyncAPI-client entry MUST have an explicit artifact version before the first API-product release changes the service-level version. This prevents an API-product release from accidentally changing the effective consumer version of another release train.

The update script MUST fail rather than edit when:

- Zero or multiple services match the repository.
- The expected artifact entry is absent or duplicated.
- The existing version is newer than the proposed version.
- The resulting manifest fails schema validation.

### 16.3 Pull-request behavior

- Target repository: `arcadia-editions/arcadia-editions-docs`.
- Target branch: `main`.
- Branch: `automation/{service-repository}/{artifact}/{version}`.
- Commit: `Update {service-repository} {artifact} to {version}`.
- PR title: `Release metadata: {service-repository} {artifact} {version}`.
- The PR body includes the source tag, GitHub Release, Maven coordinates and repository URL, generic Artifactory tree root when enabled, Apicurio coordinates when applicable, and checksums.
- The PR is left for normal review and is not automatically merged in the pilot.
- If an identical open PR exists, rerunning the job reuses it.

## 17. Permissions, environments, variables, and secrets

### 17.1 Default permissions

All reusable workflows MUST declare:

```yaml
permissions:
  contents: read
```

Jobs elevate only what they need:

| Job | Permissions |
| --- | --- |
| CI and package | `contents: read` |
| Prepare release PR | `contents: write`, `pull-requests: write` |
| Push release tag | `contents: write` |
| Create GitHub Release | `contents: write` |
| Snapshot/release external publication | `contents: read` |
| Manifest PR | GitHub App token scoped to docs repo: `contents: write`, `pull-requests: write` |

`persist-credentials` MUST be false except in the narrowly scoped job or step that intentionally pushes a branch or tag.

Third-party actions MUST be pinned to full commit SHAs. Caller workflows MUST pass secrets explicitly; `secrets: inherit` is prohibited.

### 17.2 GitHub Environments

The pilot SHOULD use:

- `artifact-snapshots`: snapshot Maven repository, optional generic Artifactory, and draft Apicurio credentials; no manual approval, restricted to `main`. No repository credential is required in file-backed test mode.
- `artifact-releases`: release Maven repository, optional generic Artifactory, and Apicurio credentials; optional required reviewer, restricted to protected branches/tags. Each remote publisher is independently disabled when its required configuration is absent.
- `architecture-manifest`: GitHub App credentials for the cross-repository PR.

### 17.3 Required variables

Names may be adapted to organization conventions, but the implementation must define equivalents for:

```text
MAVEN_RELEASE_REPOSITORY_URL          # optional until a server exists
MAVEN_RELEASE_REPOSITORY_ID           # optional until a server exists
MAVEN_SNAPSHOT_REPOSITORY_URL         # optional until a server exists
MAVEN_SNAPSHOT_REPOSITORY_ID          # optional until a server exists
MAVEN_DEPLOY_PLUGIN_VERSION           # pinned exact version
MAVEN_INSTALL_PLUGIN_VERSION          # pinned exact version
ARTIFACTORY_GENERIC_SERVER            # reserved placeholder; not used by the pilot
ARTIFACTORY_GENERIC_RELEASE_REPOSITORY # reserved placeholder; versioned immutable trees
ARTIFACTORY_GENERIC_SNAPSHOT_REPOSITORY # reserved placeholder; mutable snapshot trees
APICURIO_REGISTRY_URL
APICURIO_MAVEN_PLUGIN_VERSION
JBANG_VERSION                         # pinned exact version
ZENWAVE_SDK_VERSION
ARCHITECTURE_REPOSITORY              # default: arcadia-editions/arcadia-editions-docs
ARCHITECTURE_MANIFEST_PATH           # default: zenwave-architecture.yml
ARCHITECTURE_APP_ID
```

### 17.4 Required secrets

```text
MAVEN_REPOSITORY_USERNAME            # only when a remote repository is configured
MAVEN_REPOSITORY_PASSWORD_OR_TOKEN   # only when a remote repository is configured
ARTIFACTORY_GENERIC_USERNAME         # only when generic publication is enabled
ARTIFACTORY_GENERIC_PASSWORD_OR_TOKEN # only when generic publication is enabled
APICURIO_USERNAME                    # when required by the registry
APICURIO_PASSWORD_OR_TOKEN           # when required by the registry
ARCHITECTURE_APP_PRIVATE_KEY
```

OIDC or short-lived identity federation SHOULD replace long-lived Maven-repository or Apicurio credentials when supported. The pilot may begin with environment-scoped tokens, but it MUST NOT store credentials in repositories or generated packages.

## 18. Concurrency and idempotency

- CI concurrency: `ci-{repository}-{pull-request-or-ref}` with cancellation enabled.
- Snapshot concurrency: `snapshot-{repository}` with cancellation disabled so a newer push cannot interrupt a multi-family publication loop and leave an omitted family unpublished.
- Release concurrency: `release-{repository}-{artifact}` with cancellation disabled.
- Manifest concurrency: `manifest-{repository}-{artifact}` with cancellation disabled.
- Development catalog concurrency: `event-catalog-develop` with cancellation enabled.
- Released catalog concurrency: `event-catalog-released` with cancellation disabled.
- Only one release of a given artifact family may execute at a time.
- Release validation MUST reject an existing conflicting tag, release, branch, Maven coordinate/checksum, or enabled registry version.
- Every externally mutating step MUST be safely rerunnable after partial failure.

## 19. Failure and recovery model

| Failure point | Required behavior |
| --- | --- |
| Validation or packaging | No external writes; fix source and rerun |
| Release PR creation/merge | No tag or publication; repair/delete stale branch and rerun |
| Tag push | No publication; rerun tag step only after verifying release commit |
| Maven deployment | No GitHub Release; identical deployment may be retried |
| Generic Artifactory deployment | No GitHub Release when that publisher is enabled; identical files may be retried, conflicting immutable files fail |
| Apicurio publication | No GitHub Release; repair registry/configuration and retry from immutable commit |
| Multi-family snapshot publication | Preserve successful family publications, report exact per-family state, and rerun idempotently to complete the plan |
| GitHub Release creation | Published artifacts remain; rerun release creation idempotently |
| Manifest PR | Release remains valid; rerun manifest synchronization independently |
| Next snapshot publication | Release remains valid; dispatch snapshot publication independently |
| Development catalog generation | Keep the previously published development catalog; coalesce or rerun after correcting the source/manifest |
| Released catalog generation | Keep the previously published released catalog; never substitute a partial or Git-backed artifact release |

The workflow MUST never attempt to delete a published immutable artifact automatically as rollback.

## 20. Pilot implementation sequence

### Phase 0: configuration and test fixtures

1. Audit current `orders-checkout-api` tags, Maven coordinates, and Apicurio artifacts.
2. Choose explicit initial development versions without overwriting published releases.
3. Prepare a reviewed bootstrap manifest change that adds the `api-product` artifact entry and records audited current artifact versions; do not invent release history.
4. Configure GitHub Environments, variables, and secrets.
5. Create a GitHub App or equivalent narrowly scoped credential for docs-repository PRs and catalog dispatch.
6. Add workflow test fixtures and dry-run publication endpoints where practical.

### Phase 1: shared CI and packaging

1. Implement trusted change detection and artifact resolution.
2. Implement version readers and validators.
3. Implement artifact-specific validation without API generation.
4. Implement deterministic Maven JAR creation with the JDK `jar` tool and embedded metadata.
5. Produce the proposed generic Artifactory file tree as a workflow artifact and validate its family-qualified layout; do not upload it remotely.
6. Add the thin `orders-checkout-api` CI caller.
7. Prove path filtering with ZDL-only, OpenAPI-only, Avro-only, documentation-only, and mixed changes.
8. Prove that a mixed OpenAPI and AsyncAPI change is processed by one sequential runner loop, with separate per-family results and no expanded workflow copies.

### Phase 2: snapshots

1. Implement snapshot JAR deployment to an isolated file-backed Maven repository.
2. Implement Apicurio CLI publication using `API_INFO_VERSION`.
3. Prove that OpenAPI and AsyncAPI `-SNAPSHOT` versions become drafts.
4. Prove that one merged change can validate, package, and publish snapshots for multiple affected families in the stable loop order.
5. Prove repeated and partially completed snapshot updates are idempotent.

### Phase 3: releases

1. Implement the manual release caller and shared release engine.
2. Prove that `artifact`, `version`, and `development-version` are mandatory and no immutable release starts from an automatic event.
3. Prove that each invocation releases exactly one selected family even when multiple families have unreleased changes.
4. Prove the two-commit release/next-snapshot model.
5. Prove prefixed tags and artifact-scoped GitHub Releases coexist in one repository.
6. Prove both release-notes paths: a committed deterministic notes file and the generated fallback when that optional file is absent.
7. Rehearse one pilot release for each artifact family with a disposable Git remote and file-backed Maven repository; do not represent the rehearsal as an official published release.
8. Prove draft-to-enabled promotion in Apicurio.
9. Prove GitHub Release assets, Maven coordinates, JAR contents, and checksums.

### Phase 4: architecture synchronization

1. Add artifact versions to the pilot service entry through a reviewed docs PR.
2. Implement the cross-repository manifest update workflow.
3. Validate the updated manifest against its published schema.
4. Prove that asyncapi and asyncapi-client versions update together.

### Phase 5: Spectral lifecycle

1. Add the lock file, package version, fixtures, and ignored generated-output directory.
2. Implement bundle-generating Spectral CI with a temporary seven-day workflow artifact.
3. Implement a Spectral release and immutable HTTP download.
4. Pin artifact CI to the released Spectral bundle/workflow revision.

### Phase 6: EventCatalog lifecycle

1. Add the central `arcadia-editions-docs` receiver workflow.
2. Implement full development generation with `jbang zw -p EventCatalogPlugin` and Git-preferred content.
3. Implement released generation with Maven-preferred content and strict artifact preflight.
4. Prove cross-repository develop dispatch from `orders-checkout-api`.
5. Prove released generation with a representative file-backed Maven repository fixture.
6. Upload separate develop and released catalog artifacts without one overwriting the other.

### Phase 7: rollout

After the pilot acceptance criteria pass, roll out thin callers and initial versions one API-product repository at a time. Do not bulk-enable publication before each repository's existing tags and external coordinates have been audited.

## 21. Acceptance criteria

The file-backed pilot is complete only when all of the following are demonstrated. Operations that require a durable remote Maven repository—official immutable publication, a live architecture-manifest PR, and released-catalog deployment—MUST be exercised against disposable integration fixtures and remain disabled in production until the repository variables are configured. Once a remote repository exists, the same criteria MUST pass end to end against the real environments before production release is enabled:

- A ZDL-only PR runs ZDL and API-product validation without running OpenAPI or AsyncAPI validation.
- An OpenAPI-only PR runs OpenAPI and API-product validation.
- An Avro-only PR runs AsyncAPI and API-product validation.
- A mixed PR runs every affected family exactly once.
- Merging a PR that changes both OpenAPI and AsyncAPI produces one stable execution plan and one sequential runner loop that validates and packages OpenAPI, AsyncAPI, and the changed aggregate API product.
- Multi-family CI and snapshot execution does not require copied per-type workflows or an expanded dynamic job matrix; logs and summaries still identify each family separately.
- No CI workflow generates or modifies API source files.
- Pull-request CI has no publication credentials and performs no external writes.
- A trusted-branch push publishes snapshots only for changed artifact families.
- OpenAPI and AsyncAPI snapshots register as Apicurio drafts using `info.version`.
- Repeated snapshot publication is idempotent.
- No push, merge, tag, CI completion, or snapshot completion automatically starts an immutable artifact release.
- An authorized user can start the release from GitHub Actions only after supplying the artifact type, release version, and next `-SNAPSHOT` development version.
- A manual release creates a release PR, release commit, next-snapshot commit, prefixed tag, Maven JARs, checksums, and GitHub Release.
- A manual release requires the artifact type and releases exactly that one family; unrelated unreleased families are reported but not tagged, published, or added to the manifest update.
- When `release-notes/{artifact}/release-notes.v{version}.md` exists, its committed content forms the human-authored GitHub Release text; when it is absent, artifact-scoped generated notes are used without failing the release.
- OpenAPI and AsyncAPI may each have a `v1.0.0` GitHub Release in the same repository because their tags and titles are artifact-prefixed, and neither is marked as the repository-wide latest release.
- A stable `api-product` GitHub Release is marked as repository-wide latest; later ZDL, OpenAPI, AsyncAPI, prerelease API-product, or Spectral releases do not replace it.
- The tag points to the release-version commit rather than the next-snapshot or merge commit.
- An OpenAPI or AsyncAPI release promotes the matching Apicurio draft to enabled.
- A release never overwrites different immutable content.
- A successful artifact release opens the correct architecture-manifest PR.
- The manifest PR updates only the matching artifact version, or service version for an API-product release.
- The resulting architecture manifest validates against its published schema.
- `spectral/dist/spectral.js` is generated and verified without a committed copy on `main`; each release tag points to an isolated commit containing the bundle, and the bundle is downloadable by immutable tag URL and GitHub Release asset.
- Every JAR contains its manifest-declared artifact path and is readable through `manifest-core` after `maven-deploy-plugin:deploy-file` publishes it to the file-backed test repository.
- Maven coordinates match manifest-core resolution, including explicit service/artifact overrides.
- Every staged and immutable-release Maven JAR resides under `{groupId with dots replaced by path separators}/{artifactId}/{version}/{artifactId}-{version}.jar`; timestamped snapshots retain the same group-derived directory prefix.
- An AsyncAPI family release produces separate `asyncapi` and `asyncapi-client` JARs when both artifacts are declared.
- The dry-run generic Artifactory output preserves repository-relative files under `{service.repository}/{artifactFamily}/{version}/` and includes metadata and checksums.
- A relevant merge in the pilot repository dispatches and fully regenerates the development catalog.
- A manifest version merge fully regenerates the released catalog using Maven-preferred artifact content.
- Development and released catalog outputs are published independently.
- All reusable workflow references and third-party actions are pinned immutably.
- Partial failures can be repaired without deleting or duplicating valid releases.

## 22. References

- [Treat Your Domain Models and APIs as Products](https://ivangsa.com/) — product-lifecycle direction supplied with this specification request.
- [Apicurio Registry Maven Plugin: CLI Mode and Autoconfiguration](https://ivangsa.com/articles/apicurio-registry-maven-plugin-cli-mode-and-autoconfiguration/) — required reference for CLI mode, automatic references, `API_INFO_VERSION`, and draft-to-enabled behavior.
- [ZenWave reusable Maven release workflow](https://github.com/ZenWave360/release-workflows/blob/main/.github/workflows/release-maven.yml) — reference for explicit release and next-development versions, release PRs, immutable release commits, GitHub Releases, and post-release snapshot dispatch.
- [ZenWave Architecture Manifest schema](https://schemas.zenwave360.io/zenwave-architecture/latest/schema.json) — source of truth for supported service and artifact version metadata.
- [ZenWave Manifest](https://github.com/ZenWave360/zenwave-manifest) — source of truth for effective-version inheritance, coordinate expressions, ordered content resolution, and Maven JAR-entry loading.
- [ZenWave SDK](https://github.com/ZenWave360/zenwave-sdk) — source of the `EventCatalogPlugin` and its `inputFile`, `outputFolder`, `preferredSource`, `allowFallback`, and `linkSource` options.
