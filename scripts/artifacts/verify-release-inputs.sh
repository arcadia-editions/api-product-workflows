#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
record="${2:-}"
release_version="${3:-}"
next_version="${4:-}"
default_branch="${5:-main}"
artifact_id="$(jq -r .artifactId <<< "$record")"
type="$(jq -r .type <<< "$record")"
path="$(jq -r .path <<< "$record")"

arcadia_assert_type "$type"
arcadia_assert_safe_relative_path "$path"
arcadia_assert_release_version "$release_version"
arcadia_assert_semver "$next_version"
[[ "$artifact_id" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || arcadia_die "unsafe artifactId: $artifact_id"

ruby -e '
  require "rubygems"
  release_version, next_version = ARGV
  release = Gem::Version.new(release_version)
  following = Gem::Version.new(next_version)
  abort("nextVersion must be greater than version") unless following > release
' "$release_version" "$next_version"

[[ "${GITHUB_REF_NAME:-$default_branch}" == "$default_branch" ]] || arcadia_die "release must run from $default_branch"
current="$(arcadia_read_version "$type" "$root/$path")"
arcadia_assert_semver "$current"

release_ref="release/$artifact_id/v$release_version"
git -C "$root" show-ref --verify --quiet "refs/tags/$release_ref" && arcadia_die "tag already exists: $release_ref"
git -C "$root" ls-remote --exit-code --heads origin "$release_ref" >/dev/null 2>&1 && arcadia_die "release branch already exists: $release_ref"
if command -v gh >/dev/null 2>&1 && gh release view "$release_ref" --repo "${GITHUB_REPOSITORY:-}" >/dev/null 2>&1; then
  arcadia_die "GitHub release already exists: $release_ref"
fi

arcadia_write_output ref "$release_ref"
arcadia_write_output current_version "$current"
