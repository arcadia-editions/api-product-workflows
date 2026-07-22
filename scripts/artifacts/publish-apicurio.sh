#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
service_id="${2:-}"
family="${3:-}"
registry_url="${4:-}"
settings="${5:-}"

[[ "$family" == "openapi" || "$family" == "asyncapi" ]] || exit 0
[[ -n "$registry_url" ]] || exit 0
[[ -n "$service_id" ]] || arcadia_die "service ID is required for Apicurio publication"
[[ -s "$settings" ]] || arcadia_die "explicit Maven settings file is required"
arcadia_require_command mvn

files=(openapi.yml)
type="OPENAPI"
if [[ "$family" == "asyncapi" ]]; then
  files=(asyncapi.yml)
  [[ ! -f "$root/asyncapi-client.yml" ]] || files+=(asyncapi-client.yml)
  type="ASYNCAPI"
fi

index=0
properties=()
for file in "${files[@]}"; do
  properties+=(
    "-Dartifacts.$index.groupId=$service_id"
    "-Dartifacts.$index.artifactId=$file"
    "-Dartifacts.$index.artifactType=$type"
    "-Dartifacts.$index.file=$root/$file"
    "-Dartifacts.$index.versionStrategy=API_INFO_VERSION"
    "-Dartifacts.$index.ifExists=FIND_OR_CREATE_VERSION"
    "-Dartifacts.$index.autoRefs=true"
  )
  index=$((index + 1))
done

auth=()
[[ -z "${APICURIO_USERNAME:-}" ]] || auth+=("-Dapicurio.username=$APICURIO_USERNAME")
[[ -z "${APICURIO_PASSWORD_OR_TOKEN:-}" ]] || auth+=("-Dapicurio.password=$APICURIO_PASSWORD_OR_TOKEN")

mvn -B -ntp -s "$settings" \
  "io.apicurio:apicurio-registry-maven-plugin:${APICURIO_MAVEN_PLUGIN_VERSION:-$ARCADIA_APICURIO_PLUGIN_VERSION}:register" \
  "-Dapicurio.url=$registry_url" "${properties[@]}" "${auth[@]}"

