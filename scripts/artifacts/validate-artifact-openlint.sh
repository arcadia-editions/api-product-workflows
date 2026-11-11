#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
pipeline_root="${2:-}"
record="${3:-}"
type="$(jq -r .type <<< "$record")"
relative_path="$(jq -r .path <<< "$record")"
arcadia_assert_type "$type"
arcadia_assert_safe_relative_path "$relative_path"
file="$root/$relative_path"
[[ -s "$file" ]] || arcadia_die "artifact file is missing or empty: $relative_path"

version="$(arcadia_read_version "$type" "$file")"
arcadia_assert_semver "$version"

case "$type" in
  zdl|zfl)
    jbang --quiet "$SCRIPT_DIR/DslTool.java" validate "$type" "$file"
    ;;
  openapi|asyncapi|asyncapi-client)
    if [[ "$type" == asyncapi || "$type" == asyncapi-client ]]; then
      "$(arcadia_locked_cli asyncapi)" validate "$file"
    fi
    "$SCRIPT_DIR/lint-openlint.sh" "$file"
    if [[ "$type" == "asyncapi" ]]; then
      while IFS= read -r referenced; do
        [[ "$referenced" == *.avsc ]] || continue
        ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$root/$referenced"
      done < <(arcadia_resolve_refs "$root" "$relative_path")
    fi
    ;;
esac

printf '%s (%s) %s validated\n' "$(jq -r .artifactId <<< "$record")" "$type" "$version"
