#!/usr/bin/env bash
# check-action-runtimes: every action a workflow uses must declare a supported Node runtime.
#
#   scripts/check-action-runtimes.sh [workflow-dir]        (default .github/workflows)
#
# For each step-level `uses: owner/repo[/path]@ref`, fetches that action's action.yml (or
# action.yaml) at exactly that ref and reads `runs.using`. Fails on node20 or older: GitHub removed
# Node 20 from runners on 2026-09-23, so a node20 declaration runs on Node 24 only by the runner's
# grace, and a later runner release can refuse it with no change on our side. composite, docker and
# node24+ pass. Skipped, having no runtime of their own: local actions (./), docker:// images, and
# reusable workflows (…/x.yml@ref). Fails closed: an action file that cannot be fetched or parsed,
# an unrecognised runs.using, or a `uses` value that is not a resolvable spec all FAIL.
#
# A composite action's own `uses:` steps are checked too, one level deep (an inner composite's steps
# are not followed); those rows carry `via` = the parent spec.
#
# Needs `gh` authenticated (GH_TOKEN in CI), `jq`, and `yq` (mikefarah v4; preinstalled on
# ubuntu-latest). Parsing is by yq over the real YAML, never grep: grep matches `uses:` inside run:
# strings and comments, and a first-`using:` match can read an inputs description.
#
# Test seam: CHECK_ACTION_RUNTIMES_FETCHER names a command run as `<cmd> <owner/repo> <path> <ref>`
# that prints the action file, or exits non-zero with a reason on stderr (default: gh api).
#
# Human lines on stderr; a JSON array of {verdict, uses, using, reason, via} on stdout.
# Exit codes: 0 every row PASS (including `[]` when the workflows use no actions at all, a legitimate
# run-only repo); 1 at least one FAIL row; 2 usage or environment error (no workflow files, or yq/jq
# missing), with no JSON on stdout.
set -euo pipefail

for tool in jq yq; do
  command -v "$tool" >/dev/null || { echo "check-action-runtimes: $tool is required but not installed" >&2; exit 2; }
done

dir="${1:-.github/workflows}"
min_node=24
fail=0
json="["
seen=$'\n'
errf="$(mktemp)"; trap 'rm -f "$errf"' EXIT

gh_fetch() { gh api "repos/$1/contents/$2?ref=$3" --jq .content | base64 -d; }
fetcher="${CHECK_ACTION_RUNTIMES_FETCHER:-gh_fetch}"

emit() { # verdict spec using reason via
  local suffix=""; [[ -n "$5" ]] && suffix=" (via $5)"
  printf '%-4s %-80s %-10s %s%s\n' "$1" "$2" "$3" "$4" "$suffix" >&2
  json+="$( [[ "$json" == "[" ]] || printf ',' )"
  json+="$(jq -cn --arg v "$1" --arg s "$2" --arg u "$3" --arg r "$4" --arg via "$5" \
    '{verdict:$v,uses:$s,using:$u,reason:$r,via:(if $via=="" then null else $via end)}')"
  [[ "$1" == "FAIL" ]] && fail=1 || true
}

# check_spec <spec> <via> <depth>: emit a row, and for a composite at depth 0 recurse into its steps.
check_spec() {
  local spec="$1" via="$2" depth="$3" ref path owner_repo sub p f content using="" reason="" fetched="" inner
  case "$spec" in ./*|docker://*) return;; esac
  case "$seen" in *$'\n'"$spec|$via"$'\n'*) return;; esac
  seen+="$spec|$via"$'\n'
  if [[ "$spec" != *@* || "$spec" == *'${{'* || "${spec%@*}" != */* ]]; then
    emit FAIL "$spec" "?" "uses value is not a resolvable owner/repo[/path]@ref spec" "$via"; return
  fi
  ref="${spec##*@}"; path="${spec%@*}"
  case "$path" in *.yml|*.yaml) return;; esac
  owner_repo="$(cut -d/ -f1,2 <<<"$path")"; sub="$(cut -d/ -f3- -s <<<"$path")"
  content=""
  for f in action.yml action.yaml; do
    p="${sub:+$sub/}$f"
    if content="$("$fetcher" "$owner_repo" "$p" "$ref" 2>"$errf")"; then
      fetched=1; reason=""
      # The reason describes the file we actually got: a .yml fetch error is stale once .yaml fetches.
      if using="$(yq -r '.runs.using' <<<"$content" 2>"$errf")"; then
        [[ "$using" == null ]] && reason="$p has no runs.using"
      else
        using=""; reason="$p unparseable: $(tr '\n' ' ' <"$errf")"
      fi
      break
    fi
    reason+="${reason:+; }$p: $(tr '\n' ' ' <"$errf")"
  done
  if [[ -z "$using" || "$using" == null ]]; then
    emit FAIL "$spec" "?" "${reason:-runs.using missing}; failing closed" "$via"
  elif [[ "$using" =~ ^node([0-9]+)$ ]]; then
    # 10# : "09" is decimal, not an invalid octal literal.
    if (( 10#${BASH_REMATCH[1]} < min_node )); then
      emit FAIL "$spec" "$using" "declares a retired Node runtime; minimum is node$min_node" "$via"
    else
      emit PASS "$spec" "$using" "supported Node runtime" "$via"
    fi
  elif [[ "$using" == composite || "$using" == docker ]]; then
    emit PASS "$spec" "$using" "no Node runtime of its own" "$via"
    if [[ "$using" == composite && "$depth" -eq 0 ]]; then
      inner="$(yq -o=json -I=0 '.runs.steps[]? | .uses | select(. != null)' <<<"$content" | to_specs)"
      while IFS= read -r p; do [[ -n "$p" ]] && check_spec "$p" "$spec" 1; done <<<"$inner"
    fi
  else
    emit FAIL "$spec" "$using" "unrecognised runs.using" "$via"
  fi
}

# JSON scalars from yq -> one spec per line; a non-string value becomes a sentinel that fails validation.
to_specs() { jq -r 'if type=="string" then . else "<non-string uses>" end'; }

shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
shopt -u nullglob
(( ${#files[@]} )) || { echo "check-action-runtimes: no workflow files under $dir" >&2; exit 2; }
specs=""
for f in "${files[@]}"; do
  # One yq run per file: a workflow yq cannot parse is a FAIL row, never a silent skip or an abort.
  if raw="$(yq -o=json -I=0 '.jobs[]? | .steps[]? | .uses | select(. != null)' "$f" 2>"$errf")"; then
    specs+="$(to_specs <<<"$raw")"$'\n'
  else
    emit FAIL "$f" "?" "workflow unparseable: $(tr '\n' ' ' <"$errf")" ""
  fi
done
specs="$(sort -u <<<"$specs" | sed '/^$/d')"
[[ -n "$specs" ]] || echo "check-action-runtimes: no actions used under $dir" >&2

while IFS= read -r spec; do { [[ -z "$spec" ]] || check_spec "$spec" "" 0; }; done <<<"$specs"

printf '%s]\n' "$json"
exit "$fail"
