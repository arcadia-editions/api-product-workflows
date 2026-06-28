![lifecycle: beta](https://img.shields.io/badge/lifecycle-beta-4c1)

> Beta lifecycle: the end-to-end pipelines work against real infrastructure but are still evolving before production hardening.

# API product workflows

Reusable GitHub Actions workflows for API-first products in Arcadia Editions.

The workflows cover three independent concerns, in this order:

1. **CI for APIs and models** — detect, lint and validate changed OpenAPI, AsyncAPI, ZDL and ZFL artifacts.
2. **Releases for APIs, models and services** — release one manifest artifact or a complete service snapshot with its own version, tag, packages and GitHub release.
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
- For `openapi` and `asyncapi` artifacts, changing a file resolved through the artifact's `$ref` graph selects the artifact that references it.
- Selecting an `asyncapi` or `asyncapi-client` artifact, or changing any `.avsc` file anywhere in the repository, resolves `asyncapi-all` and validates every concrete bundle member together.
- Deleting any file selects every declared artifact: a deleted `$ref` target can no longer be resolved, so CI can't tell which artifacts depended on it and falls back to full validation.
- Changing only files under `.github/workflows/` or `.github/actions/` selects all declared artifacts.
- Unrelated files do not trigger artifact validation.
- The repository name from the GitHub caller context identifies the manifest owner; there is no `groupId`, `artifactId` or artifact list in the caller workflow.

### Validation and publication capabilities

| Type              | Validation                                         | Maven | Apicurio | Artifactory |
| ----------------- | -------------------------------------------------- | ----- | -------- | ----------- |
| `zdl`             | ZenWave ZDL parser                                 | Yes   | No       | Yes         |
| `zfl`             | ZenWave ZFL parser                                 | Yes   | No       | Yes         |
| `openapi`         | Redocly and Spectral                               | Yes   | Yes      | Yes         |
| `asyncapi`        | AsyncAPI CLI, Spectral and referenced Avro schemas | Yes   | Yes      | Yes         |
| `asyncapi-client` | AsyncAPI CLI and Spectral                          | Yes   | Yes      | Yes         |

The publication columns describe release capabilities. CI only performs validation.

### Running complete validation manually

1. Open the API repository in GitHub.
2. Select **Actions**.
3. Select **API-first artifact validation**.
4. Select **Run workflow** and choose the branch to validate.

A manual run sets `full_validation=true`, so every artifact belonging to that repository is validated even when no artifact file changed.

## 2. Releases for APIs and models

Each API repository has a thin `.github/workflows/artifact-release.yml` caller. Releases are manual. Most artifact IDs remain independent; `artifact=asyncapi-all` is the Kafka-contract bundle. `artifact=service-all` snapshots the complete service repository at the artifacts' existing versions and advances only the service version in the architecture manifest.

### Starting a release

1. Ensure the intended source and current development version are on `main`.
2. Open the API repository in GitHub.
3. Select **Actions**.
4. Select **Release API-first artifact or AsyncAPI bundle**.
5. Select **Run workflow** from `main`.
6. Provide the two release inputs.

| Input      | Meaning                                                                | Example                                |
| ---------- | ---------------------------------------------------------------------- | -------------------------------------- |
| `artifact` | Release identity. `asyncapi-all` selects the Kafka contracts; `service-all` selects the complete service snapshot | `domain-model`, `asyncapi-all`, `service-all` |
| `version`  | Release version without a `v` prefix                               | `1.4.0`                              |

The workflow derives source paths and coordinates from ManifestCore. The `asyncapi-all` virtual manifest selection returns every concrete `asyncapi`/`asyncapi-client` member on the service. Direct releases of either member type are rejected; use `asyncapi-all` whether the repository owns an owned contract, a client contract, or both.

The `service-all` virtual selection returns every manifest artifact owned by the service, but packaging is repository-wide: every Git-tracked file is included. Artifact source versions remain unchanged, the combined Maven coordinate uses artifactId `service-all`, and the GitHub release is marked as latest. The architecture update uses ManifestCore's source-aware scalar editor to change only the service-level `version`.

### What a successful release does

For `artifact=asyncapi-all` and `version=1.4.0`, expect:

1. Preflight validates the inputs, source version and absence of conflicting branches, tags and GitHub releases.
2. A branch named `release/asyncapi-all/v1.4.0` is created from `main`.
3. Every declared `asyncapi`/`asyncapi-client` source is changed to `1.4.0`, linted and validated together.
4. The release change is committed and the branch is pushed.
5. A pull request updates `main` to `1.4.0`, merges through branch protection and deletes the release branch.
6. An annotated tag named `release/asyncapi-all/v1.4.0` is created on the merged `main` commit.
7. One `asyncapi-all` Maven JAR containing all bundle members and referenced schemas is published.
8. A GitHub release titled `asyncapi-all v1.4.0` is created with the Maven JAR and checksum; a combined Terraform ZIP is generated from the same tag and attached to that release.
9. The architecture repository receives one `artifact-released` dispatch containing every bundle member.
10. The architecture repository updates all member versions in one pull request and triggers one EventCatalog rebuild after merge.

After a successful release, `main` remains at the released `version`. The workflow does not calculate or write a next development version.

Non-Kafka artifacts in the same repository are not versioned, packaged or published by that run.

For `artifact=service-all`, no artifact source version is rewritten and no individual artifact is republished to Apicurio. One repository snapshot JAR and generic tree are published under the requested service version.

### Release naming

Most artifacts are independent release units. The `asyncapi-all` identity is a composite release unit whose optional members are the repository's `asyncapi` and `asyncapi-client` manifest artifacts:

```text
branch: release/{artifactId}/v{version}
tag:    release/{artifactId}/v{version}
title:  {artifactId} v{version}
```

The branch, tag, Maven coordinate and Terraform bundle all use `asyncapi-all`; `asyncapi` and `asyncapi-client` have no separate release identities. Complete service snapshots use `service-all` for the branch, tag and Maven artifactId. Kafka Terraform provisioning remains attached to `asyncapi-all`.

All Maven JAR payload files are stored under the Java package directory derived from `groupId` (for example, `com.example.orders/openapi.yml`). `META-INF` stays at the JAR root, and generic Artifactory trees retain repository-relative paths.

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

Kafka/Schema Registry provisioning uses the same combined `asyncapi-all` release boundary. A repository that owns either an `asyncapi` or `asyncapi-client` artifact generates one Terraform configuration, one state and one promotion unit. When both exist, shared principals such as a Confluent service account are generated once.

| Stage             | File                          | Trigger                                                     | Gate                                            |
| ----------------- | ------------------------------ | ------------------------------------------------------------ | ------------------------------------------------ |
| Plan              | `provision-kafka-plan.yml`     | detected AsyncAPI/Avro change or full validation             | none, plan-only                                   |
| Develop apply     | `provision-kafka-develop.yml`  | same detection on a push or manual dispatch on `develop`     | none - a passing plan applies immediately         |
| Release attachment | `provision-kafka-release.yml` | automatically after `artifact=asyncapi-all` releases         | source release must succeed                       |
| Promote           | `provision-kafka-promote.yml`  | manual call for the combined AsyncAPI release                | the person running it - see below                 |
| Destroy           | `provision-kafka-destroy.yml`  | manual call for the combined workspace                       | typing the exact workspace name - see below       |

### Plan and develop apply (no caller file needed)

`artifact-ci.yml`'s `validate` job exposes whether the detected plan contains an `asyncapi-all` member. When true, two additional jobs run in the same workflow:

- **`kafka-plan`** (`needs: validate`) calls `provision-kafka-plan.yml`: resolves every Kafka contract, generates one Terraform tree and plans it against `{service_repo}-develop`.
- **`kafka-develop`** (`needs: kafka-plan`, `if: ref == develop`) applies that combined tree to `{service_repo}-develop`. There is no approval step: a successful plan applies immediately.

Because these run as jobs *inside* `artifact-ci.yml` (a nested reusable-workflow call one level deeper), the caller's `secrets: inherit` must be present at both levels - `artifact-ci.yml`'s `kafka-plan`/`kafka-develop` jobs re-declare `secrets: inherit` when invoking `provision-kafka-plan.yml`/`provision-kafka-develop.yml`.

### Release attachment

After `artifact-release.yml` publishes `release/asyncapi-all/vX`, it invokes `provision-kafka-release.yml`. That workflow checks out the same tag, generates Terraform from every bundle member, validates it offline and uploads `<service_repo>-asyncapi-all-vX-terraform.zip` to the existing GitHub release. There is no second Kafka version or release tag.

```yaml
jobs:
  attach-kafka-terraform:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka-release.yml@main
    with:
      service_repo: catalog-products-api
      version: "1.4.0"
    secrets: inherit
```

### Promote (apply a bundle, never regenerate)

```yaml
jobs:
  promote-kafka:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka-promote.yml@main
    with:
      service_repo: catalog-products-api
      target_env: pre        # or: prod
      version: "1.4.0"       # required for pre, must be empty for prod
    secrets: inherit
```

- **`target_env: pre`** downloads the Terraform asset from `release/asyncapi-all/vX`, renders `cloud.tf` for `{service_repo}-pre`, and applies it.
- **`target_env: prod`** takes no version input. It reads `provisioned_from` from `{service_repo}-pre`, downloads the identical release, and applies it to `{service_repo}-prod`.

Terraform workspace names are `{service_repo}-develop`, `{service_repo}-pre` and `{service_repo}-prod`.

### Destroy (tear down the combined environment)

```yaml
jobs:
  destroy-kafka:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka-destroy.yml@main
    with:
      service_repo: catalog-products-api
      target_env: develop     # or: pre, prod
      confirm: catalog-products-api-develop
    secrets: inherit
```

`provision-kafka-destroy.yml` runs `terraform destroy` against `{service_repo}-{target_env}` and then deletes that Terraform Cloud workspace. It destroys everything tracked for the combined bundle.

This is deliberately irreversible and requires typing `confirm` as the exact workspace name (`{service_repo}-{target_env}`).

### Deployment state vs. the architecture manifest

Two different things are deliberately tracked separately and never conflated:

- The architecture manifest updates all AsyncAPI bundle-member versions together when `release/asyncapi-all/vX` is published.
- The **`provisioned_from` Terraform output** records which AsyncAPI version is deployed, or the git ref/sha for continuous develop.

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
- `.github/workflows/provision-kafka-release.yml`: generates combined Terraform from `release/asyncapi-all/vX` and attaches it to that release.
- `.github/workflows/provision-kafka-promote.yml`: reusable promotion of a published bundle to `pre`/`prod`.
- `.github/workflows/provision-kafka-destroy.yml`: reusable teardown of a service environment's combined Kafka/Confluent resources and Terraform Cloud workspace.
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
