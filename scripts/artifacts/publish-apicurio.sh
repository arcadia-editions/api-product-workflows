#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
record="${2:-}"
registry_url="${3:-}"
settings="${4:-}"
type="$(jq -r .type <<< "$record")"
arcadia_publish_to_apicurio "$type" || exit 0
[[ -n "$registry_url" ]] || exit 0
[[ -s "$settings" ]] || arcadia_die "explicit Maven settings file is required"

relative_path="$(jq -r .path <<< "$record")"
owner_id="$(jq -r .ownerId <<< "$record")"
artifact_id="$(jq -r .artifactId <<< "$record")"
registry_type="$( [[ "$type" == openapi ]] && printf OPENAPI || printf ASYNCAPI )"
properties=(
  "-Dartifacts.0.groupId=$owner_id"
  "-Dartifacts.0.artifactId=$artifact_id"
  "-Dartifacts.0.artifactType=$registry_type"
  "-Dartifacts.0.file=$root/$relative_path"
  "-Dartifacts.0.versionStrategy=API_INFO_VERSION"
  "-Dartifacts.0.ifExists=FIND_OR_CREATE_VERSION"
  "-Dartifacts.0.autoRefs=true"
)
auth=()
[[ -z "${APICURIO_USERNAME:-}" ]] || auth+=("-Dapicurio.username=$APICURIO_USERNAME")
[[ -z "${APICURIO_PASSWORD_OR_TOKEN:-}" ]] || auth+=("-Dapicurio.password=$APICURIO_PASSWORD_OR_TOKEN")

mvn -B -ntp -s "$settings" \
  "io.apicurio:apicurio-registry-maven-plugin:${APICURIO_MAVEN_PLUGIN_VERSION:-$ARCADIA_APICURIO_PLUGIN_VERSION}:register" \
  "-Dapicurio.url=$registry_url" "${properties[@]}" "${auth[@]}"
