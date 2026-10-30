---
name: slices
description: |
  Plan a multi-step task as numbered slices and run the independent ones on subagents, with
  this session as the orchestrator. Use when a task splits into three or more slices and at
  least two of them are large and touch separate files. Skip it for small or sequential work.
---

# Slices

The orchestrator plans, dispatches, reviews and merges. Subagents do one slice each and start with no context, so each one costs a full cold start.

## Plan

1. Read the project instructions and the code the task touches before you plan.
2. Write the slices as a numbered list. For each one, list the files it touches, the slices it depends on, and how you will check it.
3. Mark a slice independent when it depends on no unfinished slice and shares no file with another slice in the same wave.
4. Show the plan and the waves to the user before dispatching.

## Dispatch

- Do the dependent and small slices yourself. Send only the independent, large ones to subagents.
- Start each subagent with `isolation: "worktree"`, so parallel edits never touch the same checkout.
- The `agent-cap` hook blocks any start past the session cap (`STYLE_AGENTS_MAX_SUBAGENTS`, default 3). When it blocks, wait for a subagent to finish or do the slice yourself. Do not retry in a loop.
- Give every subagent a prompt that stands alone:
  - the goal of the slice and the files it may change
  - the project's check commands, and the rule that they must pass before it reports
  - no commits, no pushes, and no edits outside its files
  - a report of the files it changed, the check output, and anything it could not finish

## Merge

1. Read each subagent's diff before you take it. A diff you did not read does not go in.
2. Merge one worktree at a time, then run the full check loop on the merged tree.
3. If a slice fails its checks, fix it yourself or send it back with the failure output. Do not merge it broken.
4. After each slice, report progress as `Slice N/M done` with what is left.

Commits follow the Commits rules in `AGENTS.md`: the orchestrator stages, proposes a message, and waits for approval.
