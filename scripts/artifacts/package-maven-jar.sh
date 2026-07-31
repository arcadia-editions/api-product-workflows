#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
manifest="${2:-}"
service_repository="${3:-}"
family="${4:-}"
output_root="${5:-$root/target/artifacts}"
commit="${6:-$(git -C "$root" rev-parse HEAD)}"
channel="${7:-ci}"

arcadia_assert_artifact "$family"
arcadia_require_command jq
arcadia_require_command jar
arcadia_require_command sha256sum

version="$(arcadia_read_version "$root" "$family")"
arcadia_assert_semver "$version"
commit_time="$(git -C "$root" show -s --format=%cI "$commit")"
created_at="$(date -u -d "$commit_time" +%Y-%m-%dT%H:%M:%SZ)"
tag=""
[[ "$channel" != "release" ]] || tag="$family/v$version"
records='[]'
generic_family_dir="$output_root/generic/$service_repository/$family/$version"
if [[ -d "$generic_family_dir" ]]; then
  rm -rf -- "$generic_family_dir"
fi

for package_unit in $(arcadia_package_units "$family"); do
  if [[ "$package_unit" == "asyncapi-client" && ! -f "$root/asyncapi-client.yml" ]]; then
    continue
  fi
  if ! coordinates="$($SCRIPT_DIR/resolve-manifest-coordinates.sh "$manifest" "$service_repository" "$package_unit" "$version")"; then
    if [[ "$package_unit" == "asyncapi-client" ]]; then
      continue
    fi
    exit 1
  fi
  group_path="$(jq -r .groupPath <<< "$coordinates")"
  artifact_id="$(jq -r .artifactId <<< "$coordinates")"
  service_id="$(jq -r .serviceId <<< "$coordinates")"
  content_path="$(jq -r .contentPath <<< "$coordinates")"
  staging="$output_root/staging/$package_unit"
  jar_dir="$output_root/maven-layout/$group_path/$artifact_id/$version"
  generic_dir="$output_root/generic/$service_repository/$family/$version"
  jar_file="$jar_dir/$artifact_id-$version.jar"
  if [[ -d "$staging" ]]; then
    rm -rf -- "$staging"
  fi
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
  done < <(arcadia_package_unit_source_files "$root" "$package_unit")

  jq -n \
    --arg repository "$service_repository" \
    --arg serviceId "$service_id" \
    --arg packageType "$package_unit" \
    --arg groupId "$(jq -r .groupId <<< "$coordinates")" \
    --arg groupPath "$group_path" \
    --arg artifactId "$artifact_id" \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg commit "$commit" \
    --arg createdAt "$created_at" \
    '{repository:$repository,serviceId:$serviceId,packageType:$packageType,groupId:$groupId,groupPath:$groupPath,artifactId:$artifactId,version:$version,tag:$tag,commit:$commit,createdAt:$createdAt}' \
    > "$staging/META-INF/arcadia/artifact-metadata.json"

  if [[ "$family" == "api-product" ]]; then
    asyncapi_client_version=""
    [[ ! -f "$root/asyncapi-client.yml" ]] || asyncapi_client_version="$(arcadia_read_version "$root" asyncapi)"
    components="$(jq -n \
      --arg zdl "$(arcadia_read_version "$root" zdl)" \
      --arg openapi "$(arcadia_read_version "$root" openapi)" \
      --arg asyncapi "$(arcadia_read_version "$root" asyncapi)" \
      --arg asyncapiClient "$asyncapi_client_version" \
      '{zdl:$zdl,openapi:$openapi,asyncapi:$asyncapi} +
        if $asyncapiClient == "" then {} else {"asyncapi-client":$asyncapiClient} end')"
    metadata_tmp="$staging/META-INF/arcadia/artifact-metadata.tmp.json"
    jq --argjson components "$components" '. + {components:$components}' "$staging/META-INF/arcadia/artifact-metadata.json" > "$metadata_tmp"
    mv "$metadata_tmp" "$staging/META-INF/arcadia/artifact-metadata.json"
  fi

  if [[ "$package_unit" == "$family" || "$family:$package_unit" == "api-product:service" ]]; then
    cp "$staging/META-INF/arcadia/artifact-metadata.json" "$generic_dir/.arcadia/artifact-metadata.json"
  fi
  manifest_file="$output_root/package-manifest-$package_unit.mf"
  printf 'Manifest-Version: 1.0\nCreated-By: Arcadia Editions artifact workflow\n\n' > "$manifest_file"
  find "$staging" -type f -exec touch -d "$created_at" {} +
  jar --create --date="$created_at" --file "$jar_file" --manifest "$manifest_file" -C "$staging" .
  mapfile -t actual_entries < <(jar --list --file "$jar_file" | sed '/\/$/d' | sort)
  mapfile -t required_entries < <({ jq -r '.[]' <<< "$expected"; printf '%s\n' META-INF/MANIFEST.MF META-INF/arcadia/artifact-metadata.json; } | sort)
  [[ "${#actual_entries[@]}" -eq "${#required_entries[@]}" ]] || \
    arcadia_die "JAR entry count differs from the closed mapping for $package_unit"
  for index in "${!required_entries[@]}"; do
    [[ "${actual_entries[$index]}" == "${required_entries[$index]}" ]] || \
      arcadia_die "JAR entry mismatch for $package_unit: expected '${required_entries[$index]}', found '${actual_entries[$index]}'"
  done
  checksum="$(sha256sum "$jar_file" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$(basename "$jar_file")" > "$jar_file.sha256"
  (cd "$generic_dir" && find . -type f ! -path './.arcadia/checksums.sha256' -print0 | sort -z | xargs -0 sha256sum) > "$generic_dir/.arcadia/checksums.sha256"
  [[ -f "$staging/$content_path" ]] || arcadia_die "required content path is absent from package: $content_path"

  record="$(jq -c \
    --arg family "$family" \
    --arg packageUnit "$package_unit" \
    --arg jar "$jar_file" \
    --arg checksumFile "$jar_file.sha256" \
    --arg checksum "$checksum" \
    --arg genericTree "$generic_dir" \
    --argjson coordinates "$coordinates" \
    --argjson expectedEntries "$expected" \
    -n '{family:$family,packageUnit:$packageUnit,jar:$jar,checksumFile:$checksumFile,checksum:$checksum,genericTree:$genericTree,coordinates:$coordinates,expectedEntries:$expectedEntries}')"
  records="$(jq -c --argjson record "$record" '. + [$record]' <<< "$records")"
done

printf '%s\n' "$records"
