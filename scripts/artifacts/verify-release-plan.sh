#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
plan="${2:-[]}"
release_artifact_id="${3:-}"
release_version="${4:-}"
default_branch="${5:-main}"

arcadia_assert_release_version "$release_version"
[[ "$release_artifact_id" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || \
  arcadia_die "unsafe release artifactId: $release_artifact_id"
jq -e 'type == "array" and length > 0' <<< "$plan" >/dev/null || arcadia_die "release plan must not be empty"

case "$release_artifact_id" in
  asyncapi-all)
    jq -e 'all(.[]; .type == "asyncapi" or .type == "asyncapi-client")' <<< "$plan" >/dev/null || \
      arcadia_die "the asyncapi-all release may contain only asyncapi and asyncapi-client artifacts"
    ;;
  service-all)
    jq -e '
      all(.[]; .ownerKind == "service") and
      ([.[].ownerRef] | unique | length) == 1 and
      ([.[].repository] | unique | length) == 1 and
      ([.[].groupId] | unique | length) == 1
    ' <<< "$plan" >/dev/null || \
      arcadia_die "service-all must select every artifact from one service owner and groupId"
    ;;
  *)
    [[ "$(jq length <<< "$plan")" -eq 1 ]] || \
      arcadia_die "a non-aggregate release must select exactly one artifact"
    ;;
esac

versions='[]'
while IFS= read -r record; do
  type="$(jq -r .type <<< "$record")"
  path="$(jq -r .path <<< "$record")"
  arcadia_assert_type "$type"
  arcadia_assert_safe_relative_path "$path"
  current="$(arcadia_read_version "$type" "$root/$path")"
  arcadia_assert_semver "$current"
  versions="$(jq -c --arg version "$current" '. + [$version]' <<< "$versions")"
done < <(jq -c '.[]' <<< "$plan")

if [[ "$release_artifact_id" != "service-all" && "$(jq 'unique | length' <<< "$versions")" -ne 1 ]]; then
  arcadia_die "artifacts in release/$release_artifact_id must have the same current version: $(jq -c . <<< "$versions")"
fi

if [[ "$release_artifact_id" == "service-all" ]]; then
  current_version="$(jq -r '.[0].ownerVersion' <<< "$plan")"
  arcadia_assert_semver "$current_version"
else
  current_version="$(jq -r '.[0]' <<< "$versions")"
fi

[[ "${GITHUB_REF_NAME:-$default_branch}" == "$default_branch" ]] || arcadia_die "release must run from $default_branch"

release_ref="release/$release_artifact_id/v$release_version"
git -C "$root" show-ref --verify --quiet "refs/tags/$release_ref" && arcadia_die "tag already exists: $release_ref"
git -C "$root" ls-remote --exit-code --heads origin "$release_ref" >/dev/null 2>&1 && \
  arcadia_die "release branch already exists: $release_ref"
if command -v gh >/dev/null 2>&1 && gh release view "$release_ref" --repo "${GITHUB_REPOSITORY:-}" >/dev/null 2>&1; then
  arcadia_die "GitHub release already exists: $release_ref"
fi

arcadia_write_output ref "$release_ref"
arcadia_write_output current_version "$current_version"
