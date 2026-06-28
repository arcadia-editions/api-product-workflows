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
release_artifact_id="${7:-}"
release_version="${8:-}"
[[ "$mode" == ci || "$mode" == release ]] || arcadia_die "unsupported execution mode: $mode"
jq -e 'type == "array" and all(.[]; (.type | IN("zdl", "zfl", "openapi", "asyncapi", "asyncapi-client")))' <<< "$plan" >/dev/null || arcadia_die "invalid execution plan"

kafka_plan="$(jq -c '[.[] | select(.type == "asyncapi" or .type == "asyncapi-client")]' <<< "$plan")"
if [[ "$release_artifact_id" != "service-all" && "$(jq length <<< "$kafka_plan")" -gt 1 ]]; then
  versions='[]'
  while IFS= read -r record; do
    type="$(jq -r .type <<< "$record")"
    path="$(jq -r .path <<< "$record")"
    version="$(arcadia_read_version "$type" "$root/$path")"
    versions="$(jq -c --arg version "$version" '. + [$version]' <<< "$versions")"
  done < <(jq -c '.[]' <<< "$kafka_plan")
  [[ "$(jq 'unique | length' <<< "$versions")" -eq 1 ]] || \
    arcadia_die "asyncapi and asyncapi-client versions must match: $(jq -c . <<< "$versions")"
fi

if [[ "$mode" == release ]]; then
  [[ -n "$release_artifact_id" ]] || arcadia_die "release artifactId is required"
  case "$release_artifact_id" in
    asyncapi-all)
      jq -e 'length > 0 and all(.[]; .type == "asyncapi" or .type == "asyncapi-client")' <<< "$plan" >/dev/null || \
        arcadia_die "release/asyncapi-all may contain only asyncapi and asyncapi-client artifacts"
      ;;
    service-all)
      arcadia_assert_release_version "$release_version"
      jq -e '
        length > 0 and all(.[]; .ownerKind == "service") and
        ([.[].ownerRef] | unique | length) == 1 and
        ([.[].groupId] | unique | length) == 1
      ' <<< "$plan" >/dev/null || arcadia_die "release/service-all must select one service owner and groupId"
      ;;
    *)
      [[ "$(jq length <<< "$plan")" -eq 1 ]] || \
        arcadia_die "a non-aggregate release must select exactly one artifact"
      ;;
  esac
fi

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
case "$release_artifact_id" in
  asyncapi-all)
    package="$($SCRIPT_DIR/package-asyncapi-bundle-jar.sh "$root" "$plan" "$output_root")"
    ;;
  service-all)
    package="$($SCRIPT_DIR/package-service-all-jar.sh "$root" "$plan" "$output_root" "$release_version")"
    ;;
  *)
    record="$(jq -c '.[0]' <<< "$plan")"
    package="$($SCRIPT_DIR/package-maven-jar.sh "$root" "$record" "$output_root")"
    ;;
esac

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

if [[ "$release_artifact_id" != "service-all" ]]; then
  while IFS= read -r record; do
    "$SCRIPT_DIR/publish-apicurio.sh" "$root" "$record" "${APICURIO_REGISTRY_URL:-}" "$settings"
  done < <(jq -c '.[]' <<< "$plan")
fi

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
