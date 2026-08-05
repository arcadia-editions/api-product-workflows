#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
record="${2:-}"
output_root="${3:-$root/target/artifacts}"
commit="${4:-}"
if [[ -z "$commit" ]]; then
  commit="$(git -C "$root" rev-parse HEAD)" || arcadia_die "cannot resolve source commit"
fi

type="$(jq -r .type <<< "$record")"
relative_path="$(jq -r .path <<< "$record")"
artifact_id="$(jq -r .artifactId <<< "$record")"
group_id="$(jq -r .groupId <<< "$record")"
group_path="$(jq -r .groupPath <<< "$record")"
repository="$(jq -r .repository <<< "$record")"
owner_id="$(jq -r .ownerId <<< "$record")"
arcadia_assert_type "$type"
arcadia_assert_safe_relative_path "$relative_path"

version="$(arcadia_read_version "$type" "$root/$relative_path")"
arcadia_assert_semver "$version"
created_at="$(git -C "$root" show -s --format=%cI "$commit" | xargs -I{} date -u -d '{}' +%Y-%m-%dT%H:%M:%SZ)"
staging="$output_root/staging/$artifact_id"
jar_dir="$output_root/maven/$group_path/$artifact_id/$version"
generic_dir="$output_root/artifactory/$repository/$artifact_id/$version"
jar_file="$jar_dir/$artifact_id-$version.jar"

mkdir -p "$staging/META-INF/arcadia" "$jar_dir" "$generic_dir/.arcadia"
expected='[]'
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  arcadia_assert_safe_relative_path "$path"
  [[ -f "$root/$path" ]] || arcadia_die "mapped source file is missing: $path"
  mkdir -p "$staging/$(dirname "$path")" "$generic_dir/$(dirname "$path")"
  cp "$root/$path" "$staging/$path"
  cp "$root/$path" "$generic_dir/$path"
  expected="$(jq -c --arg path "$path" '. + [$path]' <<< "$expected")"
done < <(arcadia_source_files "$root" "$type" "$relative_path")

jq -n \
  --arg repository "$repository" --arg ownerId "$owner_id" --arg type "$type" \
  --arg groupId "$group_id" --arg artifactId "$artifact_id" --arg version "$version" \
  --arg commit "$commit" --arg createdAt "$created_at" \
  '{repository:$repository,ownerId:$ownerId,type:$type,groupId:$groupId,artifactId:$artifactId,version:$version,commit:$commit,createdAt:$createdAt}' \
  > "$staging/META-INF/arcadia/artifact-metadata.json"
cp "$staging/META-INF/arcadia/artifact-metadata.json" "$generic_dir/.arcadia/artifact-metadata.json"

manifest_file="$output_root/$artifact_id.mf"
printf 'Manifest-Version: 1.0\nCreated-By: Arcadia Editions artifact workflow\n\n' > "$manifest_file"
arcadia_find "$staging" -type f -exec touch -d "$created_at" {} +
jar --create --date="$created_at" --file "$jar_file" --manifest "$manifest_file" -C "$staging" .
checksum="$(sha256sum "$jar_file" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$jar_file")" > "$jar_file.sha256"
(cd "$generic_dir" && arcadia_find . -type f ! -path './.arcadia/checksums.sha256' -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 sha256sum) > "$generic_dir/.arcadia/checksums.sha256"

jq -c \
  --arg jar "$jar_file" --arg checksumFile "$jar_file.sha256" --arg checksum "$checksum" \
  --arg genericTree "$generic_dir" --arg version "$version" --argjson expectedEntries "$expected" \
  '. + {deploymentVersion:$version,jar:$jar,checksumFile:$checksumFile,checksum:$checksum,genericTree:$genericTree,expectedEntries:$expectedEntries}' \
  <<< "$record"
