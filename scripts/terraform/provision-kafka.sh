#!/usr/bin/env bash
set -euo pipefail

# Generate Terraform from one or more service AsyncAPI files (owned and/or
# client contracts) and the shared pipeline overlays. Multiple generator runs
# write into the same target folder so a single Terraform apply provisions
# both owned topics/schemas and consumer ACLs/consumer groups together.

SERVICE_REPO_PATH="${1:?service repo path is required}"
PIPELINE_REPO_PATH="${2:?pipeline repo path is required}"
ASYNCAPI_FILES="${3:?comma-separated asyncapi file path(s) is required}"
SERVER="${4:?server is required}"
SERVICE_REPO_NAME="${5:-$(basename "$(cd "$SERVICE_REPO_PATH" && pwd)")}"
AVRO_IMPORTS_VALUE="${AVRO_IMPORTS:-}"
TF_CLOUD_ORGANIZATION_VALUE="${TF_CLOUD_ORGANIZATION:-}"
TF_WORKSPACE_VALUE="${PIPELINE_TF_WORKSPACE:-}"

copy_overlay_folder() {
  local source_path="$1"
  local destination_path="$2"

  if [[ ! -d "$source_path" ]]; then
    return
  fi

  mkdir -p "$destination_path"
  cp -R "$source_path"/. "$destination_path"/
}

render_cloud_config() {
  local template_path="$1"
  local output_path="$2"

  if [[ ! -f "$template_path" ]]; then
    return
  fi

  # A combined release bundle is built once and later applied to more than one
  # Terraform workspace (pre, then prod). When the target workspace isn't known
  # yet, leave cloud.tftpl in place for the promotion step to render instead of
  # failing here.
  if [[ -z "$TF_CLOUD_ORGANIZATION_VALUE" || -z "$TF_WORKSPACE_VALUE" ]]; then
    echo "TF_CLOUD_ORGANIZATION/PIPELINE_TF_WORKSPACE not set; leaving cloud.tftpl unrendered" >&2
    return
  fi

  sed \
    -e "s|__TF_CLOUD_ORGANIZATION__|${TF_CLOUD_ORGANIZATION_VALUE}|g" \
    -e "s|__TF_WORKSPACE__|${TF_WORKSPACE_VALUE}|g" \
    "$template_path" > "$output_path"
  rm -f "$template_path"
}

resolved_service_repo_path="$(cd "$SERVICE_REPO_PATH" && pwd)"
resolved_pipeline_repo_path="$(cd "$PIPELINE_REPO_PATH" && pwd)"
resolved_target_folder="${resolved_service_repo_path}/target/terraform"
service_repo_name="$SERVICE_REPO_NAME"

IFS=',' read -r -a asyncapi_file_paths <<< "$ASYNCAPI_FILES"
if [[ "${#asyncapi_file_paths[@]}" -eq 0 ]]; then
  echo "At least one AsyncAPI file is required" >&2
  exit 1
fi

resolve_asyncapi_file() {
  local asyncapi_file="$1"
  if [[ "$asyncapi_file" = /* || "$asyncapi_file" =~ ^[A-Za-z]:[\\/] ]]; then
    printf '%s' "$asyncapi_file"
  else
    printf '%s' "${resolved_service_repo_path}/${asyncapi_file}"
  fi
}

resolved_asyncapi_files=()
for asyncapi_file in "${asyncapi_file_paths[@]}"; do
  resolved_asyncapi_file="$(resolve_asyncapi_file "$asyncapi_file")"
  if [[ ! -f "$resolved_asyncapi_file" ]]; then
    echo "AsyncAPI file not found: $resolved_asyncapi_file" >&2
    exit 1
  fi
  resolved_asyncapi_files+=("$resolved_asyncapi_file")
done

rm -rf "$resolved_target_folder"
mkdir -p "$resolved_target_folder"

api_files_joined="$(IFS=','; echo "${resolved_asyncapi_files[*]}")"

generator_args=(
  "apiFiles=$api_files_joined"
  "templates=TerraformConfluent"
  "serviceAccountMode=managed"
  "server=$SERVER"
  "targetFolder=$resolved_target_folder"
)

if [[ -n "$AVRO_IMPORTS_VALUE" ]]; then
  IFS=',' read -r -a avro_import_paths <<< "$AVRO_IMPORTS_VALUE"
  for avro_import_path in "${avro_import_paths[@]}"; do
    if [[ "$avro_import_path" = /* || "$avro_import_path" =~ ^[A-Za-z]:[\\/] ]]; then
      resolved_avro_import_path="$avro_import_path"
    else
      resolved_avro_import_path="${resolved_service_repo_path}/${avro_import_path}"
    fi

    generator_args+=("avroImports=$resolved_avro_import_path")
  done
fi

(
  cd "$resolved_pipeline_repo_path"
  jbang zw -p AsyncAPIOpsGeneratorPlugin "${generator_args[@]}"
)

copy_overlay_folder "${resolved_pipeline_repo_path}/terraform/common" "$resolved_target_folder"
copy_overlay_folder "${resolved_pipeline_repo_path}/terraform/services/${service_repo_name}" "$resolved_target_folder"
render_cloud_config \
  "${resolved_target_folder}/cloud.tftpl" \
  "${resolved_target_folder}/cloud.tf"

echo "Terraform generated in $resolved_target_folder from ${#asyncapi_file_paths[@]} AsyncAPI file(s)"
