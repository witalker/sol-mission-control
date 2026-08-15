# Model routing

Use this reference only when the milestone may benefit from delegation.

## Route matrix

| Work shape | Route | Profile | Reason |
| --- | --- | --- | --- |
| Small, tightly integrated, ambiguous, live/shared, or safety/deployment-facing | Direct Sol | none | Coordination cannot improve the critical path safely. |
| Many exact substitutions, generated mappings, fixture normalization, deterministic adapters | Delegate | `luna_fast` | Lowest reasoning cost for frozen mechanical work. |
| Repetitive bounded implementation with strong types/tests and no design choice | Delegate | `luna_executor` | Luna medium handles volume while the oracle constrains behavior. |
| Small low-risk change requiring modest judgment | Delegate | `terra_fast` | Terra preserves more judgment than Luna for a small packet. |
| Bounded bug fix, local refactor, tests, or edge-case logic with frozen behavior | Delegate | `terra_executor` | Balanced implementation quality and cost. |
| Difficult semantics, architecture, integration, rescue, or unclear acceptance | Direct Sol | none | Keep frontier reasoning and ownership together. |

Do not infer that Luna is preferable merely because it is cheaper. Use it only when repetition and a strong oracle dominate the packet. Do not infer that Terra is preferable merely because a task is long. Use it only when Sol can freeze the behavioral contract without solving the same implementation.

## One versus two executors

Prefer one executor. Use two only when both packets pass every admission gate and neither can observe or mutate the other's resources. Count these as conflicts:

- ancestor/descendant write paths;
- shared contracts, schemas, registries, manifests, lockfiles, fixtures, snapshots, and generated artifacts;
- repository-wide formatters, generators, migrations, build caches, databases, ports, or services;
- one packet consuming another packet's output;
- one final end-to-end journey needed to accept both.

Route two independent mechanical packets to two Luna profiles only when each is large enough to justify coordination. Route two independent logic packets to Terra only when their interfaces are already frozen. Prefer a mixed Luna/Terra wave when the mechanical and logic packets are genuinely separate.

Require all of the following before `DELEGATE_TWO`:

1. Exclusive leases can be written without globs or ambiguous ancestors.
2. Each packet has its own targeted validation.
3. Either packet can fail without invalidating the other.
4. Sol review does not need a shared broad setup.
5. Conservative wall-clock gain is at least 30% after preparation and review.

## Scenario checks

- Rename 80 fixture keys from an approved mapping: `luna_fast`.
- Implement three independent schema adapters against golden fixtures: `luna_executor`, possibly two only if adapter directories and checks are disjoint.
- Fix a parser edge case with an existing regression test: `terra_executor`.
- Add validation across model, service, and UI layers: Direct Sol unless the layers expose frozen independent packets.
- Diagnose a flaky integration test: Direct Sol; the uncertainty is the work.
- Modify a running service, production database, browser flow, robot, or CAN behavior: Direct Sol with the real authority gate; do not delegate the live operation.
- Apply one mechanical migration while separately fixing an unrelated tested algorithm: mixed `luna_fast` plus `terra_executor` only with exclusive leases and independent checks.
- Retry a failed child through another model: prohibited; Sol finishes the packet.
