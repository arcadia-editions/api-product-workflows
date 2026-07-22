#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
pipeline_root="${2:-}"
artifact="${3:-}"
arcadia_assert_artifact "$artifact"
arcadia_require_command ruby

parse_yaml() {
  ruby -e 'require "yaml"; YAML.safe_load_file(ARGV.fetch(0), aliases: true)' "$1"
}

validate_spectral() {
  local file="$1" ruleset="$pipeline_root/spectral/dist/spectral.js"
  [[ -s "$ruleset" ]] || arcadia_die "pinned Spectral bundle is missing: $ruleset"
  arcadia_require_command npx
  npx --yes "@stoplight/spectral-cli@$ARCADIA_SPECTRAL_CLI_VERSION" lint --fail-severity=error -r "$ruleset" "$file"
}

validate_avro_inventory() {
  local avro
  while IFS= read -r avro; do
    [[ -n "$avro" ]] || continue
    ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$root/$avro"
  done < <(git -C "$root" ls-files -- '*.avsc' '**/*.avsc')
}

validate_local_avro_refs() {
  ruby -ryaml -ruri -e '
    root, file = ARGV
    document = YAML.safe_load_file(File.join(root, file), aliases: true)
    walk = lambda do |value|
      case value
      when Hash
        value.each do |key, child|
          if key.to_s == "\$ref" && child.is_a?(String) && child.split("#", 2).first.end_with?(".avsc")
            relative = URI.decode_www_form_component(child.split("#", 2).first)
            candidate = File.expand_path(relative, File.dirname(File.join(root, file)))
            root_path = File.expand_path(root) + File::SEPARATOR
            abort("unsafe Avro reference #{child} in #{file}") unless candidate.start_with?(root_path)
            abort("missing Avro reference #{child} in #{file}") unless File.file?(candidate)
          end
          walk.call(child)
        end
      when Array
        value.each { |child| walk.call(child) }
      end
    end
    walk.call(document)
  ' "$root" "$1"
}

version="$(arcadia_read_version "$root" "$artifact")"
arcadia_assert_semver "$version"

case "$artifact" in
  zdl)
    [[ -s "$root/domain-model.zdl" ]] || arcadia_die "domain-model.zdl is missing or empty"
    arcadia_die "ZDL semantic validation requires a pinned standalone validator; none is configured"
    ;;
  openapi)
    parse_yaml "$root/openapi.yml"
    validate_spectral "$root/openapi.yml"
    ;;
  asyncapi)
    parse_yaml "$root/asyncapi.yml"
    validate_spectral "$root/asyncapi.yml"
    validate_local_avro_refs asyncapi.yml
    if [[ -f "$root/asyncapi-client.yml" ]]; then
      parse_yaml "$root/asyncapi-client.yml"
      validate_spectral "$root/asyncapi-client.yml"
      validate_local_avro_refs asyncapi-client.yml
      client_version="$(arcadia_yaml_info_version "$root/asyncapi-client.yml")"
      [[ "$client_version" == "$version" ]] || arcadia_die "asyncapi-client.yml info.version ($client_version) must equal asyncapi.yml info.version ($version)"
    fi
    validate_avro_inventory
    ;;
  api-product)
    for required in .arcadia/api-product.yml .arcadia/versions/zdl.version domain-model.zdl openapi.yml asyncapi.yml README.md SUMMARY.md CHANGELOG.md; do
      [[ -s "$root/$required" ]] || arcadia_die "required API-product file is missing or empty: $required"
    done
    for component in zdl openapi asyncapi api-product; do
      component_version="$(arcadia_read_version "$root" "$component")"
      arcadia_assert_semver "$component_version"
    done
    ;;
esac

printf '%s %s validated\n' "$artifact" "$version"
