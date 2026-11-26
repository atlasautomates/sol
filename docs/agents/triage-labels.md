# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the "Label in our tracker" column to match whatever vocabulary you actually use.

## PR labels

`trivial`: every hunk of the PR is verifiable by shape in under a minute: a typo, a comment, a version comment, a label. Never logic, a workflow, a script, or a suppression file (`.gitleaksignore`, a zizmor ignore, `osv-scanner.toml`). `scripts/merge-pr.sh` lets a PR with this label merge without a named reviewer (`reviewer: n/a`); it still refuses a self-review and anything not green. The gate prints this same bar when it refuses (`scripts/lib/review-rule.sh`), so change both together.
