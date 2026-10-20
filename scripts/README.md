# Local Kafka Pipeline Helper

Run the GitHub-equivalent flow locally from Git Bash. Invoke the helper from
the service repository directory and pass the target environment. The service
repository name is inferred from the current directory. Every local `asyncapi.yml`/`asyncapi-client.yml`
file is generated and provisioned together in `<service-repository>-<environment>`:

```bash
cd ../catalog-products-api
../api-product-workflows/scripts/terraform/provision-kafka-local.sh develop
```

Optional apply:

```bash
APPLY_MODE=true ../api-product-workflows/scripts/terraform/provision-kafka-local.sh develop
```

Generated plan artifacts:

- `tfplan.txt`: human-readable plan output
- `tfplan.sanitized.json`: reduced machine-readable summary when `jq` is available

The helper does not keep the raw `tfplan` binary or a full `terraform show -json` export because both can expose secrets in plain text.

Required environment variables:

```bash
export TF_CLOUD_ORGANIZATION=""
export TF_TOKEN_app_terraform_io=""
export TF_VAR_confluent_cloud_api_key=""
export TF_VAR_confluent_cloud_api_secret=""
export TF_VAR_kafka_id=""
export TF_VAR_kafka_rest_endpoint=""
export TF_VAR_kafka_api_key=""
export TF_VAR_kafka_api_secret=""
export TF_VAR_schema_registry_id=""
export TF_VAR_schema_registry_crn=""
export TF_VAR_schema_registry_rest_endpoint=""
export TF_VAR_schema_registry_api_key=""
export TF_VAR_schema_registry_api_secret=""
```

Optional overrides:

```bash
export ASYNCAPI_FILE=asyncapi.yml
export PIPELINE_REPO_PATH=/path/to/api-product-workflows
```

Setting `ASYNCAPI_FILE` provisions only that file for repositories that intentionally own one contract.

For the example above, `PIPELINE_TF_WORKSPACE` is `catalog-products-api-develop`.

The service repository can also be passed explicitly before the environment:

```bash
../api-product-workflows/scripts/terraform/provision-kafka-local.sh catalog-products-api develop
```

The explicit repository name must match the current directory.

## Wipe a service environment

To destroy all Terraform-managed resources for the service in the current
directory and then delete its Terraform Cloud workspace, use:

```bash
cd ../orders-checkout-api
../api-product-workflows/scripts/terraform/wipe-service-environment.sh
```

The environment defaults to `develop`. Pass another environment as the first
argument when needed:

```bash
../api-product-workflows/scripts/terraform/wipe-service-environment.sh pre
../api-product-workflows/scripts/terraform/wipe-service-environment.sh prod
```

The script asks for confirmation and deletes the Terraform Cloud workspace only
after `terraform destroy` succeeds. For a non-interactive run, pass `--yes`:

```bash
../api-product-workflows/scripts/terraform/wipe-service-environment.sh prod --yes
```

The generated Terraform service account is destroyed with the other Terraform
resources. The Confluent API key used to authenticate Terraform/CI is supplied
through environment variables (`TF_VAR_*` and `.env.confluent-ci`); it is not an
`api_key` resource in this generated configuration and is not deleted by this
script. If the service-account deletion returns `403`, the Confluent identity
running Terraform needs permission to delete it, or dependent resources/API
keys must be handled first.

Run this only from the service repository root. It derives the workspace name
as `<current-folder>-<environment>` and does not remove resources outside that
Terraform state.
