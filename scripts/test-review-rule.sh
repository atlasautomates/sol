#!/usr/bin/env bash
# Acceptance test for #20: the merge gate's review rule.
#
#   scripts/test-review-rule.sh
#
# The rule lives in scripts/lib/review-rule.sh as a function `review_rule <pr-body> <labels-json>`
# that exits 0 (may merge) or 1 (refuse) and, on refusal, prints one line naming the rule to stderr.
# merge-pr.sh calls it; this test calls it with fixtures. Red until that file exists and behaves.
set -uo pipefail
cd "$(dirname "$0")/.."
lib=scripts/lib/review-rule.sh
[[ -f "$lib" ]] || { echo "FAIL: $lib does not exist" >&2; exit 1; }
# shellcheck source=/dev/null
source "$lib"

block() { # reviewer-value [author-value]
  printf 'Some PR body.\n\ngrill:       n/a\nplanner:     claude-fable-5-1\ntest-writer: n/a\nauthor:      %s\ntester:      claude-sonnet-5-5\nreviewer:    %s\n' "${2:-claude-sonnet-5-5}" "$1"
}
no_reviewer_line() { printf 'Some PR body.\n\nauthor:      claude-sonnet-5-5\n'; }

fails=0
expect() { # name expected-exit body labels-json
  local name=$1 want=$2 body=$3 labels=$4 got err
  err="$(review_rule "$body" "$labels" 2>&1 >/dev/null)"; got=$?
  if [[ "$got" != "$want" ]]; then echo "FAIL $name: exit $got, wanted $want" >&2; fails=1; return; fi
  if [[ "$want" == 1 && -z "$err" ]]; then echo "FAIL $name: refused silently; a refusal names the rule" >&2; fails=1; return; fi
  echo "PASS $name" >&2
}

expect "n/a, no labels → refuse"                 1 "$(block 'n/a')"                       '[]'
expect "n/a, trivial label → pass"                0 "$(block 'n/a')"                       '["trivial"]'
expect "n/a, other labels only → refuse"          1 "$(block 'n/a')"                       '["bug","enhancement"]'
expect "pending → refuse (not a review)"          1 "$(block 'pending')"                   '[]'
expect "reviewer line missing → refuse"           1 "$(no_reviewer_line)"                  '[]'
expect "reviewer line missing, trivial → pass"    0 "$(no_reviewer_line)"                  '["trivial"]'
expect "named reviewer → pass"                    0 "$(block 'claude-opus-5-5 (independent review agent)')" '[]'
expect "named reviewer, case/space variants"      0 "$(printf 'reviewer:claude-opus-5-5\n')" '[]'
expect "N/A uppercase → refuse"                   1 "$(block 'N/A')"                       '[]'

# Amendments (Adrian, 2026-11-07): a self-review is not a review, and a refusal teaches the bar.
expect "reviewer == author → refuse"              1 "$(block 'claude-sonnet-5-5' 'claude-sonnet-5-5')" '[]'
expect "reviewer == author, trivial → still refuse" 1 "$(block 'claude-sonnet-5-5' 'claude-sonnet-5-5')" '["trivial"]'
expect "reviewer == author with note → refuse"    1 "$(block 'claude-sonnet-5-5 (self)' 'claude-sonnet-5-5')" '[]'
expect "reviewer ≠ author, same vendor → pass"    0 "$(block 'claude-opus-5-5' 'claude-sonnet-5-5')" '[]'

# GitHub's web editor can save bodies with CRLF; "n/a\r" must not pass as a named reviewer.
expect "CRLF body, n/a → refuse"                  1 "$(block 'n/a' | sed 's/$/\r/')"       '[]'
expect "CRLF body, named reviewer → pass"         0 "$(block 'claude-opus-5-5' | sed 's/$/\r/')" '[]'

# The unreviewed refusal must state the trivial bar, not only point at a doc.
msg="$(review_rule "$(block 'n/a')" '[]' 2>&1 >/dev/null)"
if grep -qi 'trivial' <<<"$msg" && grep -qiE 'under a minute|by shape' <<<"$msg" && grep -qiE 'never .*(logic|workflow|script)' <<<"$msg" && grep -qi 'suppression file' <<<"$msg"; then
  echo "PASS refusal states the trivial bar" >&2
else
  echo "FAIL refusal does not state the trivial bar; got: $msg" >&2; fails=1
fi

exit "$fails"
