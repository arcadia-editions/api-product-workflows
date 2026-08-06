#!/usr/bin/env bash
set -euo pipefail

# Generate Terraform from one or more service AsyncAPI files (owned and/or
# client contracts) and the shared pipeline overlays. Multiple generator runs
# write into the same target folder so a single Terraform apply provisions
# both owned topics/schemas and consumer ACLs/consumer groups together.
#
# Run this script from the folder that ASYNCAPI_FILES/AVRO_IMPORTS are
# relative to: a single service repo checkout, or the primary checkout when
# combining files from more than one (reach into sibling checkouts with ../).

PIPELINE_REPO_PATH="${1:?pipeline repo path is required}"
ASYNCAPI_FILES="${2:?comma-separated asyncapi file path(s) is required}"
SERVER="${3:?server is required}"
SERVICE_REPO_NAME="${4:-$(basename "$(pwd)")}"
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

resolved_service_repo_path="$(pwd)"
resolved_pipeline_repo_path="$(cd "$PIPELINE_REPO_PATH" && pwd)"
resolved_target_folder="${resolved_service_repo_path}/target/terraform"
service_repo_name="$SERVICE_REPO_NAME"

IFS=',' read -r -a asyncapi_file_paths <<< "$ASYNCAPI_FILES"
if [[ "${#asyncapi_file_paths[@]}" -eq 0 ]]; then
  echo "At least one AsyncAPI file is required" >&2
  exit 1
fi

for asyncapi_file in "${asyncapi_file_paths[@]}"; do
  if [[ ! -f "$asyncapi_file" ]]; then
    echo "AsyncAPI file not found: $asyncapi_file (relative to $resolved_service_repo_path)" >&2
    exit 1
  fi
done

rm -rf "$resolved_target_folder"
mkdir -p "$resolved_target_folder"

generator_args=(
  "apiFiles=$ASYNCAPI_FILES"
  "templates=TerraformConfluent"
  "serviceAccountMode=managed"
  "server=$SERVER"
  "targetFolder=target/terraform"
)

if [[ -n "$AVRO_IMPORTS_VALUE" ]]; then
  IFS=',' read -r -a avro_import_paths <<< "$AVRO_IMPORTS_VALUE"
  for avro_import_path in "${avro_import_paths[@]}"; do
    generator_args+=("avroImports=$avro_import_path")
  done
fi

jbang zw -p AsyncAPIOpsGeneratorPlugin "${generator_args[@]}"

copy_overlay_folder "${resolved_pipeline_repo_path}/terraform/common" "$resolved_target_folder"
copy_overlay_folder "${resolved_pipeline_repo_path}/terraform/services/${service_repo_name}" "$resolved_target_folder"
render_cloud_config \
  "${resolved_target_folder}/cloud.tftpl" \
  "${resolved_target_folder}/cloud.tf"

echo "Terraform generated in $resolved_target_folder from ${#asyncapi_file_paths[@]} AsyncAPI file(s)"
