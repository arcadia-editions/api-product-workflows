#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# One OpenLint invocation lints every given OpenAPI or AsyncAPI document.
# The CLI version comes from tools/package.json. The rules bundle is downloaded
# and checked against OPENLINT_BUNDLE_SHA256 before it is used.

if [[ $# -lt 1 ]]; then
  arcadia_die "at least one document path is required"
fi

url="${OPENLINT_BUNDLE_URL:?OPENLINT_BUNDLE_URL is required}"
expected="${OPENLINT_BUNDLE_SHA256:?OPENLINT_BUNDLE_SHA256 is required}"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || arcadia_die "OPENLINT_BUNDLE_SHA256 must be 64 hex characters"

openlint="$(arcadia_locked_cli openlint)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL "$url" -o "$work/openlint.js"
(
  cd "$work"
  printf '%s  openlint.js\n' "$expected" | sha256sum -c -
)

"$openlint" lint --fail-severity=error -r "$work/openlint.js" "$@"
