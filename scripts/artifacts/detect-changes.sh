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
  plan="$(jq -c --argjson changed "$changed" '
    [ .[] as $artifact |
      ([ $changed[] | select(
        . == $artifact.path or
        (($artifact.type == "asyncapi" or $artifact.type == "asyncapi-client") and endswith(".avsc"))
      ) ]) as $files |
      select(($files | length) > 0) |
      $artifact + {changedFiles:$files}
    ]
  ' <<< "$inventory")"
  if jq -e 'length > 0 and all(.[]; startswith(".github/workflows/") or startswith(".github/actions/"))' <<< "$changed" >/dev/null; then
    plan="$(jq -c 'map(. + {changedFiles:[]})' <<< "$inventory")"
  fi
fi

arcadia_write_output plan "$(jq -c . <<< "$plan")"
arcadia_write_output changed_files "$(jq -c . <<< "$changed")"
printf '%s\n' "$(jq -c . <<< "$plan")"
