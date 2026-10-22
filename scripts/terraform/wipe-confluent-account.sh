#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Reset a Confluent Cloud *test* account to an empty Kafka/Schema Registry,
# independently of Terraform state. Deletes:
#   - every Kafka ACL whose principal is not a protected service account
#   - every topic, except internal ones and Confluent-managed _confluent* topics
#   - every Schema Registry subject (hard delete) and its subject-level config
#   - every service account generated from AsyncAPI
#     (description "Managed from AsyncAPI principal ...")
#
# Protected (never deleted): the owners of the API keys this script runs with,
# any service account that still owns API keys, and the service accounts named
# in KEEP_SERVICE_ACCOUNTS (default zenwave-ci-sa). API key owners are read with
# the Cloud key, or with the confluent CLI (logging in if needed) when that is
# forbidden.
#
# Dry run by default; pass --yes to delete.
#
# Usage (from api-product-workflows or any directory):
#   bash scripts/terraform/wipe-confluent-account.sh          # show what would be deleted
#   bash scripts/terraform/wipe-confluent-account.sh --yes    # delete

usage() {
  cat >&2 <<'EOF'
Usage: wipe-confluent-account.sh [--yes]

Dry run unless --yes is given. Credentials come from the TF_VAR_* variables
already exported, or from api-product-workflows/.env.confluent-ci.
Set KEEP_SERVICE_ACCOUNTS (comma-separated names or sa-... ids) to protect more accounts.
EOF
}

execute=false
for argument in "$@"; do
  case "$argument" in
    --yes|-y) execute=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; usage; exit 2 ;;
  esac
done

log() { printf '[wipe-confluent] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# jq on Windows ends lines with CRLF; a stray \r would end up in URLs and ids.
jq() { command jq "$@" | tr -d '\r'; }
command -v curl >/dev/null 2>&1 || die "curl is required"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
workflow_dir="$(cd -- "$script_dir/../.." && pwd -P)"
if [[ -z "${TF_VAR_confluent_cloud_api_key:-}" && -f "$workflow_dir/.env.confluent-ci" ]]; then
  source "$workflow_dir/.env.confluent-ci"
fi

for name in confluent_cloud_api_key confluent_cloud_api_secret kafka_id kafka_rest_endpoint \
            kafka_api_key kafka_api_secret schema_registry_rest_endpoint \
            schema_registry_api_key schema_registry_api_secret; do
  var="TF_VAR_$name"
  [[ -n "${!var:-}" ]] || die "$var is not set"
done

CLOUD_API="https://api.confluent.cloud"
CAUTH="$TF_VAR_confluent_cloud_api_key:$TF_VAR_confluent_cloud_api_secret"
KAUTH="$TF_VAR_kafka_api_key:$TF_VAR_kafka_api_secret"
SRAUTH="$TF_VAR_schema_registry_api_key:$TF_VAR_schema_registry_api_secret"
KR="${TF_VAR_kafka_rest_endpoint%/}/kafka/v3/clusters/$TF_VAR_kafka_id"
SR="${TF_VAR_schema_registry_rest_endpoint%/}"
KEEP_SERVICE_ACCOUNTS="${KEEP_SERVICE_ACCOUNTS:-zenwave-ci-sa}"

failures=0

# api <auth> <method> <url> [extra accepted HTTP codes...]
# Prints the response body; returns 1 (and logs the response) on any other status.
api() {
  local auth="$1" method="$2" url="$3"
  shift 3
  local accepted=" 200 201 202 204 $* " response code body
  response="$(curl -sS -u "$auth" -X "$method" -w $'\n%{http_code}' "$url")" || {
    log "$method $url: request failed"
    return 1
  }
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$accepted" != *" $code "* ]]; then
    log "$method $url -> HTTP $code: $(printf '%s' "$body" | head -c 300)"
    return 1
  fi
  printf '%s' "$body"
}

uri() { jq -rn --arg value "$1" '$value | @uri'; }

# delete_call <description> <auth> <url> [extra accepted codes...]
delete_call() {
  local description="$1" auth="$2" url="$3"
  shift 3
  if [[ "$execute" != true ]]; then
    log "would delete $description"
    return 0
  fi
  if api "$auth" DELETE "$url" "$@" >/dev/null; then
    log "deleted $description"
  else
    failures=$((failures + 1))
  fi
}

# The CI Cloud key usually may not read API keys (403), so API key lookups fall
# back to the Confluent CLI, logged in as the user.
cli_ready=false
ensure_cli() {
  [[ "$cli_ready" == true ]] && return 0
  command -v confluent >/dev/null 2>&1 || die "Cannot read API keys with the Cloud key and the confluent CLI is not installed"
  if ! confluent context describe >/dev/null 2>&1; then
    log "Logging in to Confluent Cloud to look up API key owners"
    confluent login </dev/tty >&2 || die "confluent login failed"
  fi
  cli_ready=true
}

key_owner() {
  local owner
  if owner="$(api "$CAUTH" GET "$CLOUD_API/iam/v2/api-keys/$1" 2>/dev/null | jq -r '.spec.owner.id // empty')" && [[ -n "$owner" ]]; then
    printf '%s\n' "$owner"
    return
  fi
  ensure_cli
  confluent api-key describe "$1" -o json | jq -r 'if type == "array" then .[0] else . end | .owner // .owner_resource_id // empty'
}

owned_keys_rest() {
  api "$CAUTH" GET "$CLOUD_API/iam/v2/api-keys?spec.owner=$1&page_size=100" 2>/dev/null | jq -r '.data[].id'
}

owned_keys_cli() {
  ensure_cli
  confluent api-key list --service-account "$1" -o json | jq -r '.[].key'
}

# Key listings only show keys visible to the caller, so "owns no keys" is only
# trusted from a source that can see the Cloud key this script runs with.
key_listing_source=none
choose_key_listing_source() {
  local owner="$1" keys source
  for source in rest cli; do
    if keys="$("owned_keys_$source" "$owner")" && grep -qxF "$TF_VAR_confluent_cloud_api_key" <<<"$keys"; then
      key_listing_source="$source"
      return
    fi
  done
  log "WARNING: cannot verify API key visibility; no service account will be deleted"
}

owned_key_count() {
  local keys
  [[ "$key_listing_source" != none ]] || return 1
  keys="$("owned_keys_$key_listing_source" "$1")" || return 1
  grep -c . <<<"$keys" || true
}

list_service_accounts() {
  local url="$CLOUD_API/iam/v2/service-accounts?page_size=100" page
  while [[ -n "$url" ]]; do
    page="$(api "$CAUTH" GET "$url")"
    jq -c '.data[]' <<<"$page"
    url="$(jq -r '.metadata.next // empty' <<<"$page")"
  done
}

list_subjects() {
  api "$SRAUTH" GET "$SR/subjects?deleted=true" | jq -r '.[]'
}

list_topics() {
  api "$KAUTH" GET "$KR/topics" \
    | jq -r '.data[] | select(.is_internal | not) | .topic_name | select(startswith("_confluent") | not)'
}

# hard_delete_subject <subject> -> soft delete (if needed), hard delete, drop subject config
hard_delete_subject() {
  local encoded
  encoded="$(uri "$1")"
  api "$SRAUTH" DELETE "$SR/subjects/$encoded" 404 >/dev/null 2>&1 || true
  api "$SRAUTH" DELETE "$SR/subjects/$encoded?permanent=true" 404 >/dev/null || return 1
  api "$SRAUTH" DELETE "$SR/config/$encoded" 404 >/dev/null 2>&1 || true
}

# --- Preflight: every API must accept its key before anything is deleted ---
api "$CAUTH" GET "$CLOUD_API/iam/v2/service-accounts?page_size=1" >/dev/null \
  || die "Cloud API key rejected (it needs OrganizationAdmin or AccountAdmin to manage service accounts)"
api "$KAUTH" GET "$KR/topics" >/dev/null || die "Kafka API key rejected for cluster $TF_VAR_kafka_id"
api "$SRAUTH" GET "$SR/subjects" >/dev/null || die "Schema Registry API key rejected"

# --- Protected service accounts: the owners of the keys this script runs with ---
declare -A protected=()
for key in "$TF_VAR_confluent_cloud_api_key" "$TF_VAR_kafka_api_key" "$TF_VAR_schema_registry_api_key"; do
  owner="$(key_owner "$key")" || die "Could not resolve the owner of API key $key"
  [[ -n "$owner" ]] || die "Could not resolve the owner of API key $key"
  protected["$owner"]=1
  [[ "$key" == "$TF_VAR_confluent_cloud_api_key" ]] && cloud_key_owner="$owner"
done
choose_key_listing_source "$cloud_key_owner"

service_accounts="$(list_service_accounts)"
IFS=',' read -r -a keep_names <<<"$KEEP_SERVICE_ACCOUNTS"
for keep_name in "${keep_names[@]}"; do
  while read -r id; do
    [[ -n "$id" ]] && protected["$id"]=1
  done < <(jq -r --arg name "$keep_name" 'select(.display_name == $name or .id == $name) | .id' <<<"$service_accounts")
done

[[ "${#protected[@]}" -gt 0 ]] \
  || die "No protected service account found (looked for: $KEEP_SERVICE_ACCOUNTS); set KEEP_SERVICE_ACCOUNTS"
log "Protected service accounts: ${!protected[*]}"
[[ "$execute" == true ]] || log "DRY RUN: nothing will be deleted (pass --yes to delete)"

# --- ACLs: delete per non-protected principal. UserV2:* asks for sa-... ids
# instead of numeric ones; any principal that is still not an sa-... id cannot
# be checked against the protected set and is skipped. ---
acls="$(api "$KAUTH" GET "$KR/acls?principal=$(uri 'UserV2:*')" 2>/dev/null)" \
  || acls="$(api "$KAUTH" GET "$KR/acls")"
log "Found $(jq '.data | length' <<<"$acls") ACL(s) in cluster $TF_VAR_kafka_id"
acl_principals="$(jq -r '.data[].principal' <<<"$acls" | sort -u)"
while read -r principal; do
  [[ -n "$principal" ]] || continue
  account="${principal#*:}"
  if [[ "$account" != sa-* ]]; then
    log "WARNING: skipping ACLs of $principal: cannot tell whether it is a protected service account"
    failures=$((failures + 1))
    continue
  fi
  [[ -n "${protected[$account]:-}" ]] && continue
  delete_call "ACLs of $principal" "$KAUTH" \
    "$KR/acls?principal=$(uri "$principal")&resource_type=ANY&pattern_type=ANY&operation=ANY&permission=ANY"
done <<<"$acl_principals"

# --- Topics ---
topics="$(list_topics)"
while read -r topic; do
  [[ -n "$topic" ]] || continue
  delete_call "topic $topic" "$KAUTH" "$KR/topics/$(uri "$topic")" 404
done <<<"$topics"

# --- Schema subjects. Referenced subjects cannot be hard-deleted before their
# referrers, so keep passing while each pass makes progress; whatever is left
# is reported by the verification below. ---
subjects="$(list_subjects)"
if [[ "$execute" != true ]]; then
  while read -r subject; do
    [[ -n "$subject" ]] && log "would delete subject $subject"
  done <<<"$subjects"
else
  while [[ -n "$subjects" ]]; do
    while read -r subject; do
      hard_delete_subject "$subject" 2>/dev/null && log "deleted subject $subject"
    done <<<"$subjects"
    remaining="$(list_subjects)"
    if [[ "$remaining" == "$subjects" ]]; then
      # No progress: one last pass with errors shown, so the cause is visible.
      while read -r subject; do
        hard_delete_subject "$subject" || true
      done <<<"$remaining"
      break
    fi
    subjects="$remaining"
  done
fi

# --- Service accounts generated from AsyncAPI (their role bindings go with them) ---
while read -r account; do
  [[ -n "$account" ]] || continue
  id="$(jq -r '.id' <<<"$account")"
  name="$(jq -r '.display_name' <<<"$account")"
  if [[ -n "${protected[$id]:-}" ]]; then
    log "keeping protected service account $name ($id)"
    continue
  fi
  owned_keys="$(owned_key_count "$id")" || {
    log "keeping $name ($id): could not check its API keys"
    failures=$((failures + 1))
    continue
  }
  if [[ "$owned_keys" != 0 ]]; then
    log "keeping $name ($id): it owns $owned_keys API key(s)"
    continue
  fi
  if [[ "$execute" != true ]]; then
    log "would delete service account $name ($id)"
  elif api "$CAUTH" DELETE "$CLOUD_API/iam/v2/service-accounts/$id" 404 >/dev/null 2>&1; then
    log "deleted service account $name ($id)"
  elif ensure_cli && confluent iam service-account delete "$id" --force >&2; then
    # The CI Cloud key may list service accounts but not delete them.
    log "deleted service account $name ($id) with the confluent CLI"
  else
    log "could not delete service account $name ($id)"
    failures=$((failures + 1))
  fi
done < <(jq -c 'select((.description // "") | startswith("Managed from AsyncAPI principal"))' <<<"$service_accounts")

[[ "$execute" == true ]] || exit 0

# --- Verify (topic deletion is asynchronous) ---
for attempt in 1 2 3 4 5 6; do
  remaining_topics="$(list_topics)"
  remaining_subjects="$(list_subjects)"
  [[ -z "$remaining_topics" && -z "$remaining_subjects" ]] && break
  sleep 5
done
[[ -z "$remaining_topics" ]] || { log "topics still present: $(tr '\n' ' ' <<<"$remaining_topics")"; failures=$((failures + 1)); }
[[ -z "$remaining_subjects" ]] || { log "subjects still present: $(tr '\n' ' ' <<<"$remaining_subjects")"; failures=$((failures + 1)); }

if [[ "$failures" -gt 0 ]]; then
  die "$failures operation(s) failed; re-run the script after fixing the errors above"
fi
log "Confluent account wiped. Terraform Cloud state is untouched; run wipe-terraform-workspaces.sh to reset it too."
