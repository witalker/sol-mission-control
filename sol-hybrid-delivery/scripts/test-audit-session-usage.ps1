[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$auditScript = Join-Path $PSScriptRoot 'audit-session-usage.ps1'
if (-not (Test-Path -LiteralPath $auditScript -PathType Leaf)) {
    throw "Audit script not found: $auditScript"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function New-UsageEvent {
    param([string]$Timestamp, [long]$InputTokens, [long]$CachedInputTokens, [long]$OutputTokens, [long]$TotalTokens)
    [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = [ordered]@{
            type = 'token_count'
            info = [ordered]@{
                total_token_usage = [ordered]@{
                    input_tokens = $InputTokens
                    cached_input_tokens = $CachedInputTokens
                    output_tokens = $OutputTokens
                    reasoning_output_tokens = 0
                    total_tokens = $TotalTokens
                }
            }
        }
    }
}

function New-MarkerEvent {
    param([string]$Timestamp, [string]$Marker)
    [ordered]@{
        timestamp = $Timestamp
        type = 'response_item'
        payload = [ordered]@{
            type = 'message'
            role = 'assistant'
            phase = 'commentary'
            content = @([ordered]@{ type = 'output_text'; text = $Marker })
        }
    }
}

function New-ToolCallEvent {
    param([string]$Timestamp, [string]$CallId, [string]$Name, [string]$CallInput, [switch]$FunctionCall)
    $payload = [ordered]@{
        type = if ($FunctionCall) { 'function_call' } else { 'custom_tool_call' }
        call_id = $CallId
        name = $Name
    }
    if ($FunctionCall) { $payload.arguments = $CallInput } else { $payload.input = $CallInput }
    [ordered]@{ timestamp = $Timestamp; type = 'response_item'; payload = $payload }
}

function New-ToolOutputEvent {
    param([string]$Timestamp, [string]$CallId, [string]$Text)
    [ordered]@{
        timestamp = $Timestamp
        type = 'response_item'
        payload = [ordered]@{
            type = 'custom_tool_call_output'
            call_id = $CallId
            output = @([ordered]@{ type = 'input_text'; text = $Text })
        }
    }
}

function Write-JsonLines {
    param([string]$Path, [object[]]$Events)
    $lines = @($Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 })
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

function New-ChildSession {
    param(
        [string]$Timestamp,
        [string]$Model,
        [string]$Effort,
        [long]$InputTokens = 1000,
        [long]$CachedInputTokens = 200,
        [long]$OutputTokens = 200,
        [long]$DurationMs = 600000
    )
    @(
        [ordered]@{
            timestamp = $Timestamp
            type = 'turn_context'
            payload = [ordered]@{
                model = $Model
                collaboration_mode = [ordered]@{ settings = [ordered]@{ reasoning_effort = $Effort } }
            }
        },
        (New-UsageEvent ([DateTimeOffset]::Parse($Timestamp).AddSeconds(1).ToString('o')) $InputTokens $CachedInputTokens $OutputTokens ($InputTokens + $OutputTokens)),
        [ordered]@{
            timestamp = [DateTimeOffset]::Parse($Timestamp).AddMinutes(10).ToString('o')
            type = 'event_msg'
            payload = [ordered]@{ type = 'task_complete'; duration_ms = $DurationMs }
        }
    )
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempBase ('sol-hybrid-audit-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot).TrimEnd('\')
if (-not $resolvedTestRoot.StartsWith($tempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe test root: $resolvedTestRoot"
}

$sessionDirectory = Join-Path $resolvedTestRoot 'sessions\2026\01\01'
$parentId = '11111111-1111-1111-1111-111111111111'
$lunaId = '22222222-2222-2222-2222-222222222222'
$terraId = '33333333-3333-3333-3333-333333333333'
$mixedLunaId = '44444444-4444-4444-4444-444444444444'
$mixedTerraId = '55555555-5555-5555-5555-555555555555'
$mismatchId = '66666666-6666-6666-6666-666666666666'
$baselineId = '77777777-7777-7777-7777-777777777777'
$allIds = @($parentId, $lunaId, $terraId, $mixedLunaId, $mixedTerraId, $mismatchId, $baselineId)
$paths = @{}
foreach ($id in $allIds) { $paths[$id] = Join-Path $sessionDirectory "rollout-2026-01-01T00-00-00-$id.jsonl" }

try {
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null

    $startM1 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"start","version":"1.0","milestoneId":"M1"} -->'
    $decisionM1 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"decision","version":"1.0","milestoneId":"M1","route":"DIRECT_SOL","plannedProfiles":[],"oracle":"task-contract","baselineSource":"estimate","baselineSessionId":"","directSolMinutesLow":5,"directSolMinutesHigh":10,"coordinationMinutesEstimate":0} -->'
    $endM1 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"end","version":"1.0","milestoneId":"M1","qualityOutcome":"PASS","delegationOutcome":"NOT_USED","oraclePassed":true,"evidenceComplete":true,"childSessionIds":[],"solFallback":false,"solSemanticRescue":false,"leaseBreach":false,"coordinationMinutesActual":0,"reworkMinutes":0,"avoidableInvocationFailuresActual":0,"duplicateAuthorityRequests":0,"broadGateRunsActual":1,"repeatedUnchangedBroadGate":false} -->'

    $startM2 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"start","version":"1.0","milestoneId":"M2"} -->'
    $decisionM2 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"decision","version":"1.0","milestoneId":"M2","route":"DELEGATE_ONE","plannedProfiles":["luna_fast"],"oracle":"golden-map","baselineSource":"historical","baselineSessionId":"77777777-7777-7777-7777-777777777777","directSolMinutesLow":50,"directSolMinutesHigh":70,"coordinationMinutesEstimate":5} -->'
    $endM2 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"end","version":"1.0","milestoneId":"M2","qualityOutcome":"PASS","delegationOutcome":"WIN","oraclePassed":true,"evidenceComplete":true,"childSessionIds":["22222222-2222-2222-2222-222222222222"],"solFallback":false,"solSemanticRescue":false,"leaseBreach":false,"coordinationMinutesActual":5,"reworkMinutes":0,"avoidableInvocationFailuresActual":0,"duplicateAuthorityRequests":0,"broadGateRunsActual":1,"repeatedUnchangedBroadGate":false} -->'

    $startM3 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"start","version":"1.0","milestoneId":"M3"} -->'
    $decisionM3 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"decision","version":"1.0","milestoneId":"M3","route":"DELEGATE_ONE","plannedProfiles":["terra_executor"],"oracle":"parser-regression","baselineSource":"estimate","baselineSessionId":"","directSolMinutesLow":20,"directSolMinutesHigh":35,"coordinationMinutesEstimate":4} -->'
    $endM3 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"end","version":"1.0","milestoneId":"M3","qualityOutcome":"PASS","delegationOutcome":"NEUTRAL","oraclePassed":true,"evidenceComplete":true,"childSessionIds":["33333333-3333-3333-3333-333333333333"],"solFallback":false,"solSemanticRescue":false,"leaseBreach":false,"coordinationMinutesActual":4,"reworkMinutes":0,"avoidableInvocationFailuresActual":0,"duplicateAuthorityRequests":0,"broadGateRunsActual":1,"repeatedUnchangedBroadGate":false} -->'

    $startM4 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"start","version":"1.0","milestoneId":"M4"} -->'
    $decisionM4 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"decision","version":"1.0","milestoneId":"M4","route":"DELEGATE_TWO","plannedProfiles":["luna_fast","terra_executor"],"oracle":"independent-checks","baselineSource":"estimate","baselineSessionId":"","directSolMinutesLow":40,"directSolMinutesHigh":60,"coordinationMinutesEstimate":6} -->'
    $endM4 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"end","version":"1.0","milestoneId":"M4","qualityOutcome":"PASS","delegationOutcome":"LOSS","oraclePassed":true,"evidenceComplete":true,"childSessionIds":["44444444-4444-4444-4444-444444444444","55555555-5555-5555-5555-555555555555"],"solFallback":true,"solSemanticRescue":false,"leaseBreach":false,"coordinationMinutesActual":9,"reworkMinutes":7,"avoidableInvocationFailuresActual":0,"duplicateAuthorityRequests":0,"broadGateRunsActual":1,"repeatedUnchangedBroadGate":false} -->'

    $startM5 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"start","version":"1.0","milestoneId":"M5"} -->'
    $decisionM5 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"decision","version":"1.0","milestoneId":"M5","route":"DELEGATE_ONE","plannedProfiles":["luna_fast"],"oracle":"golden-map","baselineSource":"estimate","baselineSessionId":"","directSolMinutesLow":20,"directSolMinutesHigh":30,"coordinationMinutesEstimate":3} -->'
    $endM5 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"end","version":"1.0","milestoneId":"M5","qualityOutcome":"PASS","delegationOutcome":"LOSS","oraclePassed":true,"evidenceComplete":true,"childSessionIds":["66666666-6666-6666-6666-666666666666"],"solFallback":false,"solSemanticRescue":false,"leaseBreach":false,"coordinationMinutesActual":3,"reworkMinutes":0,"avoidableInvocationFailuresActual":0,"duplicateAuthorityRequests":0,"broadGateRunsActual":1,"repeatedUnchangedBroadGate":false} -->'

    $startM6 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"start","version":"1.0","milestoneId":"M6"} -->'
    $decisionM6 = '<!-- SOL_HYBRID_DELIVERY_V1 {"event":"decision","version":"1.0","milestoneId":"M6","route":"DIRECT_SOL","plannedProfiles":[],"oracle":"task-contract","baselineSource":"estimate","baselineSessionId":"","directSolMinutesLow":5,"directSolMinutesHigh":10,"coordinationMinutesEstimate":0} -->'

    $parentEvents = @(
        [ordered]@{ timestamp = '2026-01-01T00:00:00Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol'; collaboration_mode = [ordered]@{ settings = [ordered]@{ reasoning_effort = 'max' } } } },
        (New-UsageEvent '2026-01-01T00:00:01Z' 0 0 0 0),
        (New-MarkerEvent '2026-01-01T00:00:10Z' $startM1),
        (New-MarkerEvent '2026-01-01T00:00:11Z' $decisionM1),
        (New-MarkerEvent '2026-01-01T00:05:00Z' $endM1),
        (New-UsageEvent '2026-01-01T00:05:01Z' 100 20 20 120),

        (New-MarkerEvent '2026-01-01T01:00:00Z' $startM2),
        (New-MarkerEvent '2026-01-01T01:00:05Z' $decisionM2),
        (New-ToolCallEvent '2026-01-01T01:00:10Z' 'm2-success' 'exec' 'read fixture'),
        (New-ToolOutputEvent '2026-01-01T01:00:11Z' 'm2-success' 'Script completed; fixture contains SyntaxError: literal text'),
        (New-ToolCallEvent '2026-01-01T01:00:12Z' 'm2-failure' 'exec' 'broken('),
        (New-ToolOutputEvent '2026-01-01T01:00:13Z' 'm2-failure' 'Script failed; SyntaxError: missing ) after argument list'),
        (New-ToolCallEvent '2026-01-01T01:00:15Z' 'm2-spawn' 'spawn_agent' '{"agent_type":"luna_fast","fork_turns":"none","task_name":"m2"}' -FunctionCall),
        (New-ToolOutputEvent '2026-01-01T01:00:16Z' 'm2-spawn' 'agent started'),
        (New-MarkerEvent '2026-01-01T01:30:00Z' $endM2),
        (New-UsageEvent '2026-01-01T01:30:01Z' 1100 220 220 1320),

        (New-MarkerEvent '2026-01-01T02:00:00Z' $startM3),
        (New-MarkerEvent '2026-01-01T02:00:05Z' $decisionM3),
        (New-ToolCallEvent '2026-01-01T02:00:10Z' 'm3-spawn' 'spawn_agent' '{"agent_type":"terra_executor","fork_turns":"none","task_name":"m3"}' -FunctionCall),
        (New-ToolOutputEvent '2026-01-01T02:00:11Z' 'm3-spawn' 'agent started'),
        (New-MarkerEvent '2026-01-01T02:10:00Z' $endM3),
        (New-UsageEvent '2026-01-01T02:10:01Z' 1600 320 320 1920),

        (New-MarkerEvent '2026-01-01T03:00:00Z' $startM4),
        (New-MarkerEvent '2026-01-01T03:00:05Z' $decisionM4),
        (New-ToolCallEvent '2026-01-01T03:00:10Z' 'm4-spawn-a' 'spawn_agent' '{"agent_type":"luna_fast","fork_turns":"none","task_name":"m4a"}' -FunctionCall),
        (New-ToolOutputEvent '2026-01-01T03:00:11Z' 'm4-spawn-a' 'agent started'),
        (New-ToolCallEvent '2026-01-01T03:00:12Z' 'm4-spawn-b' 'spawn_agent' '{"agent_type":"terra_executor","fork_turns":"none","task_name":"m4b"}' -FunctionCall),
        (New-ToolOutputEvent '2026-01-01T03:00:13Z' 'm4-spawn-b' 'agent started'),
        (New-MarkerEvent '2026-01-01T03:15:00Z' $endM4),
        (New-UsageEvent '2026-01-01T03:15:01Z' 2200 440 440 2640),

        (New-MarkerEvent '2026-01-01T04:00:00Z' $startM5),
        (New-MarkerEvent '2026-01-01T04:00:05Z' $decisionM5),
        (New-ToolCallEvent '2026-01-01T04:00:10Z' 'm5-spawn' 'spawn_agent' '{"agent_type":"luna_fast","fork_turns":"none","task_name":"m5"}' -FunctionCall),
        (New-ToolOutputEvent '2026-01-01T04:00:11Z' 'm5-spawn' 'agent started'),
        (New-MarkerEvent '2026-01-01T04:10:00Z' $endM5),
        (New-UsageEvent '2026-01-01T04:10:01Z' 2600 520 520 3120),

        (New-MarkerEvent '2026-01-01T05:00:00Z' $startM6),
        (New-MarkerEvent '2026-01-01T05:00:05Z' $decisionM6),
        (New-UsageEvent '2026-01-01T05:01:00Z' 2700 540 540 3240),
        [ordered]@{ timestamp = '2026-01-01T05:01:01Z'; type = 'event_msg'; payload = [ordered]@{ type = 'task_complete'; duration_ms = 18000000 } }
    )
    Write-JsonLines -Path $paths[$parentId] -Events $parentEvents

    Write-JsonLines -Path $paths[$lunaId] -Events (New-ChildSession '2026-01-01T01:00:15Z' 'gpt-5.6-luna' 'low')
    Write-JsonLines -Path $paths[$terraId] -Events (New-ChildSession '2026-01-01T02:00:10Z' 'gpt-5.6-terra' 'medium')
    Write-JsonLines -Path $paths[$mixedLunaId] -Events (New-ChildSession '2026-01-01T03:00:10Z' 'gpt-5.6-luna' 'low')
    Write-JsonLines -Path $paths[$mixedTerraId] -Events (New-ChildSession '2026-01-01T03:00:12Z' 'gpt-5.6-terra' 'medium')
    Write-JsonLines -Path $paths[$mismatchId] -Events (New-ChildSession '2026-01-01T04:00:10Z' 'gpt-5.6-terra' 'low')

    $baselineEvents = @(
        [ordered]@{ timestamp = '2026-01-01T06:00:00Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol'; collaboration_mode = [ordered]@{ settings = [ordered]@{ reasoning_effort = 'max' } } } },
        (New-UsageEvent '2026-01-01T06:59:59Z' 10000 2000 2000 12000),
        [ordered]@{ timestamp = '2026-01-01T07:00:00Z'; type = 'event_msg'; payload = [ordered]@{ type = 'task_complete'; duration_ms = 3600000 } }
    )
    Write-JsonLines -Path $paths[$baselineId] -Events $baselineEvents

    $results = @(& $auditScript -SessionId $allIds -CodexRoot $resolvedTestRoot)
    $m1 = @($results | Where-Object { $_.Kind -eq 'milestone' -and $_.MilestoneId -eq 'M1' })[0]
    $m2 = @($results | Where-Object { $_.Kind -eq 'milestone' -and $_.MilestoneId -eq 'M2' })[0]
    $m3 = @($results | Where-Object { $_.Kind -eq 'milestone' -and $_.MilestoneId -eq 'M3' })[0]
    $m4 = @($results | Where-Object { $_.Kind -eq 'milestone' -and $_.MilestoneId -eq 'M4' })[0]
    $m5 = @($results | Where-Object { $_.Kind -eq 'milestone' -and $_.MilestoneId -eq 'M5' })[0]
    $m6 = @($results | Where-Object { $_.Kind -eq 'milestone' -and $_.MilestoneId -eq 'M6' })[0]

    Assert-True ($m1.QualityOutcomeCalculated -eq 'PASS') 'Direct Sol quality passes'
    Assert-True ($m1.DelegationOutcomeCalculated -eq 'NOT_USED') 'Direct Sol reports delegation NOT_USED'
    Assert-True ($m1.DelegationShapeValid -eq $true -and $m1.SpawnCount -eq 0) 'Direct Sol has a valid zero-child shape'

    Assert-True ($m2.QualityOutcomeCalculated -eq 'PASS') 'Luna quality passes'
    if ($m2.DelegationOutcomeCalculated -ne 'WIN') { Write-Host ($m2 | Format-List * | Out-String) }
    Assert-True ($m2.DelegationOutcomeCalculated -eq 'WIN') 'Comparable Luna delegation calculates WIN'
    Assert-True ($m2.BaselineComparable -eq $true) 'Direct Sol baseline is comparable'
    Assert-True ($m2.ModelProfilesValid -eq $true) 'Luna named profile resolves to Luna low'
    Assert-True ($m2.ToolFailureCount -eq 1) 'successful output containing SyntaxError is not a failure'
    Assert-True ($m2.ConfirmedAvoidableFailureCount -eq 1) 'real syntax failure is classified once'
    Assert-True ($m2.TimeSavingsPercent -ge 15 -and $m2.TokenSavingsPercent -ge 15) 'measured gain clears the win threshold'

    Assert-True ($m3.QualityOutcomeCalculated -eq 'PASS') 'Terra quality passes'
    Assert-True ($m3.DelegationOutcomeCalculated -eq 'NEUTRAL') 'clean delegation without comparable baseline is neutral'
    Assert-True ($m3.ModelProfilesValid -eq $true) 'Terra named profile resolves to Terra medium'

    Assert-True ($m4.QualityOutcomeCalculated -eq 'PASS') 'fallback can still produce passing task quality'
    Assert-True ($m4.DelegationOutcomeCalculated -eq 'LOSS') 'fallback is a delegation loss'
    Assert-True ($m4.DelegationShapeValid -eq $true -and $m4.SpawnCount -eq 2) 'mixed two-agent wave has a valid shape'

    Assert-True ($m5.QualityOutcomeCalculated -eq 'PASS') 'model mismatch does not erase final task quality'
    Assert-True ($m5.DelegationOutcomeCalculated -eq 'LOSS') 'model/profile mismatch is a delegation loss'
    Assert-True ($m5.ModelProfilesValid -eq $false) 'model/profile mismatch is detected'

    Assert-True ($m6.QualityOutcomeCalculated -eq 'INCOMPLETE') 'missing end marker makes quality incomplete'
    Assert-True ($m6.DelegationOutcomeCalculated -eq 'INCOMPLETE') 'missing end marker makes delegation incomplete'
    Assert-True ($results.Count -ge 13) 'milestone and session rows are both returned'

    $filtered = @(& $auditScript -SessionId $allIds -CodexRoot $resolvedTestRoot -MilestoneId 'M2')
    Assert-True (@($filtered | Where-Object Kind -eq 'milestone').Count -eq 1) 'milestone filter returns one row'
    Assert-True (@($filtered | Where-Object { $_.Kind -eq 'milestone' -and $_.MilestoneId -eq 'M2' }).Count -eq 1) 'milestone filter returns M2'

    'HYBRID_AUDIT_TESTS_PASSED'
}
catch {
    Write-Host ("Audit regression failed:`n{0}`n{1}" -f $_.InvocationInfo.PositionMessage, $_.ScriptStackTrace)
    throw
}
finally {
    foreach ($path in $paths.Values) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    $directories = @(
        $sessionDirectory,
        (Split-Path -Parent $sessionDirectory),
        (Split-Path -Parent (Split-Path -Parent $sessionDirectory)),
        (Join-Path $resolvedTestRoot 'sessions'),
        $resolvedTestRoot
    )
    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        $item = Get-Item -LiteralPath $directory -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove reparse point: $directory"
        }
        if (@(Get-ChildItem -LiteralPath $directory -Force).Count -ne 0) {
            throw "Refusing to remove non-empty test directory: $directory"
        }
        Remove-Item -LiteralPath $directory -Force
    }
}
