#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
artifact="${2:-}"
release_version="${3:-}"
development_version="${4:-}"
default_branch="${5:-main}"

arcadia_assert_artifact "$artifact"
arcadia_assert_release_version "$release_version"
arcadia_assert_snapshot_version "$development_version"

ruby -e '
  require "rubygems"
  release_version, development_version = ARGV
  release = Gem::Version.new(release_version)
  development = Gem::Version.new(development_version.sub(/-SNAPSHOT\z/, ""))
  abort("development version must be greater than release version") unless development > release
' "$release_version" "$development_version"

[[ "${GITHUB_REF_NAME:-$default_branch}" == "$default_branch" ]] || arcadia_die "release must run from $default_branch"
current="$(arcadia_read_version "$root" "$artifact")"
arcadia_assert_snapshot_version "$current"
current_base="${current%-SNAPSHOT}"
[[ "$current_base" == "$release_version" ]] || arcadia_die "current version $current is not compatible with requested release $release_version"

tag="$artifact/v$release_version"
branch="release/$artifact/$release_version"
git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null && arcadia_die "tag already exists: $tag"
git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 && arcadia_die "release branch already exists: $branch"
if command -v gh >/dev/null 2>&1 && gh release view "$tag" --repo "${GITHUB_REPOSITORY:-}" >/dev/null 2>&1; then
  arcadia_die "GitHub Release already exists: $tag"
fi

arcadia_write_output tag "$tag"
arcadia_write_output branch "$branch"
arcadia_write_output current_version "$current"

