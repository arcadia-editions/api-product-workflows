#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
manifest_uri="${2:-}"
repository="${3:-}"
base="${4:-}"
head="${5:-HEAD}"
full_validation="${6:-false}"

arcadia_require_command git
arcadia_require_command jbang
arcadia_require_command jq
[[ "$manifest_uri" == http://* || "$manifest_uri" == https://* ]] || arcadia_die "master manifest must be an HTTP URI"

inventory="$(jbang --quiet "$SCRIPT_DIR/ManifestTool.java" list "$manifest_uri" "$repository")"
jq -e 'type == "array"' <<< "$inventory" >/dev/null || arcadia_die "manifest inventory is invalid"
changed='[]'
deleted='[]'

if [[ "$full_validation" == "true" ]]; then
  plan="$inventory"
else
  if [[ -z "$base" || "$base" =~ ^0+$ ]] || ! git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null; then
    base="$(git -C "$root" rev-parse "$head^" 2>/dev/null || git -C "$root" merge-base "$head" "origin/$(git -C "$root" remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p')")"
  fi
  changed="$({ git -C "$root" diff --name-only --diff-filter=ACDMRTUXB -z "$base" "$head" || true; } | jq -Rs 'split("\u0000") | map(select(length > 0))')"
  deleted="$({ git -C "$root" diff --name-only --diff-filter=D -z "$base" "$head" || true; } | jq -Rs 'split("\u0000") | map(select(length > 0))')"

  if jq -e 'length > 0' <<< "$deleted" >/dev/null; then
    # a deleted file cannot be resolved to check whether artifacts still $ref it:
    # revalidate every artifact regardless of relevance
    plan="$(jq -c 'map(. + {changedFiles:[]})' <<< "$inventory")"
  elif jq -e 'length > 0 and all(.[]; startswith(".github/workflows/") or startswith(".github/actions/"))' <<< "$changed" >/dev/null; then
    # pipeline itself changed: revalidate every artifact regardless of relevance
    plan="$(jq -c 'map(. + {changedFiles:[]})' <<< "$inventory")"
  else
    plan='[]'
    while IFS= read -r artifact; do
      path="$(jq -r .path <<< "$artifact")"
      type="$(jq -r .type <<< "$artifact")"
      relevant="$(jq -cn --arg p "$path" '[$p]')"
      if [[ "$type" == openapi || "$type" == asyncapi ]]; then
        refs="$(arcadia_resolve_refs "$root" "$path" | jq -Rs 'split("\n") | map(select(length > 0))')"
        relevant="$(jq -c -n --argjson a "$relevant" --argjson b "$refs" '$a + $b')"
      fi
      files="$(jq -c -n --argjson changed "$changed" --argjson relevant "$relevant" '[$changed[] | select(. as $f | $relevant | index($f) != null)]')"
      if jq -e 'length > 0' <<< "$files" >/dev/null; then
        plan="$(jq -c --argjson artifact "$artifact" --argjson files "$files" '. + [$artifact + {changedFiles:$files}]' <<< "$plan")"
      fi
    done < <(jq -c '.[]' <<< "$inventory")
  fi
fi

# asyncapi-all is one validation, release and deployment unit. Resolve it when
# an AsyncAPI member is selected or any Avro schema changed. The latter is
# intentionally repository-wide: even an unreferenced .avsc change must run the
# complete Kafka contract validation so missing references cannot hide it.
selected="$(jq -c 'map(. + {changedFiles:(.changedFiles // [])})' <<< "$plan")"
avsc_changed="$(jq -r -n --argjson changed "$changed" --argjson deleted "$deleted" '
  any(($changed + $deleted)[]; ascii_downcase | endswith(".avsc"))
')"
if [[ "$avsc_changed" == "true" ]] || \
  jq -e 'any(.[]; .type == "asyncapi" or .type == "asyncapi-client")' <<< "$selected" >/dev/null; then
  bundle="$(jbang --quiet "$SCRIPT_DIR/ManifestTool.java" resolve "$manifest_uri" "$repository" asyncapi-all)"
  jq -e 'type == "array" and length > 0' <<< "$bundle" >/dev/null || arcadia_die "asyncapi-all selection is invalid"
  plan="$(jq -c -n --argjson bundle "$bundle" --argjson selected "$selected" '
    ($selected | map({key:.artifactId, value:.changedFiles}) | from_entries) as $changedByArtifact
    | ([$selected[] | select(.type != "asyncapi" and .type != "asyncapi-client")]
      + [$bundle[] | . + {changedFiles:($changedByArtifact[.artifactId] // [])}])
  ')"
else
  plan="$selected"
fi

arcadia_write_output plan "$(jq -c . <<< "$plan")"
arcadia_write_output changed_files "$(jq -c . <<< "$changed")"
printf '%s\n' "$(jq -c . <<< "$plan")"
