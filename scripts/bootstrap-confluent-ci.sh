#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a fresh Confluent Cloud trial organization for CI-oriented Terraform tests.
# Run this only after manually creating the Confluent Cloud account/org and running:
#   confluent login
# Existing .env.confluent-ci keys are reused by default; use --rotate-keys for new
# credentials and --print only when it is safe to display secrets on stdout.

ENV_NAME="default"
CLUSTER_NAME="arcadia-editions_cluster"
SERVICE_ACCOUNT_NAME="zenwave-ci-sa"
CLOUD_PROVIDER="gcp"
REGION="us-east1"

OUTPUT_FILE=".env.confluent-ci"
KAFKA_CLUSTER_TYPE="basic"
KAFKA_AVAILABILITY="single-zone"
SCHEMA_REGISTRY_PACKAGE="essentials"

GITHUB_SECRETS=false
DRY_RUN=false
GITHUB_REPO=""
GITHUB_ORG="arcadia-editions"
ROTATE_KEYS=false
PRINT_EXPORTS=false

usage() {
  cat <<'EOF'
Usage: bootstrap-confluent-ci.sh [--github-secrets] [--repo owner/repo] [--org org-slug] [--rotate-keys] [--print] [--dry-run]

Creates or reuses Confluent Cloud resources for low-volume CI testing and writes
Terraform-compatible exports to .env.confluent-ci.

Options:
  --github-secrets   Store generated values as GitHub secrets with gh.
  --repo owner/repo  Store secrets in one repository instead of the default organization.
  --org org-slug     Store organization secrets with visibility=all. Defaults to arcadia-editions.
  --rotate-keys      Create new API keys even when .env.confluent-ci can be reused.
  --print            Print generated exports to stdout. Secrets are not printed by default.
  --dry-run          Print intended actions without creating resources or writing secrets.
  -h, --help         Show this help.
EOF
}

log() {
  printf '[bootstrap-confluent-ci] %s\n' "$*" >&2
}

die() {
  printf '[bootstrap-confluent-ci] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found on PATH: $1"
}

run_json() {
  local output

  if ! output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    die "Command failed: $*"
  fi

  printf '%s\n' "$output"
}

jq_items='if type == "array" then .[] elif type == "object" and (.data | type) == "array" then .data[] else . end'

jq_field() {
  local field="$1"
  jq -r --arg field "$field" '
    def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
    if type != "object" then empty
    else
      to_entries[]
      | select((.key | norm) == ($field | norm))
      | .value
    end
    | select(. != null and . != "")
  ' | head -n 1
}

json_get() {
  local json="$1"
  local field="$2"
  printf '%s\n' "$json" | jq_field "$field"
}

require_json_field() {
  local json="$1"
  local field="$2"
  local label="$3"
  local value

  value="$(json_get "$json" "$field")"
  [[ -n "$value" ]] || die "Could not parse $label from Confluent CLI JSON output"
  printf '%s\n' "$value"
}

shell_quote() {
  local value="$1"
  printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

write_export() {
  local name="$1"
  local value="$2"
  printf 'export TF_VAR_%s="%s"\n' "$name" "$(shell_quote "$value")"
}

read_existing_tf_var() {
  local name="$1"
  local line
  local value

  [[ -f "$OUTPUT_FILE" ]] || return 0
  [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]] || die "Invalid TF_VAR name requested: $name"

  line="$(grep -E "^export TF_VAR_${name}=" "$OUTPUT_FILE" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#export TF_VAR_${name}=}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value//\\\\/\\}"
  value="${value//\\\"/\"}"
  value="${value//\\\$/\$}"
  value="${value//\\\`/\`}"
  printf '%s\n' "$value"
}

require_existing_tf_var() {
  local name="$1"
  local value

  value="$(read_existing_tf_var "$name")"
  [[ -n "$value" ]] || die "$OUTPUT_FILE exists but is missing TF_VAR_$name. Restore the file or rerun with --rotate-keys."
  printf '%s\n' "$value"
}

validate_existing_match() {
  local name="$1"
  local expected="$2"
  local actual

  actual="$(require_existing_tf_var "$name")"
  [[ "$actual" == "$expected" ]] || die "$OUTPUT_FILE points at TF_VAR_$name='$actual', but the discovered value is '$expected'. Use the matching env file or rerun with --rotate-keys."
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --github-secrets)
        GITHUB_SECRETS=true
        shift
        ;;
      --repo)
        [[ "${2:-}" != "" ]] || die "--repo requires owner/repo"
        GITHUB_REPO="$2"
        GITHUB_ORG=""
        shift 2
        ;;
      --org)
        [[ "${2:-}" != "" ]] || die "--org requires an organization slug"
        GITHUB_ORG="$2"
        GITHUB_REPO=""
        shift 2
        ;;
      --rotate-keys)
        ROTATE_KEYS=true
        shift
        ;;
      --print)
        PRINT_EXPORTS=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

find_environment_id() {
  confluent environment list -o json \
    | jq -r --arg name "$ENV_NAME" "$jq_items | select((.name // .Name) == \$name) | (.id // .ID)" \
    | head -n 1
}

ensure_environment() {
  local env_id

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would create Confluent environment '$ENV_NAME' with Stream Governance '$SCHEMA_REGISTRY_PACKAGE'"
    printf 'env-dryrun\n'
    return
  fi

  env_id="$(find_environment_id)"
  if [[ -n "$env_id" ]]; then
    log "Reusing Confluent environment '$ENV_NAME' ($env_id)"
    printf '%s\n' "$env_id"
    return
  fi

  log "Creating Confluent environment '$ENV_NAME'"
  local json
  json="$(run_json confluent environment create "$ENV_NAME" --governance-package "$SCHEMA_REGISTRY_PACKAGE" -o json)"
  require_json_field "$json" "id" "environment ID"
}

find_kafka_cluster_id() {
  local env_id="$1"

  confluent kafka cluster list --environment "$env_id" -o json \
    | jq -r --arg name "$CLUSTER_NAME" "$jq_items | select((.name // .Name) == \$name) | (.id // .ID)" \
    | head -n 1
}

ensure_kafka_cluster() {
  local env_id="$1"
  local cluster_id

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would create $KAFKA_CLUSTER_TYPE Kafka cluster '$CLUSTER_NAME' in $CLOUD_PROVIDER/$REGION"
    printf 'lkc-dryrun\n'
    return
  fi

  cluster_id="$(find_kafka_cluster_id "$env_id")"
  if [[ -n "$cluster_id" ]]; then
    log "Reusing Kafka cluster '$CLUSTER_NAME' ($cluster_id)"
    printf '%s\n' "$cluster_id"
    return
  fi

  log "Creating $KAFKA_CLUSTER_TYPE Kafka cluster '$CLUSTER_NAME' in $CLOUD_PROVIDER/$REGION"
  local json
  json="$(run_json confluent kafka cluster create "$CLUSTER_NAME" \
    --environment "$env_id" \
    --cloud "$CLOUD_PROVIDER" \
    --region "$REGION" \
    --type "$KAFKA_CLUSTER_TYPE" \
    --availability "$KAFKA_AVAILABILITY" \
    -o json)"
  require_json_field "$json" "id" "Kafka cluster ID"
}

wait_for_kafka_cluster() {
  local env_id="$1"
  local cluster_id="$2"
  local status

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would wait for Kafka cluster '$cluster_id' to be ready"
    return
  fi

  status="$(confluent kafka cluster describe "$cluster_id" --environment "$env_id" -o json | json_get_stdin "status" || true)"
  case "${status^^}" in
    UP|READY)
      return
      ;;
    FAILED|DELETING)
      die "Kafka cluster '$cluster_id' entered status '$status'"
      ;;
  esac

  log "Waiting for Kafka cluster '$cluster_id' to be ready"
  for _ in {1..60}; do
    status="$(confluent kafka cluster describe "$cluster_id" --environment "$env_id" -o json | json_get_stdin "status" || true)"
    case "${status^^}" in
      UP|READY)
        return
        ;;
      FAILED|DELETING)
        die "Kafka cluster '$cluster_id' entered status '$status'"
        ;;
    esac
    sleep 10
  done

  die "Timed out waiting for Kafka cluster '$cluster_id' to be ready"
}

json_get_stdin() {
  local field="$1"
  jq_field "$field"
}

describe_kafka_cluster() {
  local env_id="$1"
  local cluster_id="$2"

  if [[ "$DRY_RUN" == true ]]; then
    cat <<EOF
{"id":"$cluster_id","rest_endpoint":"https://dry-run.kafka.rest"}
EOF
    return
  fi

  run_json confluent kafka cluster describe "$cluster_id" --environment "$env_id" -o json
}

ensure_schema_registry() {
  local env_id="$1"
  local json
  local sr_id

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would discover Schema Registry for environment '$env_id'"
    cat <<'EOF'
{"id":"lsrc-dryrun","endpoint":"https://dry-run.schema-registry"}
EOF
    return
  fi

  log "Discovering Schema Registry for environment '$env_id'"
  json="$(run_json confluent schema-registry cluster describe --environment "$env_id" -o json)"
  sr_id="$(json_get "$json" "id")"
  [[ -n "$sr_id" ]] || sr_id="$(json_get "$json" "cluster")"

  [[ -n "$sr_id" ]] || die "Schema Registry is not available for environment '$env_id'. In current Confluent Cloud, it is enabled through the environment Stream Governance package and assigned after the first Kafka cluster is created."
  printf '%s\n' "$json"
}

find_schema_registry_endpoint() {
  local env_id="$1"

  run_json confluent schema-registry endpoint list --environment "$env_id" -o json \
    | jq -r "$jq_items"'
      | to_entries[]
      | select((.key | ascii_downcase | gsub("[^a-z0-9]"; "")) as $key | ["endpoint", "restendpoint", "url", "endpointurl", "publicendpointurl"] | index($key))
      | .value
      | select(type == "string" and startswith("https://"))
    ' \
    | head -n 1
}

find_service_account_id() {
  confluent iam service-account list -o json \
    | jq -r --arg name "$SERVICE_ACCOUNT_NAME" "$jq_items | select((.name // .Name) == \$name) | (.id // .ID)" \
    | head -n 1
}

ensure_service_account() {
  local service_account_id

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would create service account '$SERVICE_ACCOUNT_NAME'"
    printf 'sa-dryrun\n'
    return
  fi

  service_account_id="$(find_service_account_id)"
  if [[ -n "$service_account_id" ]]; then
    log "Reusing service account '$SERVICE_ACCOUNT_NAME' ($service_account_id)"
    printf '%s\n' "$service_account_id"
    return
  fi

  log "Creating service account '$SERVICE_ACCOUNT_NAME'"
  local json
  json="$(run_json confluent iam service-account create "$SERVICE_ACCOUNT_NAME" \
    --description "CI Terraform automation for $ENV_NAME" \
    -o json)"
  require_json_field "$json" "id" "service account ID"
}

create_api_key() {
  local resource_id="$1"
  local service_account_id="$2"
  local description="$3"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would create API key for resource '$resource_id' and service account '$service_account_id'"
    cat <<EOF
{"api_key":"dry-run-$resource_id-key","api_secret":"dry-run-$resource_id-secret"}
EOF
    return
  fi

  log "Creating API key for resource '$resource_id'"
  run_json confluent api-key create \
    --resource "$resource_id" \
    --service-account "$service_account_id" \
    --description "$description" \
    -o json
}

create_role_binding() {
  local description="$1"
  shift

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would grant $description"
    return
  fi

  log "Granting $description"
  local output
  if ! output="$(confluent iam rbac role-binding create "$@" 2>&1)"; then
    if grep -qiE 'already exists|duplicate|conflict' <<< "$output"; then
      log "Role binding already exists for $description"
      return
    fi

    printf '%s\n' "$output" >&2
    die "Could not grant $description"
  fi
}

ensure_ci_permissions() {
  local env_id="$1"
  local kafka_id="$2"
  local schema_registry_id="$3"
  local service_account_id="$4"
  local principal="User:${service_account_id}"

  create_role_binding "CloudClusterAdmin on Kafka cluster '$kafka_id' to '$principal'" \
    --principal "$principal" \
    --role CloudClusterAdmin \
    --environment "$env_id" \
    --cloud-cluster "$kafka_id"

  create_role_binding "ResourceOwner on all Schema Registry subjects in '$schema_registry_id' to '$principal'" \
    --principal "$principal" \
    --role ResourceOwner \
    --environment "$env_id" \
    --schema-registry-cluster "$schema_registry_id" \
    --resource "Subject:*"
}

load_or_create_api_keys() {
  local kafka_id="$1"
  local kafka_rest_endpoint="$2"
  local schema_registry_id="$3"
  local schema_registry_rest_endpoint="$4"
  local service_account_id="$5"

  if [[ -f "$OUTPUT_FILE" && "$ROTATE_KEYS" == false ]]; then
    log "Reusing API keys from '$OUTPUT_FILE'. Use --rotate-keys to create new keys."
    validate_existing_match "kafka_id" "$kafka_id"
    validate_existing_match "kafka_rest_endpoint" "$kafka_rest_endpoint"
    validate_existing_match "schema_registry_id" "$schema_registry_id"
    validate_existing_match "schema_registry_rest_endpoint" "$schema_registry_rest_endpoint"

    jq -n \
      --arg confluent_cloud_api_key "$(require_existing_tf_var "confluent_cloud_api_key")" \
      --arg confluent_cloud_api_secret "$(require_existing_tf_var "confluent_cloud_api_secret")" \
      --arg kafka_api_key "$(require_existing_tf_var "kafka_api_key")" \
      --arg kafka_api_secret "$(require_existing_tf_var "kafka_api_secret")" \
      --arg schema_registry_api_key "$(require_existing_tf_var "schema_registry_api_key")" \
      --arg schema_registry_api_secret "$(require_existing_tf_var "schema_registry_api_secret")" \
      '{
        confluent_cloud_api_key: $confluent_cloud_api_key,
        confluent_cloud_api_secret: $confluent_cloud_api_secret,
        kafka_api_key: $kafka_api_key,
        kafka_api_secret: $kafka_api_secret,
        schema_registry_api_key: $schema_registry_api_key,
        schema_registry_api_secret: $schema_registry_api_secret
      }'
    return
  fi

  if [[ -f "$OUTPUT_FILE" && "$ROTATE_KEYS" == true ]]; then
    log "Rotating API keys because --rotate-keys was provided"
  fi

  # API key secrets are only returned at creation time, so new keys are generated only
  # when there is no reusable env file or when --rotate-keys is explicitly provided.
  local cloud_key_json
  local kafka_key_json
  local schema_registry_key_json
  cloud_key_json="$(create_api_key "cloud" "$service_account_id" "CI Terraform Cloud API key for $ENV_NAME")"
  kafka_key_json="$(create_api_key "$kafka_id" "$service_account_id" "CI Kafka API key for $CLUSTER_NAME")"
  schema_registry_key_json="$(create_api_key "$schema_registry_id" "$service_account_id" "CI Schema Registry API key for $ENV_NAME")"

  jq -n \
    --arg confluent_cloud_api_key "$(require_json_field "$cloud_key_json" "api_key" "Cloud API key")" \
    --arg confluent_cloud_api_secret "$(require_json_field "$cloud_key_json" "api_secret" "Cloud API secret")" \
    --arg kafka_api_key "$(require_json_field "$kafka_key_json" "api_key" "Kafka API key")" \
    --arg kafka_api_secret "$(require_json_field "$kafka_key_json" "api_secret" "Kafka API secret")" \
    --arg schema_registry_api_key "$(require_json_field "$schema_registry_key_json" "api_key" "Schema Registry API key")" \
    --arg schema_registry_api_secret "$(require_json_field "$schema_registry_key_json" "api_secret" "Schema Registry API secret")" \
    '{
      confluent_cloud_api_key: $confluent_cloud_api_key,
      confluent_cloud_api_secret: $confluent_cloud_api_secret,
      kafka_api_key: $kafka_api_key,
      kafka_api_secret: $kafka_api_secret,
      schema_registry_api_key: $schema_registry_api_key,
      schema_registry_api_secret: $schema_registry_api_secret
    }'
}

set_github_secret() {
  local name="$1"
  local value="$2"
  local repo_args=()
  local org_args=()

  [[ -n "$GITHUB_REPO" ]] && repo_args=(--repo "$GITHUB_REPO")
  [[ -n "$GITHUB_ORG" ]] && org_args=(--org "$GITHUB_ORG" --visibility all)

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would set GitHub secret '$name'"
    return
  fi

  printf '%s' "$value" | gh secret set "$name" "${repo_args[@]}" "${org_args[@]}" >/dev/null
}

main() {
  parse_args "$@"

  need_cmd confluent
  need_cmd jq

  if [[ "$GITHUB_SECRETS" == true ]]; then
    need_cmd gh
    if [[ "$DRY_RUN" == false ]]; then
      gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"
    else
      log "DRY RUN: would require 'gh auth status' before writing GitHub secrets"
    fi
  elif command -v gh >/dev/null 2>&1; then
    log "GitHub CLI detected. Re-run with --github-secrets to store values as GitHub secrets."
  else
    log "GitHub CLI not found. Continuing without GitHub secret storage."
  fi

  if [[ "$DRY_RUN" == false ]]; then
    confluent context describe >/dev/null 2>&1 || die "Confluent CLI is not authenticated. Run: confluent login"
  else
    log "DRY RUN: would verify Confluent CLI authentication with 'confluent context describe'"
  fi

  # Create or reuse the Confluent environment. The governance package enables Schema Registry capabilities.
  local env_id
  env_id="$(ensure_environment)"

  # Create or reuse a single-zone Basic Kafka cluster suitable for low-volume CI tests.
  local kafka_id
  kafka_id="$(ensure_kafka_cluster "$env_id")"
  wait_for_kafka_cluster "$env_id" "$kafka_id"

  local kafka_json
  kafka_json="$(describe_kafka_cluster "$env_id" "$kafka_id")"
  local kafka_rest_endpoint
  kafka_rest_endpoint="$(require_json_field "$kafka_json" "rest_endpoint" "Kafka REST endpoint")"

  # Discover the environment Schema Registry after the first Kafka cluster exists.
  local schema_registry_json
  schema_registry_json="$(ensure_schema_registry "$env_id")"
  local schema_registry_id
  local schema_registry_rest_endpoint
  schema_registry_id="$(json_get "$schema_registry_json" "id")"
  [[ -n "$schema_registry_id" ]] || schema_registry_id="$(json_get "$schema_registry_json" "cluster")"
  [[ -n "$schema_registry_id" ]] || die "Could not parse Schema Registry ID from Confluent CLI JSON output"
  schema_registry_rest_endpoint="$(json_get "$schema_registry_json" "endpoint")"
  [[ -n "$schema_registry_rest_endpoint" ]] || schema_registry_rest_endpoint="$(json_get "$schema_registry_json" "rest_endpoint")"
  [[ -n "$schema_registry_rest_endpoint" ]] || schema_registry_rest_endpoint="$(json_get "$schema_registry_json" "url")"
  [[ -n "$schema_registry_rest_endpoint" ]] || schema_registry_rest_endpoint="$(json_get "$schema_registry_json" "endpoint_url")"
  [[ -n "$schema_registry_rest_endpoint" ]] || schema_registry_rest_endpoint="$(json_get "$schema_registry_json" "public_endpoint_url")"
  [[ -n "$schema_registry_rest_endpoint" ]] || schema_registry_rest_endpoint="$(find_schema_registry_endpoint "$env_id")"
  [[ -n "$schema_registry_rest_endpoint" ]] || die "Could not parse Schema Registry REST endpoint from Confluent CLI JSON output"

  # Create or reuse the service account that owns CI API keys.
  local service_account_id
  service_account_id="$(ensure_service_account)"
  ensure_ci_permissions "$env_id" "$kafka_id" "$schema_registry_id" "$service_account_id"

  local api_keys_json
  local confluent_cloud_api_key
  local confluent_cloud_api_secret
  local kafka_api_key
  local kafka_api_secret
  local schema_registry_api_key
  local schema_registry_api_secret
  api_keys_json="$(load_or_create_api_keys "$kafka_id" "$kafka_rest_endpoint" "$schema_registry_id" "$schema_registry_rest_endpoint" "$service_account_id")"
  confluent_cloud_api_key="$(require_json_field "$api_keys_json" "confluent_cloud_api_key" "Cloud API key")"
  confluent_cloud_api_secret="$(require_json_field "$api_keys_json" "confluent_cloud_api_secret" "Cloud API secret")"
  kafka_api_key="$(require_json_field "$api_keys_json" "kafka_api_key" "Kafka API key")"
  kafka_api_secret="$(require_json_field "$api_keys_json" "kafka_api_secret" "Kafka API secret")"
  schema_registry_api_key="$(require_json_field "$api_keys_json" "schema_registry_api_key" "Schema Registry API key")"
  schema_registry_api_secret="$(require_json_field "$api_keys_json" "schema_registry_api_secret" "Schema Registry API secret")"

  local env_content
  env_content="$(
    write_export "confluent_cloud_api_key" "$confluent_cloud_api_key"
    write_export "confluent_cloud_api_secret" "$confluent_cloud_api_secret"
    printf '\n'
    write_export "kafka_id" "$kafka_id"
    write_export "kafka_rest_endpoint" "$kafka_rest_endpoint"
    write_export "kafka_api_key" "$kafka_api_key"
    write_export "kafka_api_secret" "$kafka_api_secret"
    printf '\n'
    write_export "schema_registry_id" "$schema_registry_id"
    write_export "schema_registry_rest_endpoint" "$schema_registry_rest_endpoint"
    write_export "schema_registry_api_key" "$schema_registry_api_key"
    write_export "schema_registry_api_secret" "$schema_registry_api_secret"
  )"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would write Terraform exports to '$OUTPUT_FILE'"
  else
    umask 077
    printf '%s\n' "$env_content" > "$OUTPUT_FILE"
    log "Wrote Terraform exports to '$OUTPUT_FILE'"
  fi

  if [[ "$PRINT_EXPORTS" == true ]]; then
    printf '%s\n' "$env_content"
  else
    log "Exports were not printed to stdout. Use --print if you need to display them."
  fi

  if [[ "$GITHUB_SECRETS" == true ]]; then
    set_github_secret "CONFLUENT_CLOUD_API_KEY" "$confluent_cloud_api_key"
    set_github_secret "CONFLUENT_CLOUD_API_SECRET" "$confluent_cloud_api_secret"
    set_github_secret "KAFKA_ID" "$kafka_id"
    set_github_secret "KAFKA_REST_ENDPOINT" "$kafka_rest_endpoint"
    set_github_secret "KAFKA_API_KEY" "$kafka_api_key"
    set_github_secret "KAFKA_API_SECRET" "$kafka_api_secret"
    set_github_secret "SCHEMA_REGISTRY_ID" "$schema_registry_id"
    set_github_secret "SCHEMA_REGISTRY_REST_ENDPOINT" "$schema_registry_rest_endpoint"
    set_github_secret "SCHEMA_REGISTRY_API_KEY" "$schema_registry_api_key"
    set_github_secret "SCHEMA_REGISTRY_API_SECRET" "$schema_registry_api_secret"
    [[ "$DRY_RUN" == true ]] || log "Stored GitHub repository secrets"
  fi

  cat >&2 <<EOF

Next steps:
  source $OUTPUT_FILE
  terraform init
  terraform plan
EOF
}

main "$@"
