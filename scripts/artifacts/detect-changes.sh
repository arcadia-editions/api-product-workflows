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

if [[ "$full_validation" == "true" ]]; then
  changed='[]'
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

arcadia_write_output plan "$(jq -c . <<< "$plan")"
arcadia_write_output changed_files "$(jq -c . <<< "$changed")"
printf '%s\n' "$(jq -c . <<< "$plan")"
