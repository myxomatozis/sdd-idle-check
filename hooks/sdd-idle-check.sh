#!/usr/bin/env bash
# Stop-hook guard for subagent-driven development.
#
# WHY THIS EXISTS. In an SDD run the controller dispatches a subagent, gets a result,
# and must immediately dispatch the next thing — a review, a fix round, or the next
# task. The failure mode is writing a status summary instead and ending the turn with
# a slot sitting empty. That is invisible: every individual message looks productive.
#
# WHAT IT DOES. On Stop, find the SDD ledger for this repo. If it names a task that was
# dispatched and never completed, block the stop and say which one. Otherwise exit 0
# and stay out of the way.
#
# ESCAPE HATCHES, because a Stop hook that cannot be satisfied wedges the session:
#   * touch <workspace>/PAUSE          -> this plan stops blocking
#   * another session owns the run     -> silent (the transcript never names the workspace)
#   * every ledger task has a `complete` line -> nothing to block on
#   * no ledger at all                 -> not an SDD run, exit silently
#
# The hook blocks ONCE per distinct ledger state. A second consecutive stop on an
# unchanged ledger is let through — because the honest reason for a repeat stop is
# almost always "waiting on a running subagent", and a guard that argues with that
# is noise. Any real progress changes the ledger and re-arms it.

set -uo pipefail

payload=$(cat 2>/dev/null || true)

repo=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
sdd="$repo/.superpowers/sdd"
[ -d "$sdd" ] || exit 0

# Newest ledger wins: the plan currently being executed.
ledger=$(ls -t "$sdd"/*/progress.md 2>/dev/null | head -1)
[ -n "$ledger" ] || exit 0

workspace=$(dirname "$ledger")
[ -f "$workspace/PAUSE" ] && exit 0

# Whose run is it? Two sessions in one repo share the newest ledger, and blocking the session
# that is NOT executing the plan tells the wrong one to dispatch — which risks two controllers
# on one task. If this session's transcript never mentions the workspace, it is not the owner.
# Unreadable transcript, or a harness that sends no path: fall through and block as before.
transcript=$(printf '%s' "$payload" | grep -oE '"transcript_path" *: *"[^"]*"' | sed 's/.*: *"//; s/"$//')
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  grep -qF "$(basename "$workspace")" "$transcript" || exit 0
fi

# A task is outstanding when it was dispatched but never got a `complete` line.
# A ledger line may be a bullet (`- Task 3: …`) or bare (`Task 3: …`); both count. A task id
# may carry a letter suffix (`Task 1b`, a task inserted mid-plan), which is part of the id.
dispatched=$(grep -oE '^(- )?Task [0-9]+[a-z]?:' "$ledger" 2>/dev/null | grep -oE '[0-9]+[a-z]?' | sort -u)
[ -n "$dispatched" ] || exit 0

outstanding=""
for n in $dispatched; do
  if ! grep -qE "^(- )?Task $n: complete" "$ledger"; then
    outstanding="${outstanding:+$outstanding, }$n"
  fi
done
[ -n "$outstanding" ] || exit 0

# Anti-wedge: if the ledger has not changed since the last two blocks, let it through.
state=$(md5 -q "$ledger" 2>/dev/null || md5sum "$ledger" 2>/dev/null | cut -d' ' -f1)
stamp="$workspace/.idle-check-state"
prev_state=""; prev_count=0
if [ -f "$stamp" ]; then
  prev_state=$(head -1 "$stamp")
  prev_count=$(sed -n '2p' "$stamp")
  [ -n "$prev_count" ] || prev_count=0
fi
if [ "$state" = "$prev_state" ]; then
  count=$((prev_count + 1))
else
  count=1
fi
printf '%s\n%s\n' "$state" "$count" > "$stamp"

if [ "$count" -ge 2 ]; then
  exit 0
fi

plan=$(head -1 "$ledger" | sed 's/^# SDD ledger — plan: //')
printf '{"decision":"block","reason":"SDD run still has outstanding work: task(s) %s in %s have a dispatch line but no `Task N: complete` line.\\n\\nDo not end the turn on a status summary. Dispatch the next thing now — the task review, the fix round, or the next task. If a subagent is still running, reply with one line beginning `Waiting:` naming it, and stop. This will not fire again until the ledger changes.\\n\\nPlan: %s\\nLedger: %s\\nTo silence for this plan: touch %s/PAUSE"}\n' \
  "$outstanding" "$(basename "$workspace")" "$plan" "$ledger" "$workspace"
