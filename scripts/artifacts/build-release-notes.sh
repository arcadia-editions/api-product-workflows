#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
artifact="${2:-}"
version="${3:-}"
packages="${4:-[]}"
output="${5:-$root/target/release-notes.md}"
manifest_pr_url="${6:-}"

arcadia_assert_artifact "$artifact"
arcadia_assert_release_version "$version"
notes_file="$root/release-notes/$artifact/release-notes.v$version.md"
mkdir -p "$(dirname "$output")"

if [[ -e "$notes_file" ]]; then
  [[ ! -L "$notes_file" ]] || arcadia_die "release notes must not be a symlink: $notes_file"
  [[ -s "$notes_file" ]] || arcadia_die "release notes are empty: $notes_file"
  if ! grep -Fq "$version" "$notes_file"; then
    echo "warning: release notes do not mention $version" >&2
  fi
  cp "$notes_file" "$output"
else
  previous_tag="$(git -C "$root" tag --list "$artifact/v*" --sort=-v:refname | grep -Fxv "$artifact/v$version" | head -n 1 || true)"
  range="HEAD"
  [[ -z "$previous_tag" ]] || range="$previous_tag..HEAD"
  {
    printf '# %s v%s\n\n' "$artifact" "$version"
    printf 'Changes affecting the %s artifact family:\n\n' "$artifact"
    mapfile -t paths < <(arcadia_source_files "$root" "$artifact")
    git -C "$root" log "$range" --pretty='- %s (%h)' -- "${paths[@]}" || true
  } > "$output"
fi

commit="$(git -C "$root" rev-parse HEAD)"
{
  printf '\n## Provenance\n\n'
  printf -- '- Artifact family: `%s`\n' "$artifact"
  printf -- '- Version: `%s`\n' "$version"
  printf -- '- Source commit: `%s`\n' "$commit"
  while IFS= read -r record; do
    printf -- '- Maven: `%s:%s:%s` — SHA-256 `%s`\n' \
      "$(jq -r .coordinates.groupId <<< "$record")" \
      "$(jq -r .coordinates.artifactId <<< "$record")" \
      "$(jq -r .coordinates.deploymentVersion <<< "$record")" \
      "$(jq -r .checksum <<< "$record")"
  done < <(jq -c '.[]' <<< "$packages")
  [[ -z "${MAVEN_REPOSITORY_URL:-}" ]] || printf -- '- Maven repository: %s\n' "$MAVEN_REPOSITORY_URL"
  [[ -z "${ARTIFACTORY_GENERIC_RELEASE_REPOSITORY:-}" ]] || printf -- '- Generic repository: %s\n' "$ARTIFACTORY_GENERIC_RELEASE_REPOSITORY"
  if [[ "$artifact" == "openapi" || "$artifact" == "asyncapi" ]] && [[ -n "${APICURIO_REGISTRY_URL:-}" ]]; then
    printf -- '- Apicurio group: `%s`\n' "$(jq -r '.[0].coordinates.serviceId' <<< "$packages")"
  fi
  [[ -z "$manifest_pr_url" ]] || printf -- '- Architecture manifest PR: %s\n' "$manifest_pr_url"
} >> "$output"

arcadia_write_output notes_file "$output"
