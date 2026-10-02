#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
plan="${2:-[]}"
output_root="${3:-$root/target/artifacts}"
version="${4:-}"
commit="${5:-}"
arcadia_assert_release_version "$version"
if [[ -z "$commit" ]]; then
  commit="$(git -C "$root" rev-parse HEAD)" || arcadia_die "cannot resolve source commit"
fi

jq -e '
  type == "array" and length > 0 and
  ([.[].ownerRef] | unique | length) == 1 and
  ([.[].repository] | unique | length) == 1 and
  ([.[].groupId] | unique | length) == 1 and
  ([.[].groupPath] | unique | length) == 1
' <<< "$plan" >/dev/null || arcadia_die "service-all plan must resolve one owner, repository and groupId"

owner_id="$(jq -r '.[0].ownerId' <<< "$plan")"
owner_ref="$(jq -r '.[0].ownerRef' <<< "$plan")"
group_id="$(jq -r '.[0].groupId' <<< "$plan")"
group_path="$(jq -r '.[0].groupPath' <<< "$plan")"
repository="$(jq -r '.[0].repository' <<< "$plan")"
artifact_id="service-all"
created_at="$(git -C "$root" show -s --format=%cI "$commit")"
staging="$output_root/staging/$artifact_id"
jar_dir="$output_root/maven/$group_path/$artifact_id/$version"
generic_dir="$output_root/artifactory/$repository/$artifact_id/$version"
jar_file="$jar_dir/$artifact_id-$version.jar"
members="$(jq -c '[.[] | {type, path, artifactId, groupId, version}]' <<< "$plan")"

mkdir -p "$staging/META-INF/arcadia" "$staging/$group_path" "$jar_dir" "$generic_dir/.arcadia"
expected='[]'
while IFS= read -r -d '' path; do
  arcadia_assert_safe_relative_path "$path"
  [[ -f "$root/$path" && ! -L "$root/$path" ]] || \
    arcadia_die "tracked repository entry is not a regular file: $path"
  jar_path="$group_path/$path"
  mkdir -p "$staging/$(dirname "$jar_path")" "$generic_dir/$(dirname "$path")"
  cp "$root/$path" "$staging/$jar_path"
  cp "$root/$path" "$generic_dir/$path"
  expected="$(jq -c --arg path "$jar_path" '. + [$path]' <<< "$expected")"
done < <(git -C "$root" ls-files -z --cached)

jq -n \
  --arg repository "$repository" --arg ownerId "$owner_id" --arg ownerRef "$owner_ref" \
  --arg type "$artifact_id" --arg groupId "$group_id" --arg artifactId "$artifact_id" \
  --arg version "$version" --arg commit "$commit" --arg createdAt "$created_at" \
  --argjson members "$members" \
  '{repository:$repository,ownerId:$ownerId,ownerRef:$ownerRef,type:$type,groupId:$groupId,artifactId:$artifactId,version:$version,commit:$commit,createdAt:$createdAt,members:$members}' \
  > "$staging/META-INF/arcadia/artifact-metadata.json"
cp "$staging/META-INF/arcadia/artifact-metadata.json" "$generic_dir/.arcadia/artifact-metadata.json"

manifest_file="$output_root/$artifact_id.mf"
printf 'Manifest-Version: 1.0\nCreated-By: Arcadia Editions artifact workflow\n\n' > "$manifest_file"
jar --create --file "$jar_file" --manifest "$manifest_file" -C "$staging" .
checksum="$(sha256sum "$jar_file" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$jar_file")" > "$jar_file.sha256"
(cd "$generic_dir" && arcadia_find . -type f ! -path './.arcadia/checksums.sha256' -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 sha256sum) > "$generic_dir/.arcadia/checksums.sha256"

jq -n \
  --arg repository "$repository" --arg ownerId "$owner_id" --arg ownerRef "$owner_ref" \
  --arg type "$artifact_id" --arg groupId "$group_id" --arg groupPath "$group_path" \
  --arg artifactId "$artifact_id" --arg version "$version" --arg deploymentVersion "$version" \
  --arg commit "$commit" --arg createdAt "$created_at" --arg jar "$jar_file" \
  --arg checksumFile "$jar_file.sha256" --arg checksum "$checksum" --arg genericTree "$generic_dir" \
  --argjson expectedEntries "$expected" --argjson members "$members" \
  '{repository:$repository,ownerId:$ownerId,ownerRef:$ownerRef,type:$type,groupId:$groupId,groupPath:$groupPath,artifactId:$artifactId,version:$version,deploymentVersion:$deploymentVersion,commit:$commit,createdAt:$createdAt,jar:$jar,checksumFile:$checksumFile,checksum:$checksum,genericTree:$genericTree,expectedEntries:$expectedEntries,members:$members}'
