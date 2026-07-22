#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

root="${1:-.}"
artifact="${2:-}"
version="$(arcadia_read_version "$root" "$artifact")"
arcadia_assert_semver "$version"
arcadia_write_output version "$version"
printf '%s\n' "$version"

