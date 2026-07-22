#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

manifest="${1:-}"
service_repository="${2:-}"
manifest_type="${3:-}"
deployment_version="${4:-}"

[[ -s "$manifest" ]] || arcadia_die "manifest does not exist or is empty: $manifest"
[[ -n "$service_repository" ]] || arcadia_die "service repository is required"
arcadia_assert_semver "$deployment_version"
arcadia_require_command jbang

jbang --quiet "$SCRIPT_DIR/ManifestCoordinates.kt" \
  "$manifest" "$service_repository" "$manifest_type" "$deployment_version"

