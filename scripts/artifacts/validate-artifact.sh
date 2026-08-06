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

spectral() {
  local ruleset_url="${SPECTRAL_BUNDLE_URL:?SPECTRAL_BUNDLE_URL is required}"
  npx --yes "@stoplight/spectral-cli@$ARCADIA_SPECTRAL_CLI_VERSION" lint --fail-severity=error -r "$ruleset_url" "$file"
}

case "$type" in
  zdl|zfl)
    jbang --quiet "$SCRIPT_DIR/DslTool.java" validate "$type" "$file"
    ;;
  openapi)
    npx --yes "@redocly/cli@$ARCADIA_REDOCLY_CLI_VERSION" lint "$file"
    spectral
    ;;
  asyncapi|asyncapi-client)
    npx --yes "@asyncapi/cli@$ARCADIA_ASYNCAPI_CLI_VERSION" validate "$file"
    spectral
    if [[ "$type" == "asyncapi" ]]; then
      while IFS= read -r avro; do
        [[ -z "$avro" ]] || ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$root/$avro"
      done < <(git -C "$root" ls-files -- '*.avsc' '**/*.avsc')
    fi
    ;;
esac

printf '%s (%s) %s validated\n' "$(jq -r .artifactId <<< "$record")" "$type" "$version"
