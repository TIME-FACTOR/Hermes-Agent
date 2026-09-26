#!/usr/bin/env bash
# Keep this fork's main current with upstream.
# Inherited GitHub workflows are stripped so upstream CI does not run here.
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?UPSTREAM_REPO is required}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }
need git

if git remote get-url upstream >/dev/null 2>&1; then
  git remote set-url upstream "$UPSTREAM_URL"
else
  git remote add upstream "$UPSTREAM_URL"
fi

git fetch --quiet origin "$DEFAULT_BRANCH"
git fetch --quiet upstream "$UPSTREAM_BRANCH"

git checkout --quiet -B "$DEFAULT_BRANCH" "origin/${DEFAULT_BRANCH}"

LOCAL_SHA="$(git rev-parse HEAD)"
UPSTREAM_SHA="$(git rev-parse "upstream/${UPSTREAM_BRANCH}")"
AHEAD_COUNT="$(git rev-list --count "HEAD..upstream/${UPSTREAM_BRANCH}")"

KEEP_WORKFLOW=".github/workflows/upstream-sync.yml"
KEEP_SCRIPT=".github/scripts/upstream-fork-sync.sh"
SAVED="$(mktemp -d)"
trap 'rm -rf "$SAVED"' EXIT
cp "$KEEP_WORKFLOW" "$SAVED/upstream-sync.yml"
cp "$KEEP_SCRIPT" "$SAVED/upstream-fork-sync.sh"

strip_inherited_ci() {
  mkdir -p .github/workflows .github/scripts
  find .github/workflows -type f ! -name 'upstream-sync.yml' -delete
  cp "$SAVED/upstream-sync.yml" "$KEEP_WORKFLOW"
  cp "$SAVED/upstream-fork-sync.sh" "$KEEP_SCRIPT"
  chmod +x "$KEEP_SCRIPT"
}

if [[ "$AHEAD_COUNT" -eq 0 ]]; then
  strip_inherited_ci
  if git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard .github)" ]]; then
    log "Already up to date with ${UPSTREAM_REPO}@${UPSTREAM_BRANCH} (${UPSTREAM_SHA:0:8})."
    exit 0
  fi
  git add -A .github
  git -c user.email="actions@users.noreply.github.com" -c user.name="hermes-upstream-sync" \
    commit -m "ci: drop inherited upstream workflows on this fork"
  git push origin "HEAD:${DEFAULT_BRANCH}"
  log "Removed inherited workflows from ${DEFAULT_BRANCH}."
  exit 0
fi

log "Upstream is ${AHEAD_COUNT} commit(s) ahead (${UPSTREAM_SHA:0:8}). Merging into ${DEFAULT_BRANCH}."
git merge --no-edit "upstream/${UPSTREAM_BRANCH}"

strip_inherited_ci
git add -A
if ! git diff --cached --quiet; then
  git -c user.email="actions@users.noreply.github.com" -c user.name="hermes-upstream-sync" \
    commit -m "ci: keep only the fork upstream-sync workflow"
fi

git push origin "HEAD:${DEFAULT_BRANCH}"
log "Updated origin/${DEFAULT_BRANCH} to include ${UPSTREAM_REPO}@${UPSTREAM_SHA:0:8} without inherited CI."
