# review-rule: the merge gate's review rule, sourced by scripts/merge-pr.sh.
#
#   review_rule <pr-body> <labels-json>   → 0 may merge, 1 refuse (one line on stderr naming the rule)
#
# A pure function over its arguments (no gh, no network) so scripts/test-review-rule.sh can pin it
# with fixtures. It reads the attribution block's `reviewer:` and `author:` lines (see the "Git"
# section of ~/.agents/AGENTS.md). Written for macOS's bash 3.2: no ${var,,}, no associative arrays.

# Value of the LAST "<key>:" line in <body>, trimmed; status 1 when no such line exists.
# Last wins so a quoted example or template text earlier in the body cannot count; a review record
# appended after the block (PR #21's shape) holds no `reviewer:` line of its own, so it is unaffected.
# Keys match case-insensitively with any leading indent and any (or no) space after the colon.
_review_attr() { # body key
  local line value="" found=1 restore
  restore="$(shopt -p nocasematch)"
  shopt -s nocasematch
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"   # GitHub's web editor can save CRLF; "n/a\r" must not read as a name.
    if [[ "$line" =~ ^[[:space:]]*$2:[[:space:]]*(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"; found=0
    fi
  done <<<"$1"
  eval "$restore"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
  return "$found"
}

# The model id a value names: cut at the first "(" (a note such as "(self)"), trimmed, lowercased.
# Model ids never contain "(", so a value that is only a note names no reviewer at all.
_review_id() {
  local id="${1%%(*}"
  id="${id%"${id##*[![:space:]]}"}"
  printf '%s' "$id" | tr '[:upper:]' '[:lower:]'
}

review_rule() { # pr-body labels-json
  local body="$1" labels="$2" reviewer author shown rid aid
  if reviewer="$(_review_attr "$body" reviewer)"; then shown="${reviewer:-empty}"; else shown="missing"; fi
  rid="$(_review_id "$reviewer")"

  case "$rid" in
    "" | n/a | pending)
      # Malformed labels JSON fails closed: jq errors, so the PR counts as not trivial.
      # The bar below is the definition in docs/agents/triage-labels.md; keep the two in step.
      jq -e 'type == "array" and any(.[]; . == "trivial")' <<<"$labels" >/dev/null 2>&1 && return 0
      echo "merge-pr: review rule: reviewer is $shown; get an independent review and name the reviewer, or add the trivial label if every hunk is verifiable by shape in under a minute (typo, comment, version comment, label), never logic, a workflow, a script or a suppression file (.gitleaksignore, a zizmor ignore, osv-scanner.toml) (docs/agents/triage-labels.md)" >&2
      return 1 ;;
  esac

  # Author ≠ reviewer, compared by model id: a note on the reviewer line does not make a self-review
  # independent, and the trivial label does not lift this rule.
  author="$(_review_attr "$body" author)" || author=""
  aid="$(_review_id "$author")"
  if [[ "$rid" == "$aid" ]]; then
    echo "merge-pr: review rule: reviewer $rid is the author; a self-review is not a review, and the trivial label does not lift this" >&2
    return 1
  fi
  return 0
}
