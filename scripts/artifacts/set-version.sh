#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
type="${2:-}"
relative_path="${3:-}"
version="${4:-}"
arcadia_assert_type "$type"
arcadia_assert_safe_relative_path "$relative_path"
arcadia_assert_semver "$version"
file="$root/$relative_path"

replace_yaml_info_version() {
  ruby - "$file" "$version" <<'RUBY'
file, version = ARGV
lines = File.readlines(file, chomp: true)
info = lines.index { |line| line.match?(/^info:\s*$/) }
abort("info section not found in #{file}") unless info
finish = ((info + 1)...lines.length).find { |index| lines[index].match?(/^\S/) } || lines.length
versions = ((info + 1)...finish).select { |index| lines[index].match?(/^  version:\s*/) }
abort("expected exactly one info.version in #{file}") unless versions.length == 1
lines[versions.first] = "  version: \"#{version}\""
File.write(file, lines.join("\n") + "\n")
RUBY
}

case "$type" in
  zdl|zfl) jbang --quiet "$SCRIPT_DIR/DslTool.java" write-version "$type" "$file" "$version" ;;
  openapi|asyncapi|asyncapi-client) replace_yaml_info_version ;;
esac

[[ "$(arcadia_read_version "$type" "$file")" == "$version" ]] || arcadia_die "version update failed for $relative_path"
