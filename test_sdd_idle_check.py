#!/usr/bin/env python3
"""Run: python3 test_sdd_idle_check.py — fails loudly if the guard drifts."""
import json, pathlib, shutil, subprocess, sys, tempfile

HOOK = str(pathlib.Path(__file__).parent / "hooks" / "sdd-idle-check.sh")
LEDGER = "# SDD ledger — plan: docs/plans/a-plan.md\n\n"


def call(cwd, payload="{}"):
    p = subprocess.run(["bash", HOOK], cwd=cwd, input=payload, capture_output=True, text=True)
    assert p.returncode == 0, f"guard must never fail the stop: {p.returncode} {p.stderr}"
    return p.stdout.strip()


def blocks(cwd, payload="{}"):
    out = call(cwd, payload)
    if not out:
        return None
    payload = json.loads(out)
    assert payload["decision"] == "block", payload
    return payload["reason"]


def repo_with(ledger_body, name="a-plan"):
    repo = tempfile.mkdtemp()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    ws = pathlib.Path(repo) / ".superpowers" / "sdd" / name
    ws.mkdir(parents=True)
    (ws / "progress.md").write_text(LEDGER + ledger_body)
    return repo, ws


# Not a repo, and a repo with no SDD run: silent.
assert call(tempfile.mkdtemp()) == ""
plain = tempfile.mkdtemp()
subprocess.run(["git", "init", "-q"], cwd=plain, check=True)
assert call(plain) == ""

# Every task complete: silent.
repo, _ = repo_with("Task 1: dispatched\nTask 1: complete\n")
assert blocks(repo) is None

# A dispatched task with no completion: blocked, and named.
repo, ws = repo_with("Task 1: dispatched\nTask 1: complete\nTask 2: dispatched\n")
reason = blocks(repo)
assert reason and "task(s) 2" in reason, reason
assert "a-plan" in reason and "PAUSE" in reason, reason

# Blocks once. A second stop on the same ledger is let through, then re-arms on change.
assert blocks(repo) is None, "must not block twice on an unchanged ledger"
(ws / "progress.md").write_text(LEDGER + "Task 1: dispatched\nTask 3: dispatched\n")
assert blocks(repo) is not None, "a changed ledger must re-arm the guard"

# PAUSE silences the plan.
repo, ws = repo_with("Task 2: dispatched\n")
(ws / "PAUSE").touch()
assert blocks(repo) is None

# Bullet form and a letter-suffixed task id both count.
repo, _ = repo_with("- Task 1: dispatched\n- Task 1: complete\n- Task 1b: dispatched\n")
reason = blocks(repo)
assert reason and "1b" in reason, reason

# A task id is not matched by a prefix of another (Task 1 complete != Task 12 complete).
repo, _ = repo_with("Task 12: dispatched\nTask 1: complete\n")
reason = blocks(repo)
assert reason and "12" in reason, reason

# With two runs in one repo, the newest ledger is the one judged.
repo, ws = repo_with("Task 9: dispatched\n", name="old-plan")
newer = pathlib.Path(repo) / ".superpowers" / "sdd" / "new-plan"
newer.mkdir(parents=True)
(newer / "progress.md").write_text(LEDGER + "Task 1: dispatched\nTask 1: complete\n")
assert blocks(repo) is None, "the newest ledger is complete, so nothing should block"

# Ownership: a session whose transcript never names the workspace is not the one executing it.
repo, ws = repo_with("Task 2: dispatched\n", name="owned-plan")
mine = pathlib.Path(tempfile.mkdtemp()) / "mine.jsonl"
mine.write_text('{"text": "working on .superpowers/sdd/owned-plan/progress.md"}\n')
theirs = pathlib.Path(tempfile.mkdtemp()) / "theirs.jsonl"
theirs.write_text('{"text": "packaging a plugin, nothing to do with that run"}\n')

assert blocks(repo, json.dumps({"transcript_path": str(theirs)})) is None, \
    "another session's run must not block this one"
(ws / ".idle-check-state").unlink(missing_ok=True)
assert blocks(repo, json.dumps({"transcript_path": str(mine)})) is not None, \
    "the owning session must still be blocked"
(ws / ".idle-check-state").unlink(missing_ok=True)
assert blocks(repo, json.dumps({"transcript_path": "/nonexistent"})) is not None, \
    "an unreadable transcript must fall back to blocking, not silently disable the guard"

print("ok")
