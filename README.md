![lifecycle: beta](https://img.shields.io/badge/lifecycle-beta-4c1)

> Beta lifecycle: End-to-end pipeline working against real infrastructure, still evolving before production hardening.

# api-product-workflows

Shared CI/CD assets for Arcadia Editions AsyncAPI repositories.

This repository provides the reusable workflow and scripts that turn AsyncAPI contracts into Terraform bundles for Kafka topics, Schema Registry subjects, and related platform resources.

## What it does

- generates Terraform from AsyncAPI with ZenWave
- adds a shared Terraform overlay for Confluent Cloud and HCP Terraform
- runs `terraform init`, `validate`, `plan`, and `apply` for `develop`
- packages release-ready Terraform bundles for `pre` and `prod`

## Repository contents

- `.github/workflows/provision-kafka.yml`: reusable GitHub Actions workflow
- `scripts/provision-kafka.sh`: generates Terraform and overlays shared files
- `scripts/assert-terraform-env.sh`: validates required environment variables
- `terraform/common/`: shared Terraform provider, defaults, outputs, and HCP Terraform config template
- `docs/spectral-workflows.md`: Spectral CI, release branching, tagging, and bundle distribution

## How service repos use it

Each service repo keeps a thin caller workflow:

```yaml
jobs:
  provision:
    uses: arcadia-editions/api-product-workflows/.github/workflows/provision-kafka.yml@main
```

## Environment model

- `develop` branch: generate and optionally apply to the `develop` workspace
- `rc-*` tags: generate release artifacts for `pre`
- `v*` tags: generate release artifacts for `prod`

Workspace naming is per repository and environment:

- `<repo>-develop`
- `<repo>-pre`
- `<repo>-prod`

## Bootstrap Confluent CI environment

Use `scripts/bootstrap-confluent-ci.sh` to create or reuse the low-volume Confluent Cloud resources used by CI and write Terraform-compatible exports to `.env.confluent-ci`.

Prerequisites:

- `confluent` CLI authenticated with `confluent login`
- `jq`
- `gh` authenticated with `gh auth login`, only when using `--github-secrets`

Generate the local env file:

```bash
./scripts/bootstrap-confluent-ci.sh
source .env.confluent-ci
```

The generated `.env.confluent-ci` file contains these required Confluent Terraform variables:

```bash
export TF_VAR_confluent_cloud_api_key="..."
export TF_VAR_confluent_cloud_api_secret="..."
export TF_VAR_kafka_id="..."
export TF_VAR_kafka_rest_endpoint="..."
export TF_VAR_kafka_api_key="..."
export TF_VAR_kafka_api_secret="..."
export TF_VAR_schema_registry_id="..."
export TF_VAR_schema_registry_crn="..."
export TF_VAR_schema_registry_rest_endpoint="..."
export TF_VAR_schema_registry_api_key="..."
export TF_VAR_schema_registry_api_secret="..."
```

Terraform Cloud also requires:

```bash
export TF_CLOUD_ORGANIZATION="arcadia-editions"
export TF_TOKEN_app_terraform_io="..."
```

For GitHub Actions, the reusable workflow validates all of the variables above plus `PIPELINE_TF_WORKSPACE`, which the workflow derives from the service repository and target server.

Useful options:

- `--github-secrets`: store generated secrets and variables with GitHub CLI.
- `--repo owner/repo`: store configuration in one repository.
- `--org org-slug`: store organization configuration. Defaults to `arcadia-editions`.
- `--rotate-keys`: create fresh API keys instead of reusing `.env.confluent-ci`.
- `--print`: print exports to stdout.
- `--dry-run`: show intended actions without creating resources or writing secrets.

## Notes

- AsyncAPI is the source of truth.
- Generated Terraform is disposable.
- HCP Terraform stores state per repo and environment.

## TODO

- Add a documented end-to-end example that points to the open source Kafka and Schema Registry test resources.
  Placeholder: `TODO_OPEN_SOURCE_E2E_EXAMPLE_URL`
- Add the Confluent-specific pipeline reference used for the hosted flow.
  Placeholder: `TODO_CONFLUENT_PIPELINE_URL`
