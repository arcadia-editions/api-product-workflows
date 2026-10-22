#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the Terraform Cloud configuration used by the provision-kafka workflows.
# Reuses what is already on disk: .env.terraform-cloud first, then the current
# environment, then the token saved by `terraform login`. The token is checked
# against the Terraform Cloud API before anything is written or stored.
# Secrets are never printed unless --print is given.

TF_HOST="app.terraform.io"
OUTPUT_FILE=".env.terraform-cloud"

TF_ORGANIZATION=""
GITHUB_SECRETS=false
DRY_RUN=false
GITHUB_REPO=""
GITHUB_ORG="arcadia-editions"
PRINT_EXPORTS=false

usage() {
  cat <<'EOF'
Usage: bootstrap-terraform-cloud-ci.sh [--tf-organization name] [--env-file path] [--github-secrets] [--repo owner/repo] [--org org-slug] [--print] [--dry-run]

Resolves TF_CLOUD_ORGANIZATION and TF_TOKEN_app_terraform_io from what is already
on disk, verifies them against Terraform Cloud and writes them to .env.terraform-cloud.

Lookup order for each value:
  1. --tf-organization (organization only)
  2. the env file (.env.terraform-cloud by default)
  3. the current environment
  4. terraform login credentials (token only): $TF_CLI_CONFIG_FILE,
     %APPDATA%/terraform.d/credentials.tfrc.json or ~/.terraform.d/credentials.tfrc.json

Options:
  --tf-organization name  Terraform Cloud organization to use.
  --env-file path         Env file to read and write. Defaults to .env.terraform-cloud.
  --github-secrets        Store the token secret and organization variable with gh.
  --repo owner/repo       Store configuration in one repository instead of the default organization.
  --org org-slug          Store organization configuration with visibility=all. Defaults to arcadia-editions.
  --print                 Print exports to stdout. Secrets are not printed by default.
  --dry-run               Print intended actions without writing files or secrets.
  -h, --help              Show this help.
EOF
}

log() {
  printf '[bootstrap-terraform-cloud-ci] %s\n' "$*" >&2
}

die() {
  printf '[bootstrap-terraform-cloud-ci] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found on PATH: $1"
}

shell_quote() {
  local value="$1"
  printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g; s/`/\\`/g'
}

write_export() {
  local name="$1"
  local value="$2"
  printf 'export %s="%s"\n' "$name" "$(shell_quote "$value")"
}

# Reads NAME=value or export NAME=value from the env file without sourcing it.
read_env_file_var() {
  local name="$1"
  local line
  local value

  [[ -f "$OUTPUT_FILE" ]] || return 0
  [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]] || die "Invalid variable name requested: $name"

  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${name}=" "$OUTPUT_FILE" | tail -n 1 | tr -d '\r' || true)"
  [[ -n "$line" ]] || return 0
  value="${line#*${name}=}"
  if [[ "$value" == \"*\" ]]; then
    value="${value%\"}"
    value="${value#\"}"
    value="${value//\\\\/\\}"
    value="${value//\\\"/\"}"
    value="${value//\\\$/\$}"
    value="${value//\\\`/\`}"
  elif [[ "$value" == \'*\' ]]; then
    value="${value%\'}"
    value="${value#\'}"
  fi
  printf '%s\n' "$value"
}

credentials_files() {
  [[ -n "${TF_CLI_CONFIG_FILE:-}" ]] && printf '%s\n' "$TF_CLI_CONFIG_FILE"
  [[ -n "${APPDATA:-}" ]] && printf '%s\n' "$APPDATA/terraform.d/credentials.tfrc.json"
  printf '%s\n' "$HOME/.terraform.d/credentials.tfrc.json"
}

read_terraform_login_token() {
  local file
  local token

  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    token="$(jq -r --arg host "$TF_HOST" '.credentials[$host].token // empty' "$file" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      log "Using Terraform token from '$file'"
      printf '%s\n' "$token"
      return
    fi
  done < <(credentials_files)
}

resolve_organization() {
  local organization="$TF_ORGANIZATION"

  if [[ -n "$organization" ]]; then
    log "Using Terraform organization from --tf-organization"
  else
    organization="$(read_env_file_var "TF_CLOUD_ORGANIZATION")"
    if [[ -n "$organization" ]]; then
      log "Using Terraform organization from '$OUTPUT_FILE'"
    elif [[ -n "${TF_CLOUD_ORGANIZATION:-}" ]]; then
      organization="$TF_CLOUD_ORGANIZATION"
      log "Using Terraform organization from the environment"
    fi
  fi

  [[ -n "$organization" ]] || die "No Terraform organization found. Pass --tf-organization or set TF_CLOUD_ORGANIZATION in $OUTPUT_FILE."
  printf '%s\n' "$organization"
}

resolve_token() {
  local token

  token="$(read_env_file_var "TF_TOKEN_app_terraform_io")"
  if [[ -n "$token" ]]; then
    log "Using Terraform token from '$OUTPUT_FILE'"
  elif [[ -n "${TF_TOKEN_app_terraform_io:-}" ]]; then
    token="$TF_TOKEN_app_terraform_io"
    log "Using Terraform token from the environment"
  else
    token="$(read_terraform_login_token)"
  fi

  [[ -n "$token" ]] || die "No Terraform token found. Run 'terraform login' or set TF_TOKEN_app_terraform_io in $OUTPUT_FILE."
  printf '%s\n' "$token"
}

verify_token() {
  local organization="$1"
  local token="$2"
  local status

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would verify the token can read organization '$organization'"
    return
  fi

  status="$(curl -sS -o /dev/null -w '%{http_code}' \
    --header "Authorization: Bearer ${token}" \
    --header "Content-Type: application/vnd.api+json" \
    "https://${TF_HOST}/api/v2/organizations/${organization}")" || die "Could not reach https://${TF_HOST}"

  case "$status" in
    200)
      log "Verified token access to Terraform organization '$organization'"
      ;;
    401)
      die "Terraform token was rejected (HTTP 401). Run 'terraform login' or replace the token in $OUTPUT_FILE."
      ;;
    404)
      die "Terraform organization '$organization' not found or not visible to this token (HTTP 404)"
      ;;
    *)
      die "Unexpected HTTP $status verifying Terraform organization '$organization'"
      ;;
  esac
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --tf-organization)
        [[ "${2:-}" != "" ]] || die "--tf-organization requires a name"
        TF_ORGANIZATION="$2"
        shift 2
        ;;
      --env-file)
        [[ "${2:-}" != "" ]] || die "--env-file requires a path"
        OUTPUT_FILE="$2"
        shift 2
        ;;
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

set_github_variable() {
  local name="$1"
  local value="$2"
  local repo_args=()
  local org_args=()

  [[ -n "$GITHUB_REPO" ]] && repo_args=(--repo "$GITHUB_REPO")
  [[ -n "$GITHUB_ORG" ]] && org_args=(--org "$GITHUB_ORG" --visibility all)

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would set GitHub variable '$name'"
    return
  fi

  gh variable set "$name" --body "$value" "${repo_args[@]}" "${org_args[@]}" >/dev/null
}

main() {
  parse_args "$@"

  need_cmd curl
  need_cmd jq

  if [[ "$GITHUB_SECRETS" == true ]]; then
    need_cmd gh
    if [[ "$DRY_RUN" == false ]]; then
      gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"
    else
      log "DRY RUN: would require 'gh auth status' before writing GitHub configuration"
    fi
  elif command -v gh >/dev/null 2>&1; then
    log "GitHub CLI detected. Re-run with --github-secrets to store GitHub secrets and variables."
  else
    log "GitHub CLI not found. Continuing without GitHub configuration storage."
  fi

  local organization
  local token
  organization="$(resolve_organization)"
  token="$(resolve_token)"
  verify_token "$organization" "$token"

  local env_content
  env_content="$(
    write_export "TF_CLOUD_ORGANIZATION" "$organization"
    write_export "TF_TOKEN_app_terraform_io" "$token"
  )"

  if [[ "$(read_env_file_var "TF_CLOUD_ORGANIZATION")" == "$organization" \
     && "$(read_env_file_var "TF_TOKEN_app_terraform_io")" == "$token" ]]; then
    log "'$OUTPUT_FILE' is already up to date"
  elif [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would write Terraform Cloud exports to '$OUTPUT_FILE'"
  else
    umask 077
    printf '%s\n' "$env_content" > "$OUTPUT_FILE"
    log "Wrote Terraform Cloud exports to '$OUTPUT_FILE'"
  fi

  if [[ "$PRINT_EXPORTS" == true ]]; then
    printf '%s\n' "$env_content"
  else
    log "Exports were not printed to stdout. Use --print if you need to display them."
  fi

  if [[ "$GITHUB_SECRETS" == true ]]; then
    set_github_variable "TF_CLOUD_ORGANIZATION" "$organization"
    set_github_secret "TF_TOKEN_app_terraform_io" "$token"
    [[ "$DRY_RUN" == true ]] || log "Stored GitHub configuration"
  fi

  cat >&2 <<EOF

Next steps:
  source $OUTPUT_FILE
  source .env.confluent-ci
  ../api-product-workflows/scripts/terraform/provision-kafka-local.sh develop
EOF
}

main "$@"
