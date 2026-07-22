#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

architecture_root="${1:-.}"
service_repository="${2:-}"
artifact="${3:-}"
version="${4:-}"
manifest_path="${5:-zenwave-architecture.yml}"
manifest="$architecture_root/$manifest_path"

arcadia_assert_artifact "$artifact"
arcadia_assert_release_version "$version"
arcadia_assert_safe_relative_path "$manifest_path"
[[ -s "$manifest" ]] || arcadia_die "architecture manifest is missing: $manifest"
arcadia_require_command jbang

jbang --quiet "$SCRIPT_DIR/UpdateArchitectureManifest.kt" \
  "$manifest" "$service_repository" "$artifact" "$version"

