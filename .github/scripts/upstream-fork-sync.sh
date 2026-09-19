#!/usr/bin/env bash
# Upstream fork/mirror sync — opens a reviewable PR; never merges to main.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?UPSTREAM_REPO is required}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
LABEL="${LABEL:-upstream-sync}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }
need git
need gh

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi

git fetch --quiet origin "$DEFAULT_BRANCH"
git fetch --quiet upstream "$UPSTREAM_BRANCH"

LOCAL_SHA="$(git rev-parse "origin/${DEFAULT_BRANCH}")"
UPSTREAM_SHA="$(git rev-parse "upstream/${UPSTREAM_BRANCH}")"
AHEAD_COUNT="$(git rev-list --count "origin/${DEFAULT_BRANCH}..upstream/${UPSTREAM_BRANCH}")"

if [[ "$AHEAD_COUNT" -eq 0 ]]; then
  log "Already up to date with ${UPSTREAM_REPO}@${UPSTREAM_BRANCH} (${UPSTREAM_SHA:0:8}). origin/${DEFAULT_BRANCH}=${LOCAL_SHA:0:8}"
  exit 0
fi

SHA8="${UPSTREAM_SHA:0:8}"
BRANCH="chore/upstream-sync-${SHA8}"

log "Upstream is ${AHEAD_COUNT} commit(s) ahead of origin/${DEFAULT_BRANCH}"
log "Pushing upstream/${UPSTREAM_BRANCH} (${SHA8}) → origin/${BRANCH}"

git push --force-with-lease origin "refs/remotes/upstream/${UPSTREAM_BRANCH}:refs/heads/${BRANCH}"

gh label create "$LABEL" \
  --description "Upstream sync (review before merge)" \
  --color "1D76DB" 2>/dev/null || true

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

COMPARE_URL=""
case "$UPSTREAM_URL" in
  https://github.com/*)
    COMPARE_URL="https://github.com/${UPSTREAM_REPO}/compare/${LOCAL_SHA:0:12}...${UPSTREAM_SHA:0:12}"
    ;;
  https://codeberg.org/*)
    COMPARE_URL="https://codeberg.org/${UPSTREAM_REPO}/compare/${LOCAL_SHA:0:12}...${UPSTREAM_SHA:0:12}"
    ;;
esac

{
  echo "## Upstream sync"
  echo
  echo "Upstream: [\`${UPSTREAM_REPO}\`](${UPSTREAM_URL%.git}) (\`${UPSTREAM_BRANCH}\`)"
  echo
  echo "- Local \`origin/${DEFAULT_BRANCH}\`: \`${LOCAL_SHA:0:12}\`"
  echo "- Upstream tip: \`${UPSTREAM_SHA:0:12}\`"
  echo "- Commits ahead: **${AHEAD_COUNT}**"
  if [[ -n "$COMPARE_URL" ]]; then
    echo "- Compare: ${COMPARE_URL}"
  fi
  echo
  echo "### What you should do"
  echo "- **Merge** → take these upstream commits into \`${DEFAULT_BRANCH}\`."
  echo "- **Close** → skip for now (workflow may reopen next week)."
  echo
  echo "Nothing auto-merges to \`${DEFAULT_BRANCH}\`."
  echo
  echo "## Commits"
  echo
  git log --format='- `%h` %s' "origin/${DEFAULT_BRANCH}..upstream/${UPSTREAM_BRANCH}" | head -n 50
  if [[ "$AHEAD_COUNT" -gt 50 ]]; then
    echo "- …and $((AHEAD_COUNT - 50)) more"
  fi
} > "$BODY"

TITLE="chore(upstream): sync ${UPSTREAM_REPO}@${SHA8}"

if gh pr view "$BRANCH" --json number >/dev/null 2>&1; then
  gh pr edit "$BRANCH" --title "$TITLE" --body-file "$BODY"
  log "Updated existing PR for ${BRANCH}"
  gh pr view "$BRANCH" --json url --jq .url
else
  if gh pr create --base "$DEFAULT_BRANCH" --head "$BRANCH" --title "$TITLE" --body-file "$BODY" --label "$LABEL"; then
    :
  else
    gh pr create --base "$DEFAULT_BRANCH" --head "$BRANCH" --title "$TITLE" --body-file "$BODY"
  fi
  log "Opened PR for ${BRANCH}"
fi
