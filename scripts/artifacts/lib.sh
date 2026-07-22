#!/usr/bin/env bash

set -o pipefail

readonly ARCADIA_ARTIFACT_TYPES=(zdl openapi asyncapi api-product)
readonly ARCADIA_MANIFEST_CORE_VERSION="0.9.0"
readonly ARCADIA_SPECTRAL_CLI_VERSION="6.15.0"
readonly ARCADIA_APICURIO_PLUGIN_VERSION="3.2.2"
readonly ARCADIA_MAVEN_INSTALL_PLUGIN_VERSION="3.1.4"
readonly ARCADIA_MAVEN_DEPLOY_PLUGIN_VERSION="3.1.4"

arcadia_die() {
  echo "error: $*" >&2
  exit 1
}

arcadia_require_command() {
  command -v "$1" >/dev/null 2>&1 || arcadia_die "required command not found: $1"
}

arcadia_assert_artifact() {
  case "${1:-}" in
    zdl|openapi|asyncapi|api-product) ;;
    *) arcadia_die "unsupported artifact family: ${1:-<empty>}" ;;
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
  [[ "$1" == *-SNAPSHOT ]] || arcadia_die "development version must end in -SNAPSHOT: $1"
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

arcadia_yaml_root_version() {
  ruby -e '
    require "yaml"
    value = YAML.safe_load_file(ARGV.fetch(0), aliases: false)["version"]
    abort("missing version in #{ARGV[0]}") if value.nil? || value.to_s.empty?
    puts value
  ' "$1"
}

arcadia_read_version() {
  local root="$1" artifact="$2"
  arcadia_assert_artifact "$artifact"
  case "$artifact" in
    zdl)
      [[ -s "$root/.arcadia/versions/zdl.version" ]] || arcadia_die "missing .arcadia/versions/zdl.version"
      tr -d '[:space:]' < "$root/.arcadia/versions/zdl.version"
      ;;
    openapi) arcadia_yaml_info_version "$root/openapi.yml" ;;
    asyncapi) arcadia_yaml_info_version "$root/asyncapi.yml" ;;
    api-product) arcadia_yaml_root_version "$root/.arcadia/api-product.yml" ;;
  esac
}

arcadia_manifest_types() {
  case "$1" in
    asyncapi) printf '%s\n' asyncapi asyncapi-client ;;
    *) printf '%s\n' "$1" ;;
  esac
}

arcadia_source_files() {
  local root="$1" artifact="$2"
  arcadia_assert_artifact "$artifact"
  case "$artifact" in
    zdl)
      printf '%s\n' domain-model.zdl
      ;;
    openapi)
      printf '%s\n' openapi.yml
      ;;
    asyncapi)
      printf '%s\n' asyncapi.yml
      git -C "$root" ls-files -- 'asyncapi-client.yml' '*.avsc' '**/*.avsc'
      ;;
    api-product)
      printf '%s\n' .arcadia/api-product.yml .arcadia/versions/zdl.version domain-model.zdl openapi.yml asyncapi.yml
      git -C "$root" ls-files -- 'asyncapi-client.yml' '*.avsc' '**/*.avsc' 'README.md' 'SUMMARY.md' 'CHANGELOG.md'
      ;;
  esac | awk 'NF && !seen[$0]++'
}

arcadia_manifest_source_files() {
  local root="$1" manifest_type="$2"
  case "$manifest_type" in
    zdl) printf '%s\n' domain-model.zdl ;;
    openapi) printf '%s\n' openapi.yml ;;
    asyncapi)
      printf '%s\n' asyncapi.yml
      git -C "$root" ls-files -- '*.avsc' '**/*.avsc'
      ;;
    asyncapi-client) printf '%s\n' asyncapi-client.yml ;;
    api-product) arcadia_source_files "$root" api-product ;;
    *) arcadia_die "unsupported manifest artifact type: $manifest_type" ;;
  esac | awk 'NF && !seen[$0]++'
}

arcadia_write_output() {
  local name="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

