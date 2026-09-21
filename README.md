# sdd-idle-check

A Claude Code plugin. One `Stop` hook for subagent-driven development: if the run's ledger names
a task that was dispatched and never completed, the turn does not end.

The failure it catches is specific. In an SDD run the controller dispatches a subagent, gets a
result, and must immediately dispatch the next thing — the review, the fix round, or the next
task. The failure mode is writing a status summary instead and ending the turn with a slot
sitting empty. That is invisible: every individual message looks productive.

## What it reads

The newest `.superpowers/sdd/*/progress.md` under the repo root — the ledger format from
Superpowers' `subagent-driven-development` skill. A task is outstanding when the ledger has a
`Task N: dispatched` line and no `Task N: complete` line. Bullets (`- Task 3: …`) and
letter-suffixed ids (`Task 1b`, a task inserted mid-plan) both count.

**Your controller has to write those lines.** No ledger, no lines, no guard — the hook exits
silently rather than guessing.

## Install

```
/plugin marketplace add myxomatozis/sdd-idle-check
/plugin install sdd-idle-check@sdd-idle-check
```

## Escape hatches

A `Stop` hook that cannot be satisfied wedges the session, so there are four ways out:

| | |
|---|---|
| `touch <workspace>/PAUSE` | This plan stops blocking, permanently. |
| Every task has a `complete` line | Nothing to block on. |
| Second stop on an unchanged ledger | Let through. The honest reason for a repeat stop is almost always "waiting on a running subagent", and a guard that argues with that is noise. Real progress changes the ledger and re-arms it. |
| Another session owns the run | Silent. Two sessions in one repo share the newest ledger; blocking the one that is *not* executing the plan tells the wrong controller to dispatch, which risks two controllers on one task. Ownership is decided by whether this session's transcript ever names the workspace. |

The guard never fails a stop — on any error it exits 0 and stays out of the way.

## Check

`python3 test_sdd_idle_check.py`
