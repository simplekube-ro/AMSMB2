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
