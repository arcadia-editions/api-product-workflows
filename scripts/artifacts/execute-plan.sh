#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

mode="${1:-ci}"
plan="${2:-[]}"
root="${3:-.}"
pipeline_root="${4:-}"
settings="${5:-}"
output_root="${6:-$root/target/artifacts}"
[[ "$mode" == ci || "$mode" == release ]] || arcadia_die "unsupported execution mode: $mode"
jq -e 'type == "array" and all(.[]; (.type | IN("zdl", "zfl", "openapi", "asyncapi", "asyncapi-client")))' <<< "$plan" >/dev/null || arcadia_die "invalid execution plan"
[[ "$mode" == ci || "$(jq length <<< "$plan")" -eq 1 ]] || arcadia_die "a release must select exactly one artifact"

failures=0
while IFS= read -r record; do
  "$SCRIPT_DIR/validate-artifact.sh" "$root" "$pipeline_root" "$record" || failures=$((failures + 1))
done < <(jq -c '.[]' <<< "$plan")
[[ "$failures" -eq 0 ]] || arcadia_die "$failures artifact validation(s) failed"

if [[ "$mode" == ci ]]; then
  arcadia_write_output packages '[]'
  exit 0
fi

mkdir -p "$output_root"
record="$(jq -c '.[0]' <<< "$plan")"
package="$($SCRIPT_DIR/package-maven-jar.sh "$root" "$record" "$output_root")"

if [[ -n "${MAVEN_REPOSITORY_URL:-}" ]]; then
  [[ -n "${MAVEN_REPOSITORY_ID:-}" && -s "$settings" ]] || arcadia_die "Maven repository ID and settings are required"
  mvn -B -ntp -s "$settings" \
    "org.apache.maven.plugins:maven-deploy-plugin:$ARCADIA_MAVEN_DEPLOY_PLUGIN_VERSION:deploy-file" \
    "-Dfile=$(jq -r .jar <<< "$package")" \
    "-DgroupId=$(jq -r .groupId <<< "$package")" \
    "-DartifactId=$(jq -r .artifactId <<< "$package")" \
    "-Dversion=$(jq -r .deploymentVersion <<< "$package")" \
    -Dpackaging=jar -DgeneratePom=true \
    "-DrepositoryId=$MAVEN_REPOSITORY_ID" "-Durl=$MAVEN_REPOSITORY_URL"
fi

"$SCRIPT_DIR/publish-apicurio.sh" "$root" "$package" "${APICURIO_REGISTRY_URL:-}" "$settings"

if [[ -n "${ARTIFACTORY_GENERIC_RELEASE_URL:-}" ]]; then
  generic_tree="$(jq -r .genericTree <<< "$package")"
  artifactory_root="$output_root/artifactory"
  curl_auth=()
  [[ -z "${ARTIFACTORY_USERNAME:-}" ]] || curl_auth+=(--user "$ARTIFACTORY_USERNAME:${ARTIFACTORY_PASSWORD_OR_TOKEN:-}")
  while IFS= read -r local_file; do
    remote_path="${local_file#"$artifactory_root"/}"
    curl --fail --silent --show-error "${curl_auth[@]}" \
      --upload-file "$local_file" "${ARTIFACTORY_GENERIC_RELEASE_URL%/}/$remote_path"
  done < <(arcadia_find "$generic_tree" -type f | /usr/bin/sort)
fi

packages="[$package]"
arcadia_write_output packages "$(jq -c . <<< "$packages")"
printf '%s\n' "$packages"
