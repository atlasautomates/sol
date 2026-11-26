# Sol

A fork of [ospfranco/sol](https://github.com/ospfranco/sol), a macOS launcher built on React Native macOS with native Swift and Objective-C. This repo is public: tickets, PR text, and commits are visible to anyone.

## Agent skills

### Issue tracker

Tickets live in this repo's GitHub Issues, through the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Working rules

### Local setup

`src/env.ts` is gitignored because it holds the Sentry DSN. A fresh clone needs it before `tsc` or the Xcode build: write `export const SentryDSN = ''` to `src/env.ts` (CI writes the same stub).

### CI and merging

- CI (`.github/workflows/ci.yml`) runs on every PR and every push to `main`, on GitHub's macOS runners (`macos-latest`; the repo is public). One check, `build + tests`, holds three layers:
  - JS tests: `node --experimental-strip-types --test "src/**/*.test.ts"`
  - File index acceptance (native): `sh macos/file-index-tests/run.sh`
  - Xcode build: scheme `debug`, unsigned, with `pod install` first.
- The heavy layers run only when a changed file can affect them. The rule is `scripts/lib/affects-build.sh`: an allowlist of paths the build never reads (docs, root markdown, `.github/`, `scripts/`, `.githooks/`). Extend it only by adding paths that provably cannot affect the build, never by excluding code. `ci.yml` itself is allowlisted, so an edit to it is exercised at the next build-relevant change.
- Known gaps, not yet in CI: `tsc --noEmit` and `biome ci`, both red on `main`. Each has an issue (#7, #8); add the layer to `ci.yml` once its issue lands.
- The PR-only invariant: nothing reaches `main` except through a reviewed, green PR. Layer 1 is the merge gate, layer 2 the push guard, layer 3 CI itself.
- Merge only with `scripts/merge-pr.sh <pr>`. It refuses unless every check on the PR's head is green. It also refuses an unreviewed PR (`reviewer: n/a` or `pending`) without the `trivial` label, and a self-review (the reviewer's model id equals the author's).
- Each clone arms the push guard once: `git config core.hooksPath .githooks`. The `pre-push` hook refuses any push to `main` and runs the JS tests first, unless every changed file is on the allowlist.
- This repo has no self-hosted runner, and must never get one while it is public: a fork PR runs the workflow from its own head and could target it. If the repo ever goes private and gains one, remove the runner before making the repo public again.
