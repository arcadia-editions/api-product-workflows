#!/bin/bash
set -euo pipefail

ORG="${TF_CLOUD_ORGANIZATION}"
TOKEN="${TF_TOKEN_app_terraform_io}"

page=1
while true; do
  response=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/vnd.api+json" \
    "https://app.terraform.io/api/v2/organizations/$ORG/workspaces?page%5Bnumber%5D=$page&page%5Bsize%5D=100")

  names=$(echo "$response" | jq -r '.data[].attributes.name // empty')
  [[ -z "$names" ]] && break

  for name in $names; do
    echo "Deleting $name"
    curl -s -o /dev/null -w "  -> %{http_code}\n" -X DELETE \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/vnd.api+json" \
      "https://app.terraform.io/api/v2/organizations/$ORG/workspaces/$name"
  done

  next=$(echo "$response" | jq -r '.meta.pagination."next-page" // empty')
  [[ -z "$next" || "$next" == "null" ]] && break
  page=$next
done

echo "Done"