#!/bin/bash
# TeammateIdle hook.
# Blocks a teammate from going idle until it has sent at least one
# SendMessage (marker written by record-agent-report.sh). Exit 2 keeps the
# teammate working; the stderr text tells it what is missing.
#
# Bounded on purpose: after MAX_BLOCKS refusals the teammate is allowed to
# idle anyway — a confused agent must not wedge forever. Markers older than
# 7 days are pruned opportunistically.

MAX_BLOCKS=2

input=$(cat)
agent_id=$(jq -r '.agent_id // empty' <<<"$input")
agent_id=${agent_id//[^A-Za-z0-9._-]/}
[ -z "$agent_id" ] && exit 0

dir="${CLAUDE_PROJECT_DIR:-.}/tmp/agent-reported"
mkdir -p "$dir"
find "$dir" -type f -mtime +7 -delete 2>/dev/null

# Already reported — allow idle.
[ -f "$dir/$agent_id" ] && exit 0

blocks_file="$dir/$agent_id.blocks"
blocks=$(cat "$blocks_file" 2>/dev/null)
blocks=${blocks:-0}
if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
  exit 0
fi
echo $((blocks + 1)) > "$blocks_file"

echo "Reporting Protocol: you are about to go idle without having sent any SendMessage report. Send a SendMessage to the agent that tasked you (the team lead unless instructed otherwise) summarizing: (1) outcome, (2) what was verified and how, (3) anything blocked or unresolved. Then finish." >&2
exit 2
