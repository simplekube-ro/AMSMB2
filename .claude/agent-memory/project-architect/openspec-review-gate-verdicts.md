---
name: OpenSpec review-gate verdict matching
description: How .claude/hooks/openspec-review-gate.py parses the proposal.md Review section
type: reference
---

`.claude/hooks/openspec-review-gate.py` scans the `## Review` section of `proposal.md` and
blocks `openspec instructions apply` unless it matches `\bAPPROVED\b` (case-insensitive) AND the
section contains neither the unfilled template placeholder
(`APPROVED / APPROVED WITH CONDITIONS / NEEDS REVISION`) nor a literal revision verdict.

**Why:** the match is textual, not structural — so a verdict of APPROVED WITH CONDITIONS passes
the gate, but quoting the revision-verdict phrase anywhere in the section body (e.g. inside a
finding) blocks apply even when the verdict line itself is approving.

**How to apply:** when recording APPROVED / APPROVED WITH CONDITIONS, never write the revision
verdict phrase in the findings prose; phrase conditions as "address before apply completes".
