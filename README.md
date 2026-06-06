![lifecycle: beta](https://img.shields.io/badge/lifecycle-beta-4c1)

> Beta lifecycle: End-to-end pipeline working against real infrastructure, still evolving before production hardening.

# asyncapi-ops-pipelines

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

## How service repos use it

Each service repo keeps a thin caller workflow:

```yaml
jobs:
  provision:
    uses: arcadia-editions/asyncapi-ops-pipelines/.github/workflows/provision-kafka.yml@main
```

## Environment model

- `develop` branch: generate and optionally apply to the `develop` workspace
- `rc-*` tags: generate release artifacts for `pre`
- `v*` tags: generate release artifacts for `prod`

Workspace naming is per repository and environment:

- `<repo>-develop`
- `<repo>-pre`
- `<repo>-prod`

## Notes

- AsyncAPI is the source of truth.
- Generated Terraform is disposable.
- HCP Terraform stores state per repo and environment.

## TODO

- Add a documented end-to-end example that points to the open source Kafka and Schema Registry test resources.
  Placeholder: `TODO_OPEN_SOURCE_E2E_EXAMPLE_URL`
- Add the Confluent-specific pipeline reference used for the hosted flow.
  Placeholder: `TODO_CONFLUENT_PIPELINE_URL`
