# Hybrid delivery audit schema v1

Emit single-line HTML comments in assistant messages. Plan-only work emits no markers. An implementation milestone uses exactly one `start`, `decision`, and `end` with the same unique `milestoneId`.

## Start

```text
<!-- SOL_HYBRID_DELIVERY_V1 {"event":"start","version":"1.0","milestoneId":"MILESTONE-ID"} -->
```

## Decision

Emit after no more than eight parent tool calls and before any implementation write or child spawn.

```text
<!-- SOL_HYBRID_DELIVERY_V1 {"event":"decision","version":"1.0","milestoneId":"MILESTONE-ID","route":"DELEGATE_ONE","plannedProfiles":["terra_executor"],"oracle":"tests/parser_regression","baselineSource":"estimate","baselineSessionId":"","directSolMinutesLow":30,"directSolMinutesHigh":45,"coordinationMinutesEstimate":6} -->
```

Fields:

- `route`: `DIRECT_SOL`, `DELEGATE_ONE`, or `DELEGATE_TWO`.
- `plannedProfiles`: zero, one, or two named profiles matching the route.
- `oracle`: a pre-existing acceptance identifier; use `task-contract` for Direct Sol only when no stronger oracle exists.
- `baselineSource`: `estimate`, `historical`, or `measured`.
- `baselineSessionId`: required for `historical` or `measured`, otherwise empty.
- `directSolMinutesLow` and `directSolMinutesHigh`: conservative baseline range.
- `coordinationMinutesEstimate`: Sol preparation plus review estimate.

Only a completed, comparable baseline session with the same Sol model and reasoning effort, no subagent starts, and measured duration inside the declared range can prove a delegation win. Estimates can route work but cannot prove savings.

## End

```text
<!-- SOL_HYBRID_DELIVERY_V1 {"event":"end","version":"1.0","milestoneId":"MILESTONE-ID","qualityOutcome":"PASS","delegationOutcome":"NEUTRAL","oraclePassed":true,"evidenceComplete":true,"childSessionIds":["CHILD-ID"],"solFallback":false,"solSemanticRescue":false,"leaseBreach":false,"coordinationMinutesActual":6,"reworkMinutes":0,"avoidableInvocationFailuresActual":0,"duplicateAuthorityRequests":0,"broadGateRunsActual":1,"repeatedUnchangedBroadGate":false} -->
```

`qualityOutcome` is `PASS`, `PARTIAL`, or `FAIL`. `delegationOutcome` is `NOT_USED`, `WIN`, `NEUTRAL`, or `LOSS`.

Record every child session ID. Count a switch from a failed/rejected child to Sol as `solFallback=true`; count Sol changing delegated behavior or substantially reimplementing the packet as `solSemanticRescue=true`. Do not treat either as a task blocker.

## Calculated outcomes

Quality is independent of orchestration:

- `PASS`: the oracle passes and required evidence is complete.
- `PARTIAL`: useful implementation or evidence exists, but acceptance is incomplete.
- `FAIL`: the accepted outcome was not achieved.

Direct Sol produces `NOT_USED` when no child starts. Delegated work is `LOSS` when protocol/lease/model shape is invalid, quality is not `PASS`, Sol falls back or rescues semantics, repeated authority is requested, two confirmed avoidable invocation failures occur, an unchanged broad gate repeats, or a comparable baseline is exceeded materially.

Delegated work is `WIN` only when quality passes, child model/profile evidence is complete, coordination is no more than one quarter of the Direct Sol low estimate, rework is no more than five minutes, and a comparable measured/historical baseline proves at least 15% elapsed-time savings without token regression or at least 15% cost-sensitive-token savings without exceeding the elapsed high bound. Otherwise clean passing delegation is `NEUTRAL`.

Cost-sensitive tokens are uncached input plus output for the marked parent segment and completed child sessions. Preserve declared and calculated values when they disagree.
