# Local Kafka Pipeline Helper

Run the GitHub-equivalent flow locally from Git Bash. Invoke the helper from
the service repository directory and pass the target environment. The service
repository name is inferred from the current directory, and the Terraform workspace is derived as
`<service-repository>-<environment>`:

```bash
cd ../catalog-products-api
../api-product-workflows/scripts/provision-kafka-local.sh develop
```

Optional apply:

```bash
APPLY_MODE=true ../api-product-workflows/scripts/provision-kafka-local.sh develop
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

For the example above, `PIPELINE_TF_WORKSPACE` is set to
`catalog-products-api-develop`.

The service repository can also be passed explicitly before the environment:

```bash
../api-product-workflows/scripts/provision-kafka-local.sh catalog-products-api develop
```

The explicit repository name must match the current directory.
