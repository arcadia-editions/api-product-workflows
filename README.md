![lifecycle: beta](https://img.shields.io/badge/lifecycle-beta-4c1)

> Beta lifecycle: the end-to-end pipelines work against real infrastructure but are still evolving before production hardening.

# API product workflows

Reusable GitHub Actions workflows for API-first products in Arcadia Editions.

The workflows cover three independent concerns, in this order:

1. **CI for APIs and models** — detect, lint and validate changed OpenAPI, AsyncAPI, ZDL and ZFL artifacts.
2. **Releases for APIs and models** — release one manifest artifact with its own version, tag, packages and GitHub release.
3. **Terraform provisioning from AsyncAPI** — generate, validate, plan and optionally apply Kafka and Schema Registry infrastructure.

The architecture manifest is the inventory and coordinate authority. CI and release workflows read it directly from its HTTP URI. ManifestCore resolves the artifact owner, type, path, `groupId`, `artifactId` and version defaults; callers do not repeat those values.

Only artifacts declared in the architecture manifest participate. An API or model file that exists in a repository but is not declared in the manifest is intentionally ignored.

## 1. CI for APIs and models

Each API repository has a thin `.github/workflows/artifact-ci.yml` caller. It invokes:

```yaml
uses: arcadia-editions/api-product-workflows/.github/workflows/artifact-ci.yml@main
```

### What happens on each event

| Event                          | What CI does                                                                   |
| ------------------------------ | ------------------------------------------------------------------------------ |
| Pull request opened or updated | Detects and validates affected manifest artifacts between the PR base and head |
| Push to any branch             | Detects and validates artifacts changed by the push                            |
| Push to `main`                 | Performs the same lint and validation; it does not publish a snapshot          |
| Manual run                     | Validates every manifest artifact owned by the repository                      |
| Workflow-only change           | Validates the complete repository artifact inventory                           |

CI has read-only repository permissions and does not create commits, tags, packages or releases.

### Change detection

- Changing a declared artifact path selects that artifact.
- Changing an `.avsc` file selects the repository's `asyncapi` and `asyncapi-client` artifacts.
- Changing only files under `.github/workflows/` or `.github/actions/` selects all declared artifacts.
- Unrelated files do not trigger artifact validation.
- The repository name from the GitHub caller context identifies the manifest owner; there is no `groupId`, `artifactId` or artifact list in the caller workflow.

### Validation and publication capabilities

| Type              | Validation                                      | Maven | Apicurio | Artifactory |
| ----------------- | ----------------------------------------------- | ----- | -------- | ----------- |
| `zdl`             | ZenWave ZDL parser                              | Yes   | No       | Yes         |
| `zfl`             | ZenWave ZFL parser                              | Yes   | No       | Yes         |
| `openapi`         | Redocly and Spectral                            | Yes   | Yes      | Yes         |
| `asyncapi`        | AsyncAPI CLI, Spectral and tracked Avro schemas | Yes   | Yes      | Yes         |
| `asyncapi-client` | AsyncAPI CLI and Spectral                       | Yes   | Yes      | Yes         |

The publication columns describe release capabilities. CI only performs validation.

### Running complete validation manually

1. Open the API repository in GitHub.
2. Select **Actions**.
3. Select **API-first artifact validation**.
4. Select **Run workflow** and choose the branch to validate.

A manual run sets `full_validation=true`, so every artifact belonging to that repository is validated even when no artifact file changed.

## 2. Releases for APIs and models

Each API repository has a thin `.github/workflows/artifact-release.yml` caller. Releases are manual and select exactly one manifest artifact.

### Starting a release

1. Ensure the intended source and current development version are on `main`.
2. Open the API repository in GitHub.
3. Select **Actions**.
4. Select **Release one API-first artifact**.
5. Select **Run workflow** from `main`.
6. Provide the three release inputs.

| Input         | Meaning                                                | Example                                                  |
| ------------- | ------------------------------------------------------ | -------------------------------------------------------- |
| `artifact`    | Resolved manifest `artifactId`, not the artifact type  | `domain-model`, `openapi`, `asyncapi`, `asyncapi-client` |
| `version`     | Release version without a `v` prefix                   | `1.4.0`                                                  |
| `nextVersion` | Greater next development version                       | `1.5.0`                                                  |

The workflow derives the artifact type, source path, coordinates and current version from ManifestCore. It fails when the artifact does not belong uniquely to the calling repository.

### What a successful release does

For `artifact=asyncapi`, `version=1.4.0` and `nextVersion=1.5.0`, expect:

1. Preflight validates the inputs, source version and absence of conflicting branches, tags and GitHub releases.
2. A branch named `release/asyncapi/v1.4.0` is created from `main`.
3. Only the selected source artifact is changed to `1.4.0`, linted and validated.
4. The release change is committed and the branch is pushed.
5. An annotated tag named `release/asyncapi/v1.4.0` is created from the release commit.
6. Only that artifact is packaged and published to its configured destinations.
7. A GitHub release titled `asyncapi v1.4.0` is created from the tag with the Maven JAR and checksum attached.
8. The architecture repository receives an `artifact-released` dispatch.
9. The architecture repository updates its local `zenwave-architecture.yml` through its own pull request and triggers the EventCatalog rebuild after merge.
10. The selected API source is changed to `1.5.0` on the release branch.
11. A pull request to `main` is opened, merged through branch protection and the release branch is deleted.

Other artifacts in the same repository are not versioned, packaged or published by that run.

### Release naming

Each artifact is an independent release unit, including multiple artifacts of the same type:

```text
branch: release/{artifactId}/v{version}
tag:    release/{artifactId}/v{version}
title:  {artifactId} v{version}
```

This is why the input is the resolved `artifactId` rather than `openapi`, `asyncapi` or another type name.

### Publication behavior

A destination is used when its corresponding repository variable is configured:

| Destination | Repository variables                                          | Credentials                                                       |
| ----------- | ------------------------------------------------------------- | ----------------------------------------------------------------- |
| Maven       | `MAVEN_RELEASE_REPOSITORY_URL`, `MAVEN_RELEASE_REPOSITORY_ID` | `MAVEN_REPOSITORY_USERNAME`, `MAVEN_REPOSITORY_PASSWORD_OR_TOKEN` |
| Apicurio    | `APICURIO_REGISTRY_URL`                                       | `APICURIO_USERNAME`, `APICURIO_PASSWORD_OR_TOKEN`                 |
| Artifactory | `ARTIFACTORY_GENERIC_RELEASE_URL`                             | `ARTIFACTORY_USERNAME`, `ARTIFACTORY_PASSWORD_OR_TOKEN`           |

The caller also maps:

- `ARTIFACT_WORKFLOWS_CHECKOUT_TOKEN` for reading the shared workflow implementation when required.
- `ARTIFACT_RELEASE_TOKEN` for pushing release branches, tags and pull requests.
- `ARCHITECTURE_APP_TOKEN` for dispatching the manifest update.

These may be supplied as organization-level secrets shared with the API repositories. The release job uses the protected `artifact-releases` GitHub environment.

### Failed and repeated releases

The workflow deliberately stops when the release branch, tag or GitHub release already exists. If a run fails after creating one of those resources, inspect the completed steps and resolve the partial release before retrying. It does not overwrite an existing release identity.

## 3. Terraform provisioning from AsyncAPI

Kafka/Schema Registry provisioning is split into four reusable workflows, plus two jobs folded directly into `artifact-ci.yml`. Only artifacts declared in the architecture manifest participate: a repository that owns neither `asyncapi` nor `asyncapi-client` never runs any Kafka step. Each `asyncapi`/`asyncapi-client` artifact a repository owns is provisioned **independently**, in its own Terraform workspace - a repository with both never shares state, a release, or a promotion between them.

| Stage             | File                          | Trigger                                                     | Gate                                            |
| ----------------- | ------------------------------ | ------------------------------------------------------------ | ------------------------------------------------ |
| Plan              | `provision-kafka-plan.yml`     | job inside `artifact-ci.yml`, every PR/push                  | none, plan-only                                   |
| Develop apply     | `provision-kafka-develop.yml`  | job inside `artifact-ci.yml`, push or manual dispatch on `develop` | none - a passing plan applies immediately    |
| Release           | `provision-kafka-release.yml`  | manual `workflow_dispatch` per artifact                      | none - builds and publishes a bundle, never applies |
| Promote           | `provision-kafka-promote.yml`  | manual `workflow_dispatch` per artifact                      | the person running it - see below                 |
| Destroy           | `provision-kafka-destroy.yml`  | manual `workflow_dispatch` per artifact                      | typing the exact workspace name - see below       |

### Plan and develop apply (no caller file needed)

`artifact-ci.yml`'s `validate` job resolves the manifest inventory for the calling repository and exposes `has_kafka_artifacts`. When true, two additional jobs run in the same workflow:

- **`kafka-plan`** (`needs: validate`) calls `provision-kafka-plan.yml`: resolves every `asyncapi`/`asyncapi-client` artifact the repository owns, then runs a matrix job - one leg per artifact - that generates Terraform from just that artifact's file and runs `init`/`validate`/`plan`, uploading the plan. Runs on every PR and push, regardless of whether this particular push touched an AsyncAPI file - Terraform plans are idempotent, so replanning on every CI run catches drift instead of only catching changes.
- **`kafka-develop`** (`needs: kafka-plan`, `if: ref == develop`) calls `provision-kafka-develop.yml`: the same per-artifact matrix, plus `apply` against each artifact's own `{service_repo}-{artifactId}-develop` workspace. Triggers on `push` to `develop` and on a manual `workflow_dispatch` run from `develop` - both use the existing `workflow_dispatch` trigger each repository's `artifact-ci.yml` caller already has for full-validation runs, so **no new workflow file is required per repository**. There is no approval step: a passing plan is the only condition before apply, matching that development has no human gateway.

Because these run as jobs *inside* `artifact-ci.yml` (a nested reusable-workflow call one level deeper), the caller's `secrets: inherit` must be present at both levels - `artifact-ci.yml`'s `kafka-plan`/`kafka-develop` jobs re-declare `secrets: inherit` when invoking `provision-kafka-plan.yml`/`provision-kafka-develop.yml`.

### Release (build one artifact's bundle)

`asyncapi` and `asyncapi-client` are released independently by `artifact-release.yml`, each with its own version. `provision-kafka-release.yml` follows the same one-artifact-per-call shape: a human builds a promotable Terraform bundle for a single already-released artifact version:

```yaml
jobs:
  release-kafka-asyncapi:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka-release.yml@main
    with:
      service_repo: catalog-products-api
      artifact: asyncapi
      version: "1.4.0"
      kafka_version: "7"
    secrets: inherit

  release-kafka-asyncapi-client:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka-release.yml@main
    with:
      service_repo: catalog-products-api
      artifact: asyncapi-client
      version: "2.1.0"
      kafka_version: "3"
    secrets: inherit
```

Each call resolves `artifact` against the architecture manifest, checks out `refs/tags/release/{artifactId}/v{version}`, generates Terraform from just that one file, sanity-checks it offline (`terraform init -backend=false && terraform validate`, no Confluent/TFC credentials needed), and publishes it as GitHub release `release/kafka/{artifactId}/v{kafka_version}` with the generated Terraform tree attached as a zip. `kafka_version` is that artifact's own bundle version, independent of every other artifact's bundle version and of the source artifact's own version. The bundle's `cloud.tf` is deliberately left unrendered (`cloud.tftpl`) at this stage, because the same bundle is later applied to more than one Terraform workspace.

### Promote (apply a bundle, never regenerate)

```yaml
jobs:
  promote-kafka-asyncapi:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka-promote.yml@main
    with:
      service_repo: catalog-products-api
      artifact: asyncapi
      target_env: pre        # or: prod
      kafka_release: "7"     # required for pre, must be empty for prod
    secrets: inherit
```

- **`target_env: pre`** downloads the `release/kafka/{artifact}/vX` bundle named by `kafka_release`, renders `cloud.tf` for the `{service_repo}-{artifact}-pre` workspace, and applies it. This is the only place a human picks a specific version - running the workflow with an explicit `kafka_release` *is* the approval, there is no separate reviewer gate layered on top.
- **`target_env: prod`** takes no version input. It reads the `provisioned_from` Terraform output currently applied to `{service_repo}-{artifact}-pre`, downloads that exact same bundle, and applies it to `{service_repo}-{artifact}-prod`. `prod` cannot diverge from `pre` by construction: to change what reaches `prod`, promote `pre` with a new `kafka_release` first, then promote `prod` from that. There is no bypass input.

A repository with both an `asyncapi` and an `asyncapi-client` artifact promotes each independently - promoting one to `prod` never requires or waits on the other.

Terraform workspace names are `{service_repo}-{artifactId}-develop`, `{service_repo}-{artifactId}-pre` and `{service_repo}-{artifactId}-prod` - there is no `staging` workspace.

### Destroy (tear down one artifact's environment)

```yaml
jobs:
  destroy-kafka-asyncapi:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka-destroy.yml@main
    with:
      service_repo: catalog-products-api
      artifact: asyncapi
      target_env: develop     # or: pre, prod
      confirm: catalog-products-api-asyncapi-develop
    secrets: inherit
```

`provision-kafka-destroy.yml` tears down one artifact's environment: it runs `terraform destroy` against `{service_repo}-{artifact}-{target_env}` (removing the Kafka topics, Schema Registry subjects and service account that workspace's state tracks in Confluent Cloud) and, once that succeeds, deletes the Terraform Cloud workspace itself. It does not check out the service repo, an AsyncAPI file or any release bundle - `terraform destroy` tears down whatever a workspace's state already tracks regardless of the current configuration, so the shared `terraform/common` overlay (provider config plus the `cloud` block) is all it needs.

This is deliberately irreversible and requires typing `confirm` as the exact workspace name being destroyed (`{service_repo}-{artifact}-{target_env}`) - the run fails immediately if it does not match. There is no other gate: like `promote`, the deliberate act of typing that value and pressing run is the approval.

### Deployment state vs. the architecture manifest

Two different things are deliberately tracked separately and never conflated:

- The architecture **manifest's `version` field** updates only when an artifact is released (`artifact-release.yml`). It answers "what's the latest published version of this contract", for Maven/Apicurio/EventCatalog consumers - it is never updated by, or read as, deployment state.
- The **`provisioned_from` Terraform output** (`terraform/common/outputs.tf`) records which `release/kafka/vX` bundle (or, for the continuous `develop` environment, which git ref/sha) an apply actually came from. It answers "what's live in this environment right now", and it's what `promote` reads back to mirror `pre` into `prod`.

### Required Terraform configuration

Every stage expects:

```text
TF_CLOUD_ORGANIZATION
TF_TOKEN_app_terraform_io
CONFLUENT_CLOUD_API_KEY
CONFLUENT_CLOUD_API_SECRET
CONFLUENT_KAFKA_CLUSTER_ID
CONFLUENT_KAFKA_REST_ENDPOINT
CONFLUENT_KAFKA_API_KEY
CONFLUENT_KAFKA_API_SECRET
CONFLUENT_SCHEMA_REGISTRY_ID
CONFLUENT_SCHEMA_REGISTRY_CRN
CONFLUENT_SCHEMA_REGISTRY_REST_ENDPOINT
CONFLUENT_SCHEMA_REGISTRY_API_KEY
CONFLUENT_SCHEMA_REGISTRY_API_SECRET
```

These live as **organization-level** secrets/variables visible to the `*-api` repositories, never on `api-product-workflows` itself - that repository only ever supplies code, never run identity. `service_repo` inputs stay strictly self-referential (each repository's own caller names itself); a shared dispatcher that accepted an arbitrary repository name would need one over-privileged, org-wide credential and would reintroduce a confused-deputy risk.

## Bootstrapping the Confluent CI environment

Use `scripts/terraform/bootstrap-confluent-ci.sh` to create or reuse the low-volume Confluent Cloud resources used by CI and write Terraform-compatible exports to `.env.confluent-ci`.

Prerequisites:

- `confluent` CLI authenticated with `confluent login`.
- `jq`.
- `gh` authenticated with `gh auth login` when using `--github-secrets`.

```bash
./scripts/terraform/bootstrap-confluent-ci.sh
source .env.confluent-ci
```

Useful options:

- `--github-secrets`: store generated secrets and variables with GitHub CLI.
- `--repo owner/repo`: store configuration in one repository.
- `--org org-slug`: store configuration at organization level; defaults to `arcadia-editions`.
- `--rotate-keys`: create fresh API keys.
- `--print`: print exports to stdout.
- `--dry-run`: show intended actions without creating resources or writing secrets.

## Implementation layout

- `.github/workflows/artifact-ci.yml`: reusable changed-artifact validation.
- `.github/workflows/artifact-release.yml`: reusable independent artifact release.
- `.github/workflows/provision-kafka-plan.yml`: reusable AsyncAPI-to-Terraform plan, called from `artifact-ci.yml`.
- `.github/workflows/provision-kafka-develop.yml`: reusable AsyncAPI-to-Terraform apply for `develop`, called from `artifact-ci.yml`.
- `.github/workflows/provision-kafka-release.yml`: reusable single-artifact `asyncapi`/`asyncapi-client` build, published as a `release/kafka/{artifactId}/vX` bundle.
- `.github/workflows/provision-kafka-promote.yml`: reusable promotion of a published bundle to `pre`/`prod`.
- `.github/workflows/provision-kafka-destroy.yml`: reusable teardown of one artifact's Kafka/Confluent resources and Terraform Cloud workspace.
- `scripts/artifacts/ManifestTool.java`: HTTP manifest inventory and coordinate resolution.
- `scripts/artifacts/DslTool.java`: ZDL/ZFL parsing and version editing.
- `scripts/artifacts/`: validation, packaging and publication helpers.
- `scripts/terraform/`: AsyncAPI-to-Terraform generation, local execution and Confluent bootstrap helpers.
- `spectral/`: shared Spectral rules and pinned bundle build.
- `terraform/common/`: shared Terraform overlay.
- `docs/artifact-release-workflows-spec.md`: detailed artifact lifecycle specification.
- `docs/spectral-workflows.md`: Spectral bundle maintenance and release process.

Reusable artifact workflows intentionally use two checkouts:

```text
source/    calling API repository being validated or released
pipeline/  trusted api-product-workflows implementation
```

Commits, tags, pull requests and GitHub releases always target the calling API repository.
