#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

mode="${1:-ci}"
plan="${2:-[]}"
root="${3:-.}"
pipeline_root="${4:-}"
manifest="${5:-}"
service_repository="${6:-}"
settings="${7:-}"
output_root="${8:-$root/target/artifacts}"

case "$mode" in ci|snapshot|release) ;; *) arcadia_die "unsupported execution mode: $mode" ;; esac
arcadia_require_command jq
jq -e 'type == "array" and all(.[]; (.type == "zdl" or .type == "openapi" or .type == "asyncapi" or .type == "api-product"))' <<< "$plan" >/dev/null || \
  arcadia_die "invalid execution plan"

mkdir -p "$output_root"
validation_summary='[]'
validation_failures=0
while IFS= read -r family; do
  [[ -n "$family" ]] || continue
  if "$SCRIPT_DIR/validate-artifact.sh" "$root" "$pipeline_root" "$family"; then
    result=success
  else
    result=failure
    validation_failures=$((validation_failures + 1))
  fi
  validation_summary="$(jq -c --arg family "$family" --arg result "$result" '. + [{family:$family,result:$result}]' <<< "$validation_summary")"
done < <(jq -r '.[].type' <<< "$plan")

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo '## Artifact validation'
    echo
    echo '| Family | Result |'
    echo '| --- | --- |'
    jq -r '.[] | "| \(.family) | \(.result) |"' <<< "$validation_summary"
  } >> "$GITHUB_STEP_SUMMARY"
fi
[[ "$validation_failures" -eq 0 ]] || arcadia_die "$validation_failures artifact validation(s) failed; packaging and publication skipped"

packages='[]'
commit="$(git -C "$root" rev-parse HEAD)"
while IFS= read -r family; do
  [[ -n "$family" ]] || continue
  family_packages="$($SCRIPT_DIR/package-maven-jar.sh "$root" "$manifest" "$service_repository" "$family" "$output_root" "$commit" "$mode")"
  packages="$(jq -c --argjson values "$family_packages" '. + $values' <<< "$packages")"
done < <(jq -r '.[].type' <<< "$plan")

file_repository="$output_root/file-maven-repository"
mkdir -p "$file_repository"
file_repository_url="$(ruby -e 'puts "file://#{File.expand_path(ARGV.fetch(0))}"' "$file_repository")"
while IFS= read -r record; do
  "$SCRIPT_DIR/deploy-maven-artifact.sh" "$record" "$file_repository_url" arcadia-file-backed "$settings" true
  group_path="$(jq -r .coordinates.groupPath <<< "$record")"
  artifact_id="$(jq -r .coordinates.artifactId <<< "$record")"
  version="$(jq -r .coordinates.deploymentVersion <<< "$record")"
  artifact_path="$(jq -r .coordinates.artifactPath <<< "$record")"
  deployed_dir="$file_repository/$group_path/$artifact_id/$version"
  deployed_jar="$(find "$deployed_dir" -maxdepth 1 -type f -name '*.jar' -print -quit)"
  [[ -n "$deployed_jar" ]] || arcadia_die "deployed JAR not found under manifest-core coordinates: $deployed_dir"
  unzip -p "$deployed_jar" "$artifact_path" >/dev/null || arcadia_die "manifest-declared path cannot be read from deployed JAR: $artifact_path"
done < <(jq -c '.[]' <<< "$packages")

if [[ "$mode" == "snapshot" || "$mode" == "release" ]]; then
  remote_url="${MAVEN_REPOSITORY_URL:-}"
  remote_id="${MAVEN_REPOSITORY_ID:-}"
  if [[ -n "$remote_url" || -n "$remote_id" ]]; then
    [[ -n "$remote_url" && -n "$remote_id" ]] || arcadia_die "both remote Maven repository URL and ID must be configured"
    while IFS= read -r record; do
      should_deploy=true
      if [[ "$mode" == "release" ]]; then
        group_path="$(jq -r .coordinates.groupPath <<< "$record")"
        artifact_id="$(jq -r .coordinates.artifactId <<< "$record")"
        version="$(jq -r .coordinates.deploymentVersion <<< "$record")"
        target_url="${remote_url%/}/$group_path/$artifact_id/$version/$artifact_id-$version.jar"
        existing="$output_root/existing-$artifact_id-$version.jar"
        curl_args=(--fail --location --silent --show-error)
        [[ -z "${MAVEN_REPOSITORY_USERNAME:-}" ]] || curl_args+=(--user "$MAVEN_REPOSITORY_USERNAME:${MAVEN_REPOSITORY_PASSWORD_OR_TOKEN:-}")
        if curl "${curl_args[@]}" "$target_url" --output "$existing"; then
          existing_checksum="$(sha256sum "$existing" | awk '{print $1}')"
          expected_checksum="$(jq -r .checksum <<< "$record")"
          [[ "$existing_checksum" == "$expected_checksum" ]] || arcadia_die "immutable Maven coordinate already contains different content: $target_url"
          should_deploy=false
        fi
      fi
      [[ "$should_deploy" != "true" ]] || "$SCRIPT_DIR/deploy-maven-artifact.sh" "$record" "$remote_url" "$remote_id" "$settings" false
    done < <(jq -c '.[]' <<< "$packages")
  fi
  if [[ -n "${APICURIO_REGISTRY_URL:-}" ]]; then
    service_id="$(jq -r '.[0].coordinates.serviceId // empty' <<< "$packages")"
    while IFS= read -r family; do
      "$SCRIPT_DIR/publish-apicurio.sh" "$root" "$service_id" "$family" "$APICURIO_REGISTRY_URL" "$settings"
    done < <(jq -r '.[].type' <<< "$plan")
  fi
fi

arcadia_write_output packages "$(jq -c . <<< "$packages")"
arcadia_write_output maven_repository "$file_repository"
arcadia_write_output generic_tree "$output_root/generic"
printf '%s\n' "$packages"
