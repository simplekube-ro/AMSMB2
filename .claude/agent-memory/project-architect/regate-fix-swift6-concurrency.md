---
name: Re-gate precedent — fix-swift6-concurrency scope expansions
description: How the architect ruled on two scope expansions during the swift6-concurrency re-gate
type: project
---

Re-gate of `fix-swift6-concurrency` (originally GATE_APPROVED 2026-06-27) on 2026-06-30, triggered by binding guardrail 4 ("if any diagnostic beyond the five appears, update design.md and re-gate"). Two scope expansions were flagged by the swift-code-reviewer (task 4.1).

**Ruling 1 — C2b test-portability fixes (test-only): ACCEPTED into the change (A), conditional on honest artifacts.**
- Why: the change's own approved acceptance bar (B) is "make linuxtest builds AND passes." The test target had never compiled on Linux before because the 5 library errors blocked the library target; clearing them exposed pre-existing Linux-portability defects (FoundationNetworking import, UInt64(NSEC_PER_SEC), @unchecked Sendable on 3 integration test classes, #if canImport(Darwin) on 2 NSCoding tests). You cannot evaluate bar (B) without them. Splitting would create a verification deadlock (a standalone Linux-test-portability change couldn't go green without this change first). Minimal, test-only, mirror existing conventions, zero library behavior change.
- How to apply: when an acceptance bar requires a green build/test and clearing the in-scope defect exposes orthogonal blockers that gate that same bar, those blockers are inside the bar's envelope — accept, but make the spec/design honest about the widened file surface.

**Ruling 2 — ~2200 lines of agent scaffolding (.agents/, .codex/, AGENTS.md, .gitignore) bundled in d2c0d18: out-of-scope (B), but record-only remediation.**
- Why: tooling, unrelated to the fix or to either acceptance bar; pure change-hygiene pollution. But it's merged to master and the user explicitly requested keeping it ("per request" in the commit). It is NOT in spec.md so archiving does not bless it in openspec/specs. History rewrite is off the table.
- How to apply: disown it in the artifacts (state it is not part of the capability); do not let any spec.md confinement scenario be contradicted by it; do not require revert. The scaffolding's continued tracking is a product decision, not an architecture one.

**The actual blocker found: spec.md is dishonest.** `openspec/changes/fix-swift6-concurrency/specs/swift6-strict-concurrency/spec.md` has a scenario "Edits confined to Context.swift" asserting "only AMSMB2/Context.swift (plus the OpenSpec artifacts) is modified." That is FALSE as shipped (test files, Dockerfile, agent tooling all changed) and would be permanently accumulated into openspec/specs on archive, violating the project rule "Keep specs honest." design.md honestly records deviations #1 (queueKey #if split) and #2 (C2b) but omits the scaffolding. **Verdict: RE-GATE APPROVED conditional — archive is BLOCKED until spec.md + design.md are corrected for honesty.** The queueKey #if-canImport(Darwin) split (vs bare nonisolated(unsafe)) was a third, within-scope deviation — honestly recorded, needed no ruling.
