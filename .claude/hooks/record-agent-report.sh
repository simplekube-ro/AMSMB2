#!/bin/bash
# PostToolUse hook (matcher: SendMessage).
# Records that an agent sent a SendMessage this session, so
# teammate-report-gate.sh will let it go idle without blocking.
# Fires in the main loop too (no agent_id) — that case is a no-op.

input=$(cat)
agent_id=$(jq -r '.agent_id // empty' <<<"$input")
agent_id=${agent_id//[^A-Za-z0-9._-]/}
[ -z "$agent_id" ] && exit 0

dir="${CLAUDE_PROJECT_DIR:-.}/tmp/agent-reported"
mkdir -p "$dir"
touch "$dir/$agent_id"
exit 0
