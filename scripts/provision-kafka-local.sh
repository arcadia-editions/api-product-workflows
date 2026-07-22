#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <environment>" >&2
  echo "   or: $0 <service-repository> <environment>" >&2
  echo "Run this script from the service repository directory." >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

if [[ -z "$1" ]]; then
  usage
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_REPO_PATH="$(pwd)"
CURRENT_REPO_NAME="$(basename "$SERVICE_REPO_PATH")"
PIPELINE_REPO_PATH_DEFAULT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "$CURRENT_REPO_NAME" != *-api ]]; then
  echo "Current directory must be a *-api service repository: $SERVICE_REPO_PATH" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  SERVICE_REPO_NAME="$CURRENT_REPO_NAME"
  SERVER="$1"
else
  if [[ -z "$2" ]]; then
    usage
    exit 2
  fi

  SERVICE_REPO_NAME="$1"
  SERVER="$2"

  if [[ "$SERVICE_REPO_NAME" != "$CURRENT_REPO_NAME" ]]; then
    echo "Service repository argument '$SERVICE_REPO_NAME' does not match current directory '$CURRENT_REPO_NAME'" >&2
    exit 1
  fi
fi

PIPELINE_TF_WORKSPACE="${SERVICE_REPO_NAME}-${SERVER}"
PIPELINE_REPO_PATH="${PIPELINE_REPO_PATH:-$PIPELINE_REPO_PATH_DEFAULT}"
ASYNCAPI_FILE="${ASYNCAPI_FILE:-asyncapi.yml}"
APPLY_MODE="${APPLY_MODE:-false}"
export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-true}"
export TF_INPUT="${TF_INPUT:-false}"
export PIPELINE_TF_WORKSPACE

required_commands=(
  jbang
  terraform
)

for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

if [[ ! -d "$PIPELINE_REPO_PATH" ]]; then
  echo "Pipeline repo not found: $PIPELINE_REPO_PATH" >&2
  exit 1
fi

chmod +x "${PIPELINE_REPO_PATH}/scripts/provision-kafka.sh"
chmod +x "${PIPELINE_REPO_PATH}/scripts/assert-terraform-env.sh"

"${PIPELINE_REPO_PATH}/scripts/provision-kafka.sh" \
  "$SERVICE_REPO_PATH" \
  "$PIPELINE_REPO_PATH" \
  "$ASYNCAPI_FILE" \
  "$SERVER"

"${PIPELINE_REPO_PATH}/scripts/assert-terraform-env.sh" \
  TF_CLOUD_ORGANIZATION \
  TF_TOKEN_app_terraform_io \
  PIPELINE_TF_WORKSPACE \
  TF_VAR_confluent_cloud_api_key \
  TF_VAR_confluent_cloud_api_secret \
  TF_VAR_kafka_id \
  TF_VAR_kafka_rest_endpoint \
  TF_VAR_kafka_api_key \
  TF_VAR_kafka_api_secret \
  TF_VAR_schema_registry_id \
  TF_VAR_schema_registry_crn \
  TF_VAR_schema_registry_rest_endpoint \
  TF_VAR_schema_registry_api_key \
  TF_VAR_schema_registry_api_secret

cd "${SERVICE_REPO_PATH}/target/terraform"

unset TF_WORKSPACE
terraform init
terraform validate
terraform plan -out=tfplan
terraform show -no-color tfplan > tfplan.txt

if command -v jq >/dev/null 2>&1; then
  terraform show -json tfplan | jq '{
    format_version,
    terraform_version,
    resource_changes: [
      .resource_changes[]? | {
        address,
        mode,
        type,
        name,
        provider_name,
        actions: .change.actions,
        before_sensitive: (.change.before_sensitive // null),
        after_sensitive: (.change.after_sensitive // null),
        after_unknown: (.change.after_unknown // null)
      }
    ],
    output_changes: (
      .output_changes
      | to_entries
      | map({
          key,
          value: {
            actions: (.value.actions // []),
            sensitive: (.value.sensitive // false)
          }
        })
    )
  }' > tfplan.sanitized.json
else
  echo "jq not found; skipping tfplan.sanitized.json export" >&2
fi

if [[ "$APPLY_MODE" == "true" ]]; then
  terraform apply -auto-approve tfplan
fi

rm -f tfplan
