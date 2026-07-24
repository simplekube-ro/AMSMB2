#!/usr/bin/env python3
"""PreToolUse gate: block `openspec instructions apply` until the change's
proposal.md carries an approved `## Review` section (project-architect),
matching the mandatory review gate in CLAUDE.md.

This is the deterministic backstop for the review gate. This hook makes the
apply path non-bypassable under Claude Code regardless of which entrypoint
(skill, slash command) is used.

Contract: exit 0 = allow, exit 2 = block (stderr is shown to the model).
Fails OPEN (exit 0) on anything it cannot evaluate, so a hook bug never wedges
unrelated Bash calls — but it never fails *silently*: it prints why to stderr.
"""
import json
import os
import re
import sys

# The unfilled template placeholder. Its presence means the verdict line was
# never replaced with a real verdict, so the gate has not actually been run.
PLACEHOLDER = "APPROVED / APPROVED WITH CONDITIONS / NEEDS REVISION"


def allow(note: str = "") -> None:
    if note:
        print(f"[openspec-review-gate] {note}", file=sys.stderr)
    sys.exit(0)


def block(reason: str) -> None:
    print(reason, file=sys.stderr)
    sys.exit(2)


def main() -> None:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        allow("could not parse hook payload; allowing")

    if payload.get("tool_name") != "Bash":
        sys.exit(0)

    command = (payload.get("tool_input") or {}).get("command", "")
    if not command:
        sys.exit(0)

    # Only gate the apply-instructions chokepoint. Match `openspec ... instructions
    # ... apply` (artifact may sit before or after flags).
    if not re.search(r"\bopenspec\b.+\binstructions\b.+\bapply\b", command):
        sys.exit(0)

    # Extract the change name: --change NAME / --change=NAME / --change "NAME".
    m = re.search(r"--change(?:=|\s+)(['\"]?)([^'\"\s]+)\1", command)
    if not m:
        allow("`openspec instructions apply` without --change; cannot identify "
              "the proposal, allowing")
    change = m.group(2)

    root = os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()
    proposal = os.path.join(root, "openspec", "changes", change, "proposal.md")
    if not os.path.isfile(proposal):
        allow(f"no proposal at {proposal}; allowing (non-standard layout or schema)")

    try:
        with open(proposal, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        allow(f"could not read {proposal} ({exc}); allowing")

    # Isolate the `## Review` section (heading to next `## ` or EOF).
    heading = re.search(r"(?mi)^##\s+Review\b", text)
    deny_prefix = (
        f"BLOCKED: change '{change}' has not passed the mandatory review gate.\n"
    )
    deny_suffix = (
        "\nThe proposal must be reviewed by the project-architect agent, with "
        "the verdict recorded in a `## Review` section of proposal.md, before "
        "implementation can begin. Re-run /opsx:propose to trigger the gate, "
        "or dispatch the project-architect review agent and record its "
        "verdict. If the user explicitly chooses to skip the review, they can "
        "re-issue the apply with that instruction."
    )

    if not heading:
        block(deny_prefix + "No `## Review` section was found in proposal.md."
              + deny_suffix)

    section = text[heading.start():]
    nxt = re.search(r"(?m)^##\s+(?!Review\b)", section[1:])
    if nxt:
        section = section[: nxt.start() + 1]

    if PLACEHOLDER in section:
        block(deny_prefix + "The `## Review` section still contains the unfilled "
              "verdict placeholder, so the review has not actually been run."
              + deny_suffix)

    if re.search(r"NEEDS\s+REVISION", section, re.IGNORECASE):
        block(deny_prefix + "The `## Review` section records a NEEDS REVISION "
              "verdict; the artifacts must be revised and re-reviewed first."
              + deny_suffix)

    if not re.search(r"\bAPPROVED\b", section, re.IGNORECASE):
        block(deny_prefix + "The `## Review` section does not record an APPROVED "
              "verdict." + deny_suffix)

    # Approved (or approved-with-conditions) and no outstanding revision: allow.
    sys.exit(0)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never wedge unrelated Bash on a hook bug
        print(f"[openspec-review-gate] internal error, allowing: {exc}",
              file=sys.stderr)
        sys.exit(0)
