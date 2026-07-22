#!/usr/bin/env bash
set -euo pipefail

SERVICE_REPO_PATH="${1:?service repo path is required}"
PIPELINE_REPO_PATH="${2:?pipeline repo path is required}"
ASYNCAPI_FILE="${3:?asyncapi file path is required}"
SERVER="${4:?server is required}"
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

  if [[ -z "$TF_CLOUD_ORGANIZATION_VALUE" ]]; then
    echo "TF_CLOUD_ORGANIZATION is required to render cloud.tf" >&2
    exit 1
  fi

  if [[ -z "$TF_WORKSPACE_VALUE" ]]; then
    echo "PIPELINE_TF_WORKSPACE is required to render cloud.tf" >&2
    exit 1
  fi

  sed \
    -e "s|__TF_CLOUD_ORGANIZATION__|${TF_CLOUD_ORGANIZATION_VALUE}|g" \
    -e "s|__TF_WORKSPACE__|${TF_WORKSPACE_VALUE}|g" \
    "$template_path" > "$output_path"
}

resolved_service_repo_path="$(cd "$SERVICE_REPO_PATH" && pwd)"
resolved_pipeline_repo_path="$(cd "$PIPELINE_REPO_PATH" && pwd)"
resolved_asyncapi_file="${resolved_service_repo_path}/${ASYNCAPI_FILE}"
resolved_target_folder="${resolved_service_repo_path}/target/terraform"
service_repo_name="$(basename "$resolved_service_repo_path")"
generator_args=(
  "apiFile=$resolved_asyncapi_file"
  "templates=TerraformConfluent"
  "serviceAccountMode=managed"
  "server=$SERVER"
  "targetFolder=$resolved_target_folder"
)

if [[ ! -f "$resolved_asyncapi_file" ]]; then
  echo "AsyncAPI file not found: $resolved_asyncapi_file" >&2
  exit 1
fi

rm -rf "$resolved_target_folder"
mkdir -p "$resolved_target_folder"

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
rm -f "${resolved_target_folder}/cloud.tftpl"

echo "Terraform generated in $resolved_target_folder"
