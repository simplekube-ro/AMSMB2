---
name: Recurring findings at the OpenSpec review gate
description: The classes of gap that keep appearing in this project's proposals — check these first
type: feedback
---

Check these five things first on any `/opsx:propose` review in this repo; each has been a real
condition on more than one change.

1. **Delta-spec completeness.** A change that edits a doc governed by a capability needs a MODIFIED
   delta for that capability, and the delta must be a *faithful full copy* of the requirement with
   only the intended edits (diff it word-by-word — `diff <(tr ' ' '\n' <main) <(tr ' ' '\n' <delta)`).
   `api-reference` has two requirements that both enumerate things ("All public types documented"
   and "Error documentation"); changes routinely update only the first.
2. **Untested production wiring.** Scripted-seam tests inject state past the real translation code
   (`mapState`, verify blocks, `NWParameters` construction). Ask what unit-tests the *production*
   branch; if nothing can, require a spec NOTE saying "code inspection + interop gate".
3. **Overclaiming spec prose.** Requirement bodies say "on every path" where the machinery only
   guarantees it once a driver was started. Check the requirement text against the scenario, and
   against the transport's actual test assertions.
4. **Refactor-invariant collisions.** Factoring a helper out of `SMB2Client.connect` regularly
   collides with an invariant already documented in a doc comment there (e.g. "`parseSeamEndpoint`
   is invoked exactly once"). Grep the doc comment before endorsing an extraction.
5. **Swift 6 Sendability of new payloads.** Any new type captured in an escaping C/Network callback
   block (verify blocks, C trampolines) must be explicitly `@unchecked Sendable`; proposals describe
   the lock but omit the conformance.

**Why:** these are the gaps that survive an author's own read-through and turn into archive drift or
a failed build at apply time.
**How to apply:** run them as a checklist before writing the verdict; each one maps to a concrete,
citable condition.
