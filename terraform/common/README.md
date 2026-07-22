# Shared Terraform Overlay

Files in this folder are copied into every generated Terraform bundle.

Current overlay contents:
- `cloud.tftpl`: template rendered into `cloud.tf` with organization and workspace name
- `provider.tf`: Confluent provider configuration
- `variables.tf`: provider and schema inputs
- `defaults.auto.tfvars`: shared non-sensitive defaults
- `outputs.tf`: basic traceability outputs

## Simplified contract

- AsyncAPI is the primary source of topic and schema settings.
- Shared Terraform defaults are used only when AsyncAPI does not provide a value.
- Cluster IDs, endpoints, and credentials come from the pipeline environment, not from AsyncAPI.

In practice:

- service teams define topic intent in AsyncAPI
- the shared overlay supplies provider wiring and safe defaults
- the pipeline injects target cluster, Schema Registry, and HCP Terraform settings

Service-specific overlays may override shared defaults through `terraform/services/<repo-name>/`.

## Expected GitHub configuration

- Secrets:
  - `TF_TOKEN_app_terraform_io`
  - `CONFLUENT_CLOUD_API_KEY`
  - `CONFLUENT_CLOUD_API_SECRET`
  - `CONFLUENT_KAFKA_API_KEY`
  - `CONFLUENT_KAFKA_API_SECRET`
  - `CONFLUENT_SCHEMA_REGISTRY_API_KEY`
  - `CONFLUENT_SCHEMA_REGISTRY_API_SECRET`
- Variables:
  - `TF_CLOUD_ORGANIZATION`
  - `CONFLUENT_KAFKA_CLUSTER_ID`
  - `CONFLUENT_KAFKA_REST_ENDPOINT`
  - `CONFLUENT_SCHEMA_REGISTRY_ID`
  - `CONFLUENT_SCHEMA_REGISTRY_CRN`
  - `CONFLUENT_SCHEMA_REGISTRY_REST_ENDPOINT`

## Workspace naming

- `<repo>-develop`
- `<repo>-pre`
- `<repo>-prod`

The pipeline renders `cloud.tf` from `TF_CLOUD_ORGANIZATION` and `PIPELINE_TF_WORKSPACE`.
Because the generated config uses `workspaces { name = ... }`, `terraform init`
can auto-create a missing workspace on first use.

## TODO

- Add a direct link to the open source Kafka and Schema Registry end-to-end example.
  Placeholder: `TODO_OPEN_SOURCE_E2E_EXAMPLE_URL`
- Add the external Confluent pipeline reference for the hosted variant.
  Placeholder: `TODO_CONFLUENT_PIPELINE_URL`
