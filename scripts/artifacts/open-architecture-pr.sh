#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
target_repository="${2:-}"
service_repository="${3:-}"
artifact="${4:-}"
version="${5:-}"
source_tag="${6:-}"
release_url="${7:-}"
packages="${8:-[]}"
manifest_path="${9:-zenwave-architecture.yml}"

arcadia_assert_artifact "$artifact"
arcadia_assert_release_version "$version"
[[ -n "${ARCHITECTURE_TOKEN:-}" ]] || arcadia_die "ARCHITECTURE_TOKEN is required"
arcadia_require_command gh

export GH_TOKEN="$ARCHITECTURE_TOKEN"
branch="automation/$service_repository/$artifact/$version"
existing_url="$(gh pr list --repo "$target_repository" --head "$branch" --state open --json url --jq '.[0].url // empty')"
if [[ -n "$existing_url" ]]; then
  arcadia_write_output pr_url "$existing_url"
  printf '%s\n' "$existing_url"
  exit 0
fi

if git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  arcadia_die "stale architecture branch exists without an open PR: $branch"
fi

git -C "$root" config user.name 'arcadia-editions-architecture[bot]'
git -C "$root" config user.email 'arcadia-editions-architecture[bot]@users.noreply.github.com'
git -C "$root" switch -c "$branch"
arcadia_assert_safe_relative_path "$manifest_path"
git -C "$root" add "$manifest_path"
git -C "$root" commit -m "Update $service_repository $artifact to $version"
gh auth setup-git
git -C "$root" push --set-upstream origin "$branch"

body="$root/.git/architecture-pr-body.md"
{
  printf 'Synchronizes released artifact metadata.\n\n'
  printf -- '- Source tag: `%s`\n' "$source_tag"
  printf -- '- GitHub Release: %s\n' "$release_url"
  while IFS= read -r record; do
    printf -- '- Maven: `%s:%s:%s` — SHA-256 `%s`\n' \
      "$(jq -r .coordinates.groupId <<< "$record")" \
      "$(jq -r .coordinates.artifactId <<< "$record")" \
      "$(jq -r .coordinates.deploymentVersion <<< "$record")" \
      "$(jq -r .checksum <<< "$record")"
  done < <(jq -c '.[]' <<< "$packages")
  if [[ "$artifact" == "openapi" || "$artifact" == "asyncapi" ]]; then
    printf -- '- Apicurio version: `%s`\n' "$version"
  fi
} > "$body"

pr_url="$(gh pr create --repo "$target_repository" --base main --head "$branch" \
  --title "Release metadata: $service_repository $artifact $version" --body-file "$body")"
arcadia_write_output pr_url "$pr_url"
printf '%s\n' "$pr_url"
