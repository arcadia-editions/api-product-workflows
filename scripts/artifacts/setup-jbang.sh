#!/usr/bin/env bash
set -euo pipefail

version="${1:-0.138.0}"
install_dir="${2:-$RUNNER_TEMP/jbang}"
archive="$RUNNER_TEMP/jbang-$version.zip"
checksums="$RUNNER_TEMP/jbang-$version-checksums.txt"
base_url="https://github.com/jbangdev/jbang/releases/download/v$version"

curl --fail --location --silent --show-error "$base_url/jbang-$version.zip" --output "$archive"
curl --fail --location --silent --show-error "$base_url/checksums_sha256.txt" --output "$checksums"
expected="$(awk -v file="jbang-$version.zip" '$2 == file || $2 == "*" file {print $1}' "$checksums")"
[[ -n "$expected" ]] || { echo "checksum for jbang-$version.zip not found" >&2; exit 1; }
printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status
mkdir -p "$install_dir"
unzip -q "$archive" -d "$install_dir"
jbang_bin="$(find "$install_dir" -type f -path '*/bin/jbang' -print -quit)"
[[ -n "$jbang_bin" ]] || { echo "JBang executable not found in release archive" >&2; exit 1; }
chmod +x "$jbang_bin"
printf '%s\n' "$(dirname "$jbang_bin")" >> "$GITHUB_PATH"

