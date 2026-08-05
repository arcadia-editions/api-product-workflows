#!/usr/bin/env bash

set -o pipefail

readonly ARCADIA_ARTIFACT_TYPES=(zdl zfl openapi asyncapi asyncapi-client)
readonly ARCADIA_ARTIFACTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ARCADIA_SPECTRAL_CLI_VERSION="6.15.0"
readonly ARCADIA_ASYNCAPI_CLI_VERSION="3.4.0"
readonly ARCADIA_REDOCLY_CLI_VERSION="1.34.5"
readonly ARCADIA_APICURIO_PLUGIN_VERSION="3.2.2"
readonly ARCADIA_MAVEN_DEPLOY_PLUGIN_VERSION="3.1.4"

arcadia_die() {
  echo "error: $*" >&2
  exit 1
}

arcadia_require_command() {
  command -v "$1" >/dev/null 2>&1 || arcadia_die "required command not found: $1"
}

arcadia_find() {
  if [[ -x /usr/bin/find ]]; then
    /usr/bin/find "$@"
  else
    find "$@"
  fi
}

arcadia_assert_type() {
  case "${1:-}" in
    zdl|zfl|openapi|asyncapi|asyncapi-client) ;;
    *) arcadia_die "unsupported artifact type: ${1:-<empty>}" ;;
  esac
}

arcadia_assert_semver() {
  local version="${1:-}"
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || \
    arcadia_die "invalid semantic version: $version"
}

arcadia_assert_release_version() {
  arcadia_assert_semver "$1"
  [[ "$1" != *-SNAPSHOT ]] || arcadia_die "release version must not end in -SNAPSHOT: $1"
}

arcadia_assert_snapshot_version() {
  arcadia_assert_semver "$1"
  [[ "$1" == *-SNAPSHOT ]] || arcadia_die "nextVersion must end in -SNAPSHOT: $1"
}

arcadia_assert_safe_relative_path() {
  local path="${1:-}"
  [[ -n "$path" && "$path" != /* && "$path" != *\\* ]] || arcadia_die "unsafe relative path: $path"
  [[ "/$path/" != *"/../"* && "/$path/" != *"/./"* && "$path" != *"//"* ]] || arcadia_die "unsafe relative path: $path"
}

arcadia_yaml_info_version() {
  ruby -e '
    require "yaml"
    value = YAML.safe_load_file(ARGV.fetch(0), aliases: false).dig("info", "version")
    abort("missing info.version in #{ARGV[0]}") if value.nil? || value.to_s.empty?
    puts value
  ' "$1"
}

arcadia_read_version() {
  local type="$1" file="$2"
  arcadia_assert_type "$type"
  case "$type" in
    zdl|zfl)
      arcadia_require_command jbang
      jbang --quiet "$ARCADIA_ARTIFACTS_SCRIPT_DIR/DslTool.java" read-version "$type" "$file" | tr -d '\r'
      ;;
    openapi|asyncapi|asyncapi-client) arcadia_yaml_info_version "$file" ;;
  esac
}

arcadia_source_files() {
  local root="$1" type="$2" path="$3"
  printf '%s\n' "$path"
  if [[ "$type" == "asyncapi" ]]; then
    git -C "$root" ls-files -- '*.avsc' '**/*.avsc'
  fi
}

arcadia_publish_to_apicurio() {
  case "$1" in openapi|asyncapi|asyncapi-client) return 0 ;; *) return 1 ;; esac
}

arcadia_write_output() {
  local name="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}
