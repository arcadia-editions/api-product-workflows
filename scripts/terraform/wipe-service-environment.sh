#!/usr/bin/env bash
set -Eeuo pipefail

# Destroy the Terraform-managed resources for the service in the current
# directory and then remove its Terraform Cloud workspace.
#
# Usage (from a service repository):
#   bash ../api-product-workflows/scripts/terraform/wipe-service-environment.sh
#   bash ../api-product-workflows/scripts/terraform/wipe-service-environment.sh pre
#   bash ../api-product-workflows/scripts/terraform/wipe-service-environment.sh prod --yes

usage() {
  cat >&2 <<'EOF'
Usage: wipe-service-environment.sh [environment] [--yes]

The environment defaults to develop. The service name is the current folder
name, and the Terraform Cloud workspace is <service>-<environment>.
Use --yes to skip the confirmation prompt (for CI/non-interactive use).
EOF
}

environment="develop"
assume_yes=false
for argument in "$@"; do
  case "$argument" in
    --yes|-y) assume_yes=true ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "Unknown option: $argument" >&2; usage; exit 2 ;;
    *)
      if [[ "$environment" != "develop" ]]; then
        echo "Only one environment may be supplied" >&2
        usage
        exit 2
      fi
      environment="$argument"
      ;;
  esac
done

if [[ ! "$environment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid environment name: $environment" >&2
  exit 2
fi

service_dir="$(pwd -P)"
service_name="$(basename "$service_dir")"
terraform_dir="$service_dir/target/terraform"
workspace="${service_name}-${environment}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workflow_dir="$(cd -- "$script_dir/../.." && pwd -P)"

if [[ ! -d "$terraform_dir" ]]; then
  echo "Terraform directory not found: $terraform_dir" >&2
  echo "Run this script from the service repository root." >&2
  exit 1
fi

source "$workflow_dir/.env.confluent-ci"
source "$workflow_dir/.env.terraform-cloud"

: "${TF_CLOUD_ORGANIZATION:?TF_CLOUD_ORGANIZATION is not set}"
: "${TF_TOKEN_app_terraform_io:?TF_TOKEN_app_terraform_io is not set}"

if [[ "$assume_yes" != true ]]; then
  printf 'This will destroy resources in %s and delete workspace %s/%s. Continue? [y/N] ' \
    "$terraform_dir" "$TF_CLOUD_ORGANIZATION" "$workspace"
  read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]] || {
    echo "Cancelled."
    exit 0
  }
fi

echo "Initializing Terraform in $terraform_dir"
terraform -chdir="$terraform_dir" init -input=false -no-color

echo "Destroying Terraform resources for $workspace"
# Do not put the workspace deletion in a trap: it must happen only after a
# successful destroy, so a disconnected/failed Terraform run leaves state
# available for recovery.
terraform -chdir="$terraform_dir" destroy -auto-approve -input=false -no-color

workspace_url="https://app.terraform.io/api/v2/organizations/${TF_CLOUD_ORGANIZATION}/workspaces/${workspace}"
echo "Deleting Terraform Cloud workspace $workspace"
curl --fail-with-body --silent --show-error --request DELETE \
  --header "Authorization: Bearer $TF_TOKEN_app_terraform_io" \
  --header "Content-Type: application/vnd.api+json" \
  "$workspace_url"
printf '\nWipe completed for %s (%s).\n' "$service_name" "$environment"
