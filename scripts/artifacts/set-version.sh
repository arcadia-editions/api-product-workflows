#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
artifact="${2:-}"
version="${3:-}"
arcadia_assert_artifact "$artifact"
arcadia_assert_semver "$version"

replace_yaml_version() {
  local file="$1" section="$2"
  ruby - "$file" "$section" "$version" <<'RUBY'
file, section, version = ARGV
lines = File.readlines(file, chomp: true)
in_section = section == "root"
section_indent = nil
changed = false
lines.map! do |line|
  if section != "root" && line.match?(/^#{Regexp.escape(section)}:\s*$/)
    in_section = true
    section_indent = 0
    next line
  end
  if in_section && section != "root" && line.match?(/^\S/) && !line.match?(/^#{Regexp.escape(section)}:/)
    in_section = false
  end
  pattern = section == "root" ? /^version:\s*.*$/ : /^  version:\s*.*$/
  if in_section && !changed && line.match?(pattern)
    changed = true
    section == "root" ? "version: \"#{version}\"" : "  version: \"#{version}\""
  else
    line
  end
end
abort("version field not found in #{file}") unless changed
File.write(file, lines.join("\n") + "\n")
RUBY
}

case "$artifact" in
  zdl)
    mkdir -p "$root/.arcadia/versions"
    printf '%s\n' "$version" > "$root/.arcadia/versions/zdl.version"
    ;;
  openapi) replace_yaml_version "$root/openapi.yml" info ;;
  asyncapi)
    replace_yaml_version "$root/asyncapi.yml" info
    [[ ! -f "$root/asyncapi-client.yml" ]] || replace_yaml_version "$root/asyncapi-client.yml" info
    ;;
  api-product) replace_yaml_version "$root/.arcadia/api-product.yml" root ;;
esac

