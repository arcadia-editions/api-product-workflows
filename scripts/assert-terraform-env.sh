#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "At least one environment variable name is required" >&2
  exit 1
fi

missing=()

for name in "$@"; do
  if [[ -z "${!name:-}" ]]; then
    missing+=("$name")
  fi
done

if [[ "${#missing[@]}" -gt 0 ]]; then
  printf 'Missing required environment variables: %s\n' "${missing[*]}" >&2
  exit 1
fi
