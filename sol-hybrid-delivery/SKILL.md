---
name: sol-hybrid-delivery
description: Quality-first orchestration for a GPT-5.6 Sol primary agent that may complete work directly or delegate one bounded local implementation wave to GPT-5.6 Luna and/or Terra. Use only when the user explicitly invokes $sol-hybrid-delivery or explicitly requests Sol-led Luna/Terra subagent execution for an authorized coding task. Supports plan-only routing and end-to-end local implementation. Do not trigger for generic coding requests, pure questions, reviews, or tasks that do not authorize implementation.
---

# Sol Hybrid Delivery v1.0

Optimize in this order: accepted behavior and safety, elapsed delivery time, then tokens. Treat delegation as an optional tactic. Never delegate merely to exercise a model.

Read this file once and identify `v1.0` in the first progress update. Read `references/audit-schema.md` before an implementation decision. Read `references/model-routing.md` only when considering delegation. Read `references/usage.md` only for invocation or troubleshooting.

## Respect mode and authority

- For Plan mode or a plan-only request, inspect read-only state, return one route card and at most two frozen packets, then stop. Do not emit runtime markers, spawn, edit, run broad tests, or change external state.
- For an authorized build, fix, refactor, migration, or test task, continue through safe local edits and non-destructive validation without routine confirmation.
- Ask once only for genuinely new authority: destructive work, external writes, commit/push, deployment, service or device changes, credentials, purchases, robot motion, CAN writes, or material scope expansion. Ask for a missing product decision only when it changes behavior.
- Treat a change from Luna or Terra back to Sol as internal orchestration. Never ask the user to authorize model fallback.
- Run this workflow only with Sol as the primary agent. Otherwise report the mismatch rather than pretending the split is active.

## Start one milestone

Before task-scoped tool calls, emit the `start` marker from `references/audit-schema.md` with a unique milestone ID. Use one batched orientation pass. Within eight parent tool calls, read only repository instructions, exact status/diff, relevant paths, the authoritative oracle, and the latest completed source-task result once when needed.

Record a compact authority ledger and route card:

```text
Outcome and authoritative oracle:
Current authority boundary:
Direct Sol baseline and source:
Route: DIRECT_SOL | DELEGATE_ONE | DELEGATE_TWO
Profiles and exclusive write leases:
Expected critical-path gain:
```

Emit the matching `decision` marker before spawning or writing implementation code.

## Choose the route

Use `DIRECT_SOL` by default. Keep work with Sol when it is small, tightly integrated, semantically unresolved, already compacted, dominated by live/shared state, cross-repository, deployment/hardware-facing, or likely to make Sol rediscover and rewrite the same solution.

Delegate only when all conditions hold:

1. A pre-existing test, schema/type, captured payload, golden fixture, or explicit behavior contract independently defines acceptance.
2. Repository identity, exact write lease, expected diff, one targeted check, and stop conditions are known.
3. The child can own its implementation without architecture or product decisions.
4. Sol preparation plus review is materially cheaper than direct implementation.
5. The packet changes local repository files or isolated fixtures, not live services, real databases, credentials, ports, deployments, browsers, devices, formal evidence state, or shared mutable infrastructure.

Choose the smallest suitable profile:

- `luna_fast` (`low`): exact, repetitive mechanical edits with deterministic output.
- `luna_executor` (`medium`): repeatable bounded implementation with frozen semantics and a strong oracle.
- `terra_fast` (`low`): small low-risk edits that still need modest judgment.
- `terra_executor` (`medium`): default for bounded logic, bug fixes, tests, and local refactors.

Do not use scout or deep profiles in this Skill. Sol owns discovery and difficult reasoning. Do not run availability preflights.

Use `DELEGATE_TWO` only when both packets independently justify delegation, share no files or mutable resources, and conservatively reduce the critical path by at least 30%. A Luna/Terra mixed wave is preferred when one packet is mechanical and the other logic-bearing. Two agents must not share ancestors with overlapping writes, interfaces, schemas, fixtures, manifests, lockfiles, snapshots, generators, formatters, caches, build outputs, ports, commands, or final acceptance paths. Serialize any dependency or doubt.

## Freeze and run one wave

Keep each packet under 200 words:

```text
Accepted outcome and existing oracle:
Repository identity and exact cwd:
Exclusive write lease:
Frozen interfaces and required behavior:
Non-goals and expected diff:
One targeted validation:
Reject and return conditions:
```

State that other agents share the workspace and must not overwrite or revert their work. Spawn only the named profile with `fork_turns="none"`; omit explicit model and reasoning overrides; keep every child a leaf worker. Start at most two write agents in one wave and at most two child sessions for the milestone. Never use `followup_task`.

While children run, let Sol prepare independent acceptance or work outside every lease. Do not duplicate their exploration or implementation. A dispatch/model failure, packet rejection, lease expansion, or failed implementation closes delegation for that packet; record it once and let Sol finish within existing authority. Do not start a replacement child.

## Review and finish

Inspect actual changed paths and diffs. Reject any lease breach without discarding user or agent work. Run one independent high-signal check against the frozen oracle. Do not repeat an unchanged broad gate; after a relevant correction, allow at most one final broad rerun.

Let Sol automatically make any required in-scope correction. Record any semantic rescue or fallback as a delegation loss, while reporting the final task quality separately. A completed task can therefore be `qualityOutcome=PASS` and `delegationOutcome=LOSS`.

Emit the `end` marker from `references/audit-schema.md`. Run `scripts/audit-session-usage.ps1` with the parent, all child session IDs, and any comparable Direct Sol baseline. Report the calculated two-axis result when it differs from the declaration.

Never claim savings from agent count, cached tokens, green tests alone, or an already-solved repository state. A win requires comparable measured evidence.
