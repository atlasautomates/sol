# shellcheck shell=bash
# affects_build: the build-relevance rule shared by .githooks/pre-push and .github/workflows/ci.yml.
#
#   git diff --name-only A B | affects_build   # exit 0 = run the full suite, 1 = skip it
#
# Reads changed paths, one per line, on stdin. Skips only when every path is on the allowlist below
# and none has an extension Xcode reads; anything the allowlist does not name runs. Blank lines are
# ignored, and an empty list runs (fail closed). Pure: no git, no network. Bash 3.2 (macOS) safe.
# The list is extended only by adding paths that provably cannot affect the build or tests, never
# by excluding code. Tested by scripts/test-affects-build.sh.

# Directories the build never reads: documentation, CI and security workflows, repo tooling, git hooks.
AFFECTS_BUILD_SAFE_PREFIXES=("docs/" ".github/" "scripts/" ".githooks/")

# Root files the build never reads. `*.md` is matched case-insensitively below (README.md, NOTES.MD).
AFFECTS_BUILD_SAFE_ROOT_FILES=(".gitignore" "LICENSE")

# Extensions the BUILD reads. This is the stack-specific line of the whole rule; setup-ci step 4
# adapts it. A path with one of these on any component runs even under a safe prefix: the prefix
# list says where safe files usually live, not that nothing there can ever be compiled or bundled.
#   Xcode:   swift m h plist pbxproj xcproj xcscheme resolved xcassets storyboard xib entitlements xcconfig xcprivacy
#   Node:    js mjs cjs ts tsx jsx json lock css scss html (package.json and lockfiles are .json/.lock)
#   Python:  py pyi toml cfg txt lock ini (pyproject.toml, requirements*.txt, uv.lock)
#   Android: kt java xml gradle kts pro properties
# Sol is both: React Native JS/TS bundled by Metro, and a native app with Objective-C++ (.mm, .cpp).
AFFECTS_BUILD_BUILD_EXTENSIONS=(swift m mm c cpp h plist pbxproj xcproj xcscheme resolved xcassets storyboard xib entitlements xcconfig xcprivacy js mjs cjs ts tsx jsx json lock css scss html)

_affects_build_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# 0 when this one path cannot affect the build or tests, 1 otherwise.
_affects_build_path_is_safe() {
  local file=$1 lower part p safe=1 parts
  lower=$(_affects_build_lower "$file")
  # Every component is checked, not only the last: Assets.xcassets is a directory whose files are
  # Contents.json and images, and it is still read by Xcode.
  IFS=/ read -r -a parts <<<"$lower"
  for part in "${parts[@]}"; do
    [[ "$part" == *.* ]] || continue
    for p in "${AFFECTS_BUILD_BUILD_EXTENSIONS[@]}"; do
      [[ "${part##*.}" == "$p" ]] && return 1
    done
  done
  for p in "${AFFECTS_BUILD_SAFE_PREFIXES[@]}"; do
    [[ "$file" == "$p"* ]] && safe=0
  done
  if [[ "$file" != */* ]]; then
    [[ "$lower" == *.md ]] && safe=0
    for p in "${AFFECTS_BUILD_SAFE_ROOT_FILES[@]}"; do
      [[ "$file" == "$p" ]] && safe=0
    done
  fi
  return $safe
}

affects_build() {
  local line seen=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    seen=1
    _affects_build_path_is_safe "$line" || return 0
  done
  (( seen )) || return 0
  return 1
}
