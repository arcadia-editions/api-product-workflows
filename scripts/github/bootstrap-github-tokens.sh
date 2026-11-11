#!/usr/bin/env bash
set -euo pipefail

# Rehydrate every GitHub-token-shaped secret from ONE classic personal access token.
#
# The same PAT value is stored as:
#   org secret   ARCHITECTURE_APP_TOKEN                 (selected *-api repositories)
#   org secret   MAVEN_REPOSITORY_PASSWORD_OR_TOKEN     (all repositories, GitHub Packages)
#   org secret   MAVEN_REPOSITORY_USERNAME              (selected *-api repositories, = token owner)
#   repo secret  EVENT_CATALOG_TOKEN                    (arcadia-editions-architecture)
#   org secret   ARTIFACT_RELEASE_TOKEN                 (only with --release-token)
#
# The token is verified BEFORE anything is written: it must be a classic PAT with the
# required scopes, not expired, with push access to every repository it will serve,
# and able to dispatch to the architecture and catalog repositories.
#
# Secrets are written with the identity of the `gh` CLI (an org admin), which is
# independent of the PAT being stored. The PAT is never printed.

GITHUB_ORG="arcadia-editions"
ARCHITECTURE_REPO="arcadia-editions-architecture"
CATALOG_REPO="arcadia-event-catalog"
WORKFLOWS_REPO="api-product-workflows"
REQUIRED_SCOPES=(repo workflow write:packages)
EXPIRY_WARN_DAYS=7

DRY_RUN=false
RELEASE_TOKEN=false
API_REPOS=""

usage() {
  cat <<'EOF'
Usage: bootstrap-github-tokens.sh [--release-token] [--api-repos a,b,c] [--org org-slug] [--dry-run]

Reads the PAT from $GITHUB_PAT, or prompts for it (hidden) when not set.

Options:
  --release-token    Also store ARTIFACT_RELEASE_TOKEN so release branches and pull requests are
                     created by the PAT instead of github.token (this makes CI run on release PRs).
  --api-repos list   Comma-separated repositories that receive the org secrets that are not
                     visible to everyone. Defaults to every repository in the org ending in -api.
  --org org-slug     GitHub organization. Defaults to arcadia-editions.
  --dry-run          Verify the token and print intended actions; write nothing.
  -h, --help         Show this help.

Create the PAT first: GitHub > Settings > Developer settings > Personal access tokens >
Tokens (classic) > Generate new token (classic), scopes: repo, workflow, write:packages.
EOF
}

log() { printf '[bootstrap-github-tokens] %s\n' "$*" >&2; }
die() { printf '[bootstrap-github-tokens] ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required tool not found on PATH: $1"; }

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --release-token) RELEASE_TOKEN=true; shift ;;
    --api-repos) [[ -n "${2:-}" ]] || die "--api-repos requires a list"; API_REPOS="$2"; shift 2 ;;
    --org) [[ -n "${2:-}" ]] || die "--org requires a slug"; GITHUB_ORG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd gh
need_cmd jq
need_cmd curl
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"

PAT="${GITHUB_PAT:-}"
if [[ -z "$PAT" ]]; then
  [[ -t 0 ]] || die "Set GITHUB_PAT or run interactively to be prompted for the token"
  read -rsp "Classic PAT (input hidden): " PAT
  printf '\n' >&2
fi
[[ -n "$PAT" ]] || die "Empty token"

with_pat() { GH_TOKEN="$PAT" "$@"; }

# --- 1. Verify the token itself -------------------------------------------------------
log "Verifying the token"
headers="$(curl -sS -D - -o /tmp/bgt-user.$$ -H "Authorization: Bearer $PAT" https://api.github.com/user)"
trap 'rm -f /tmp/bgt-user.$$' EXIT
status="$(printf '%s' "$headers" | head -n 1 | awk '{print $2}')"
[[ "$status" == "200" ]] || die "Token rejected by GitHub (HTTP $status): expired, revoked or mistyped"
login="$(jq -r .login /tmp/bgt-user.$$)"
scopes="$(printf '%s' "$headers" | { grep -i '^x-oauth-scopes:' || true; } | cut -d: -f2- | tr -d ' \r')"
expires="$(printf '%s' "$headers" | { grep -i '^github-authentication-token-expiration:' || true; } | cut -d: -f2- | sed 's/^ *//; s/\r//')"

[[ -n "$scopes" ]] || die "Token has no OAuth scopes: use a classic PAT (fine-grained tokens cannot publish to GitHub Packages)"
missing=()
for scope in "${REQUIRED_SCOPES[@]}"; do
  grep -qE "(^|,)$scope(,|$)" <<< "$scopes" || missing+=("$scope")
done
(( ${#missing[@]} == 0 )) || die "Token is missing scopes: ${missing[*]} (has: $scopes)"
log "Token belongs to '$login' with scopes: $scopes"

if [[ -n "$expires" ]]; then
  expires_epoch="$(date -d "$expires" +%s 2>/dev/null || true)"
  if [[ -n "$expires_epoch" ]]; then
    days_left=$(( (expires_epoch - $(date +%s)) / 86400 ))
    (( days_left >= 0 )) || die "Token expired on $expires"
    log "Token expires: $expires ($days_left days left)"
    (( days_left >= EXPIRY_WARN_DAYS )) || log "WARNING: token expires in under $EXPIRY_WARN_DAYS days; consider a longer-lived one for the demo"
  fi
else
  log "Token has no expiration date"
fi

# --- 2. Verify it can do what the pipeline does with it ---------------------------------
if [[ -z "$API_REPOS" ]]; then
  API_REPOS="$(gh repo list "$GITHUB_ORG" --limit 200 --json name -q '.[].name | select(endswith("-api"))' | paste -sd, -)"
fi
[[ -n "$API_REPOS" ]] || die "No *-api repositories found in $GITHUB_ORG"
IFS=',' read -ra api_repo_list <<< "$API_REPOS"

fail=0
for repo in "${api_repo_list[@]}" "$ARCHITECTURE_REPO" "$CATALOG_REPO"; do
  if [[ "$(with_pat gh api "repos/$GITHUB_ORG/$repo" -q .permissions.push 2>/dev/null || true)" != "true" ]]; then
    log "ERROR: token cannot push to $GITHUB_ORG/$repo"; fail=1
  fi
done
# Dry run: an event type no workflow listens to. 204 proves the token can dispatch.
for repo in "$ARCHITECTURE_REPO" "$CATALOG_REPO"; do
  if ! with_pat gh api "repos/$GITHUB_ORG/$repo/dispatches" -f event_type=preflight >/dev/null 2>&1; then
    log "ERROR: token cannot dispatch events to $GITHUB_ORG/$repo"; fail=1
  fi
done
(( fail == 0 )) || die "Token verification failed; nothing was written"
log "Token can push to ${#api_repo_list[@]} API repositories plus architecture and catalog, and can dispatch to both"

# --- 3. Store it ------------------------------------------------------------------------
set_secret() {
  local name="$1"; shift
  if [[ "$DRY_RUN" == true ]]; then log "DRY RUN: would set secret $name ($*)"; return; fi
  printf '%s' "$VALUE" | gh secret set "$name" "$@" >/dev/null
  log "Set secret $name"
}

VALUE="$PAT"
set_secret ARCHITECTURE_APP_TOKEN --org "$GITHUB_ORG" --visibility selected --repos "$API_REPOS"
set_secret MAVEN_REPOSITORY_PASSWORD_OR_TOKEN --org "$GITHUB_ORG" --visibility all
set_secret EVENT_CATALOG_TOKEN --repo "$GITHUB_ORG/$ARCHITECTURE_REPO"
if [[ "$RELEASE_TOKEN" == true ]]; then
  set_secret ARTIFACT_RELEASE_TOKEN --org "$GITHUB_ORG" --visibility selected --repos "$API_REPOS"
fi
VALUE="$login"
set_secret MAVEN_REPOSITORY_USERNAME --org "$GITHUB_ORG" --visibility selected --repos "$API_REPOS"

log "Done. Next: re-run any failed workflow; the next release runs a preflight that re-checks these tokens."
