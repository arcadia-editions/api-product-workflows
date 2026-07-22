#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

record="${1:-}"
repository_url="${2:-}"
repository_id="${3:-arcadia-file-backed}"
settings="${4:-}"
install_first="${5:-false}"

arcadia_require_command jq
arcadia_require_command mvn
[[ -n "$repository_url" ]] || arcadia_die "Maven repository URL is required"
[[ -s "$settings" ]] || arcadia_die "explicit Maven settings file is required"

jar_file="$(jq -r .jar <<< "$record")"
group_id="$(jq -r .coordinates.groupId <<< "$record")"
artifact_id="$(jq -r .coordinates.artifactId <<< "$record")"
version="$(jq -r .coordinates.deploymentVersion <<< "$record")"
[[ -s "$jar_file" ]] || arcadia_die "JAR does not exist: $jar_file"

if [[ "$install_first" == "true" ]]; then
  local_repo="$(mktemp -d)"
  mvn -B -ntp -s "$settings" -Dmaven.repo.local="$local_repo" \
    "org.apache.maven.plugins:maven-install-plugin:$ARCADIA_MAVEN_INSTALL_PLUGIN_VERSION:install-file" \
    -Dfile="$jar_file" -DgroupId="$group_id" -DartifactId="$artifact_id" \
    -Dversion="$version" -Dpackaging=jar -DgeneratePom=true
fi

mvn -B -ntp -s "$settings" \
  "org.apache.maven.plugins:maven-deploy-plugin:$ARCADIA_MAVEN_DEPLOY_PLUGIN_VERSION:deploy-file" \
  -Dfile="$jar_file" -DgroupId="$group_id" -DartifactId="$artifact_id" \
  -Dversion="$version" -Dpackaging=jar -DgeneratePom=true \
  -DrepositoryId="$repository_id" -Durl="$repository_url"

