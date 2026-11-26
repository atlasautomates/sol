#!/usr/bin/env bash
# merge-pr: the only sanctioned way to land a PR on main.
#
#   scripts/merge-pr.sh <pr-number>
#
# Refuses an unreviewed or self-reviewed PR (scripts/lib/review-rule.sh), and refuses unless every
# check on the PR's current head is green (and at least one exists). Then squash-merges exactly that
# head, and cleans up the worktree, the local branch, and main.
# Layer 1 of the PR-only invariant (see the repo's AGENTS.md). Installed by the setup-ci skill.
set -euo pipefail

pr="${1:-}"
[[ "$pr" =~ ^[0-9]+$ ]] || { echo "usage: scripts/merge-pr.sh <pr-number>" >&2; exit 64; }

# Resolved before the cd below, which moves to the main checkout: the rule this script runs is the
# one beside it, not whatever version main's checkout happens to hold.
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/review-rule.sh"

common="$(git rev-parse --git-common-dir)"
root="$(cd "$(dirname "$common")" && pwd)"          # the main checkout, even when run from a worktree
cd "$root"

# Pin the head SHA before reading checks. Merging with --match-head-commit on this SHA means
# a commit pushed after the checks were read makes GitHub refuse, instead of landing unchecked.
read -r state base head sha < <(gh pr view "$pr" --json state,baseRefName,headRefName,headRefOid \
  --jq '[.state, .baseRefName, .headRefName, .headRefOid] | @tsv' | tr '\t' ' ')
[[ "$state" == "OPEN" ]] || { echo "merge-pr: PR #$pr is $state, not OPEN" >&2; exit 1; }
[[ "$base" == "main" ]]  || { echo "merge-pr: PR #$pr targets $base, not main" >&2; exit 1; }

# Review rule (scripts/lib/review-rule.sh): an unreviewed or self-reviewed PR is refused before
# CI is read, so the refusal does not depend on whether checks happen to be green yet.
# A copy of this script synced from the template without its lib/ would otherwise die on a raw
# bash error; refusing by name tells the operator what to sync.
[[ -f "$lib" ]] || { echo "merge-pr: $lib is missing; the review rule cannot run, so nothing merges until it is restored" >&2; exit 1; }
# shellcheck source=lib/review-rule.sh
source "$lib"
meta="$(gh pr view "$pr" --json body,labels)"
review_rule "$(jq -r '.body' <<<"$meta")" "$(jq -c '[.labels[].name]' <<<"$meta")" || exit 1

# Green means: at least one check, and every check in the pass bucket.
checks="$(gh pr checks "$pr" --json name,bucket 2>/dev/null || echo '[]')"
total="$(jq 'length' <<<"$checks")"
bad="$(jq -r '[.[] | select(.bucket != "pass" and .bucket != "skipping")] | .[] | "\(.name): \(.bucket)"' <<<"$checks")"
if (( total == 0 )); then
  echo "merge-pr: PR #$pr has no checks reported; CI must run before merge" >&2; exit 1
fi
# A PR can delete or rewrite security.yml and still have every reported check green, because a
# pull_request run uses the PR's own copy. Every guard main's security.yml defines must be present.
git fetch --quiet origin main
if git cat-file -e origin/main:.github/workflows/security.yml 2>/dev/null; then
  for g in $(git show origin/main:.github/workflows/security.yml | sed -n 's/^    name: \(guard-[a-z-]*\)$/\1/p'); do
    jq -e --arg g "$g" 'any(.[]; .name == $g)' <<<"$checks" >/dev/null ||
      { echo "merge-pr: PR #$pr does not report $g, which main's security.yml requires" >&2; exit 1; }
  done
fi
if [[ -n "$bad" ]]; then
  echo "merge-pr: PR #$pr is not green:" >&2; echo "$bad" >&2
  # A red `guard-*` check is a security finding, not a flaky test: each finding gets fixed, or
  # suppressed at that one finding with a reason and an expiry. The guard itself stays as it is.
  if grep -q '^guard-' <<<"$bad"; then
    echo "merge-pr: a security guard is red; triage each finding (fix, or scoped suppression with reason and expiry), never the guard" >&2
  fi
  exit 1
fi

# No --delete-branch: it also deletes the *local* branch, which fails while that branch is
# checked out in a worktree. The repo's delete-branch-on-merge setting removes the remote branch.
gh pr merge "$pr" --squash --match-head-commit "$sha"
echo "merge-pr: PR #$pr squash-merged into main"

# Clean up only what is provably the merged work: a dirty worktree or a branch whose tip is not
# the merged SHA holds something the merge did not include, so it is kept and reported.
# Paths can contain spaces, so take everything after "worktree " rather than awk's $2.
wt="$(git worktree list --porcelain | awk -v b="refs/heads/$head" '/^worktree /{w=substr($0, 10)} $1=="branch"&&$2==b{print w}')"
if [[ "$wt" == "$root" ]]; then
  git checkout --quiet main && echo "merge-pr: switched the main checkout from $head to main"
elif [[ -n "$wt" ]]; then
  if git worktree remove "$wt" 2>/dev/null; then
    echo "merge-pr: removed worktree $wt"
  else
    echo "merge-pr: kept worktree $wt (uncommitted changes); remove it by hand once they are saved" >&2
  fi
fi
if git show-ref --verify --quiet "refs/heads/$head"; then
  if [[ "$(git rev-parse "refs/heads/$head")" == "$sha" ]]; then
    git branch -D "$head" >/dev/null; echo "merge-pr: deleted local branch $head"
  else
    echo "merge-pr: kept local branch $head (its tip is not the merged commit)" >&2
  fi
fi
git fetch --prune --quiet origin
if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]]; then
  git merge --ff-only --quiet origin/main && echo "merge-pr: main fast-forwarded to $(git rev-parse --short HEAD)"
else
  echo "merge-pr: main checkout is on $(git rev-parse --abbrev-ref HEAD); run 'git merge --ff-only origin/main' on main" >&2
fi
