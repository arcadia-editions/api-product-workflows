#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
base="${2:-}"
head="${3:-HEAD}"
full_validation="${4:-false}"

arcadia_require_command git
arcadia_require_command jq

if [[ "$full_validation" == "true" ]]; then
  changed_json='[]'
else
  if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null; then
    base="$(git -C "$root" rev-parse "$head^" 2>/dev/null || git -C "$root" merge-base "$head" "origin/$(git -C "$root" remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')")"
  fi
  changed_json="$({ git -C "$root" diff --name-only --diff-filter=ACDMRTUXB -z "$base" "$head" || true; } | jq -Rs 'split("\u0000") | map(select(length > 0))')"
fi

family_files() {
  local family="$1"
  jq -c --arg family "$family" '
    [ .[] | select(
      if $family == "zdl" then
        . == "domain-model.zdl" or . == ".arcadia/versions/zdl.version"
      elif $family == "openapi" then
        . == "openapi.yml"
      elif $family == "asyncapi" then
        . == "asyncapi.yml" or . == "asyncapi-client.yml" or endswith(".avsc")
      elif $family == "api-product" then
        . == "domain-model.zdl" or . == ".arcadia/versions/zdl.version" or
        . == "openapi.yml" or . == "asyncapi.yml" or . == "asyncapi-client.yml" or
        endswith(".avsc") or . == ".arcadia/api-product.yml" or
        startswith(".arcadia/packaging/") or
        . == "README.md" or . == "SUMMARY.md" or . == "CHANGELOG.md"
      else false end
    ) ]
  ' <<< "$changed_json"
}

plan='[]'
publication_plan='[]'
for family in "${ARCADIA_ARTIFACT_TYPES[@]}"; do
  files="$(family_files "$family")"
  count="$(jq 'length' <<< "$files")"
  if [[ "$full_validation" == "true" || "$count" -gt 0 ]]; then
    plan="$(jq -c --arg type "$family" --argjson files "$files" '. + [{type: $type, changedFiles: $files}]' <<< "$plan")"
  fi
  if [[ "$count" -gt 0 ]]; then
    publication_plan="$(jq -c --arg type "$family" --argjson files "$files" '. + [{type: $type, changedFiles: $files}]' <<< "$publication_plan")"
  fi
done

if [[ "$full_validation" != "true" ]] && jq -e 'length > 0 and all(.[]; startswith(".github/workflows/") or startswith(".github/actions/"))' <<< "$changed_json" >/dev/null; then
  plan='[{"type":"zdl","changedFiles":[]},{"type":"openapi","changedFiles":[]},{"type":"asyncapi","changedFiles":[]},{"type":"api-product","changedFiles":[]}]'
fi

jq -e 'all(.[]; .type == "zdl" or .type == "openapi" or .type == "asyncapi" or .type == "api-product")' <<< "$plan" >/dev/null || \
  arcadia_die "change detector produced an invalid artifact type"

arcadia_write_output plan "$(jq -c . <<< "$plan")"
arcadia_write_output publication_plan "$(jq -c . <<< "$publication_plan")"
arcadia_write_output changed_files "$(jq -c . <<< "$changed_json")"
printf '%s\n' "$(jq -c . <<< "$plan")"

