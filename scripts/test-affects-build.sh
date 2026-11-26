#!/usr/bin/env bash
# Acceptance test for scripts/lib/affects-build.sh, the build-relevance rule shared by
# .githooks/pre-push and .github/workflows/ci.yml. CI runs it before trusting the rule.
#
#   scripts/test-affects-build.sh   # exit 0 when every case passes
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/affects-build.sh
source scripts/lib/affects-build.sh

fails=0
# expect <run|skip> <description> <paths, one per line>
expect() {
  local want=$1 name=$2 list=$3 status=0 got
  printf '%s' "$list" | affects_build || status=$?
  if (( status == 1 )); then got=skip; else got=run; fi
  if [[ "$got" == "$want" ]]; then
    echo "PASS $name → $got"
  else
    echo "FAIL $name → $got, want $want" >&2; fails=$((fails + 1))
  fi
}

expect skip "docs-only change"            $'docs/agents/triage-labels.md\nAGENTS.md\nGLOSSARY.md'
expect run  "one source file"             $'docs/agents/domain.md\nsrc/lib/fileSearchPage.ts'
expect run  "a build file under docs/"    'docs/example/Info.plist'
expect run  "an unknown root file"        'Podfile.local'
expect run  "an empty list"               ''
expect run  "an Objective-C++ file"       'macos/sol-macOS/lib/SolNative.mm'
expect run  "a dependency patch"          'patches/react-native-macos@0.81.7.patch'
expect run  "a JS file under scripts/"    'scripts/appcast.js'
expect skip "workflow, hook and scripts"  $'.github/workflows/ci.yml\n.githooks/pre-push\nscripts/merge-pr.sh'

(( fails == 0 )) || { echo "$fails case(s) failed" >&2; exit 1; }
