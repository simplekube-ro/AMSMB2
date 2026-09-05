---
name: profiling-tooling
description: How to review/verify scripts/profile-summary.sh and its XML fixtures fast, including the real-bundle shortcut and the XML-comment gotcha
metadata:
  type: project
---

`scripts/profile-summary.sh` (bash + one inline python3) is verified only by hand-written
fixtures under `test-fixtures/profiling/*/expected.txt`; nothing in `swift test` or CI runs them.
`SignpostContractTests` only greps the script and `docs/PROFILING.md` for the five signpost names.

**Why:** the script is the sole source of the before/after numbers recorded in
`docs/PROFILING.md`, which gate #45/#46; a silent parsing regression would not be caught by the
Swift suite.

**How to apply when reviewing a change to it:**
- Run every `diff <(scripts/profile-summary.sh ...) .../expected.txt` command the doc lists, plus
  each fixture twice (determinism).
- Real Apple TV bundles live in the gitignored `../RandomPlayer/profiling/`. Full `.trace`
  exports are slow, but pre-exported `rc5-run{1,2,3}-signposts.xml` and
  `baseline-run2-signposts.xml` are already there. Fastest independent check of a doc's pasted
  script-output block: make a temp dir, symlink one of those as `os-signpost.xml`, copy any
  fixture's `time-profile.xml` in, and run the script on the dir (~3 s for 75 MB). The
  time-profile block is then meaningless but the whole signpost block is real.
- **`--` is illegal inside an XML comment**, so fixture header comments must paraphrase
  (`the pairing option set to global`) instead of writing `--pairing global`. Do not "fix" that.
- Fixture header comments carry a hand-computed "Expected numbers" block that is the audit trail
  for `expected.txt`. Recompute it, not just the `diff`: the two can disagree (seen 2026-09-05 on
  `ceiling-export`, where the comment truncated 96.478/89.587 to 96.47/89.58 while `expected.txt`
  correctly rounds to 96.48/89.59). A clean `diff` proves the script self-consistent, not right.
- When a doc records numbers "from the script", check they are actually *printed* by it. Figures
  needing the raw size list (e.g. "% of chunks that are whole multiples of 1448 bytes", per-run
  at-or-above chunk *counts*) come from an uncommitted ad-hoc reader and must be labelled
  measured-from-raw-sizes, not "derived".
