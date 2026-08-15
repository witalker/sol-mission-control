[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('ThreadId')]
    [string[]]$SessionId,

    [string]$CodexRoot,

    [string[]]$MilestoneId
)

$ErrorActionPreference = 'Stop'
$auditVersion = '1.0'
$markerRegex = [regex]::new(
    '<!--\s*SOL_HYBRID_DELIVERY_V1\s+(?<json>\{[^\r\n]*\})\s*-->',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$allowedProfiles = @('luna_fast', 'luna_executor', 'terra_fast', 'terra_executor')
$profileSignatures = @{
    luna_fast = 'gpt-5.6-luna|low'
    luna_executor = 'gpt-5.6-luna|medium'
    terra_fast = 'gpt-5.6-terra|low'
    terra_executor = 'gpt-5.6-terra|medium'
}

if ([string]::IsNullOrWhiteSpace($CodexRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $CodexRoot = $env:CODEX_HOME
    }
    else {
        $CodexRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}

$resolvedCodexRoot = [System.IO.Path]::GetFullPath($CodexRoot)
$sessionRoot = Join-Path $resolvedCodexRoot 'sessions'
if (-not (Test-Path -LiteralPath $sessionRoot -PathType Container)) {
    throw "Codex session directory not found: $sessionRoot"
}

$normalizedSessionIds = @(
    $SessionId |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)
if ($normalizedSessionIds.Count -eq 0) {
    throw 'At least one session id is required.'
}

$milestoneFilter = @{}
foreach ($value in @($MilestoneId)) {
    foreach ($part in @($value -split ',')) {
        $normalized = $part.Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $milestoneFilter[$normalized] = $true
        }
    }
}

function Get-ObjectProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Convert-ToBooleanOrFalse {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    $parsed = $false
    if ($null -ne $Value -and [bool]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return $false
}

function Convert-ToDoubleOrNull {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = [double]0
    if ([double]::TryParse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )) {
        return $parsed
    }
    return $null
}

function Convert-ToLongOrZero {
    param([object]$Value)

    if ($null -eq $Value) {
        return [long]0
    }
    $parsed = [long]0
    if ([long]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return [long]0
}

function Convert-ArgumentsObject {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $null
        }
        try {
            return $Value | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
    return $Value
}

function Get-PayloadText {
    param([object]$Payload)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($propertyName in @('output', 'content')) {
        if ($null -eq $Payload -or -not ($Payload.PSObject.Properties.Name -contains $propertyName)) {
            continue
        }
        $value = $Payload.$propertyName
        if ($value -is [string]) {
            $parts.Add($value)
            continue
        }
        foreach ($item in @($value)) {
            if ($item -is [string]) {
                $parts.Add($item)
            }
            elseif ($null -ne $item -and $item.PSObject.Properties.Name -contains 'text') {
                $parts.Add([string]$item.text)
            }
        }
    }
    return ($parts -join [Environment]::NewLine)
}

function Read-SharedLines {
    param([Parameter(Mandatory = $true)][string]$Path)

    $shareMode = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        $shareMode
    )
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            while (-not $reader.EndOfStream) {
                $reader.ReadLine()
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-UsagePoint {
    param(
        [int]$Index,
        [object]$Usage
    )

    [pscustomobject]@{
        Index = $Index
        InputTokens = Convert-ToLongOrZero (Get-ObjectProperty $Usage 'input_tokens')
        CachedInputTokens = Convert-ToLongOrZero (Get-ObjectProperty $Usage 'cached_input_tokens')
        OutputTokens = Convert-ToLongOrZero (Get-ObjectProperty $Usage 'output_tokens')
        ReportedTotalTokens = Convert-ToLongOrZero (Get-ObjectProperty $Usage 'total_tokens')
    }
}

function Get-UsageAtOrBefore {
    param([object[]]$Points, [int]$Index)

    return @($Points | Where-Object { $_.Index -le $Index } | Select-Object -Last 1)[0]
}

function Get-UsageAtOrAfter {
    param([object[]]$Points, [int]$Index, [int]$MaximumIndex)

    $after = @(
        $Points |
            Where-Object { $_.Index -ge $Index -and $_.Index -lt $MaximumIndex } |
            Select-Object -First 1
    )
    if ($after.Count -gt 0) {
        return $after[0]
    }
    return Get-UsageAtOrBefore -Points $Points -Index ($MaximumIndex - 1)
}

function Get-UsageDelta {
    param([object]$Start, [object]$End)

    $startInput = if ($Start) { [long]$Start.InputTokens } else { [long]0 }
    $startCached = if ($Start) { [long]$Start.CachedInputTokens } else { [long]0 }
    $startOutput = if ($Start) { [long]$Start.OutputTokens } else { [long]0 }
    $startTotal = if ($Start) { [long]$Start.ReportedTotalTokens } else { [long]0 }
    $endInput = if ($End) { [long]$End.InputTokens } else { $startInput }
    $endCached = if ($End) { [long]$End.CachedInputTokens } else { $startCached }
    $endOutput = if ($End) { [long]$End.OutputTokens } else { $startOutput }
    $endTotal = if ($End) { [long]$End.ReportedTotalTokens } else { $startTotal }

    $inputDelta = [math]::Max(0, $endInput - $startInput)
    $cachedDelta = [math]::Max(0, $endCached - $startCached)
    $outputDelta = [math]::Max(0, $endOutput - $startOutput)

    [pscustomobject]@{
        InputTokens = [long]$inputDelta
        CachedInputTokens = [long]$cachedDelta
        UncachedInputEstimate = [long][math]::Max(0, $inputDelta - $cachedDelta)
        OutputTokens = [long]$outputDelta
        ReportedTotalTokens = [long][math]::Max(0, $endTotal - $startTotal)
        CostSensitiveTokens = [long]([math]::Max(0, $inputDelta - $cachedDelta) + $outputDelta)
    }
}

function Test-ActualToolFailure {
    param([object]$Payload, [string]$OutputText)

    if ((Get-ObjectProperty $Payload 'status') -eq 'failed') {
        return $true
    }
    if ((Get-ObjectProperty $Payload 'isError') -eq $true -or (Get-ObjectProperty $Payload 'is_error') -eq $true) {
        return $true
    }
    $trimmed = $OutputText.TrimStart()
    return $trimmed -match '^(?i:Script failed\b|Script error:|Tool error:|Tool failed\b)'
}

function Get-FailureCategory {
    param([string]$OutputText)

    $headLength = [math]::Min(3000, $OutputText.Length)
    $head = if ($headLength -gt 0) { $OutputText.Substring(0, $headLength) } else { '' }
    if ($head -match '(?i)ParserError|SyntaxError:|missing \) after argument list|Unexpected token|Invalid or unexpected token') { return 'syntax' }
    if ($head -match '(?i)NamedParameterNotFound|A parameter cannot be found|unknown option|unrecognized arguments|invalid option') { return 'parameter' }
    if ($head -match '(?i)DirectoryNotFound|PathNotFound|Could not find a part of the path|Cannot find path|working directory.+not found') { return 'path' }
    if ($head -match '(?i)Unknown model') { return 'model' }
    if ($head -match '(?i)Access is denied|Permission denied|os error 5') { return 'permission' }
    if ($head -match '(?i)command timed out|timed out after|operation timed out') { return 'timeout' }
    return 'other'
}

function Test-ToolName {
    param([string]$Name, [string]$Leaf)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    return $Name -match ('(^|[\._])' + [regex]::Escape($Leaf) + '$')
}

function Get-SortedSignature {
    param([object[]]$Values)

    return (@($Values | ForEach-Object { [string]$_ } | Sort-Object) -join '|')
}

function Add-Warning {
    param([System.Collections.Generic.List[string]]$List, [string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $List.Add($Message)
    }
}

$sessionMap = @{}

foreach ($id in $normalizedSessionIds) {
    if ($id -notmatch '^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
        throw "Invalid session id: $id"
    }

    $matches = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter "*-$id.jsonl")
    if ($matches.Count -eq 0) {
        throw "Session log not found for: $id"
    }
    if ($matches.Count -gt 1) {
        throw "Multiple session logs found for: $id"
    }

    $events = New-Object System.Collections.Generic.List[object]
    $usagePoints = New-Object System.Collections.Generic.List[object]
    $markers = New-Object System.Collections.Generic.List[object]
    $calls = New-Object System.Collections.Generic.List[object]
    $outputs = New-Object System.Collections.Generic.List[object]
    $callById = @{}
    $model = ''
    $reasoningEffort = ''
    $completedTurnCount = 0
    $completedDurationMs = [long]0
    $firstTimestamp = $null
    $lastTimestamp = $null
    $eventIndex = -1

    foreach ($line in Read-SharedLines -Path $matches[0].FullName) {
        try { $event = $line | ConvertFrom-Json } catch { continue }
        $eventIndex++
        $timestamp = $null
        if ($event.timestamp) {
            try {
                $timestamp = [DateTimeOffset]::Parse([string]$event.timestamp)
                if ($null -eq $firstTimestamp) { $firstTimestamp = $timestamp }
                $lastTimestamp = $timestamp
            }
            catch { $timestamp = $null }
        }
        $events.Add([pscustomobject]@{ Index = $eventIndex; Timestamp = $timestamp; Event = $event })

        if ($event.type -eq 'turn_context') {
            if ($event.payload.model) { $model = [string]$event.payload.model }
            $settings = $event.payload.collaboration_mode.settings
            if ($settings -and $settings.reasoning_effort) { $reasoningEffort = [string]$settings.reasoning_effort }
        }
        if ($event.type -eq 'event_msg') {
            if ($event.payload.type -eq 'token_count' -and $event.payload.info.total_token_usage) {
                $usagePoints.Add((New-UsagePoint -Index $eventIndex -Usage $event.payload.info.total_token_usage))
            }
            elseif ($event.payload.type -eq 'task_complete') {
                $completedTurnCount++
                $completedDurationMs += Convert-ToLongOrZero $event.payload.duration_ms
            }
        }
        if ($event.type -ne 'response_item') { continue }

        $payload = $event.payload
        if ($payload.type -eq 'message' -and $payload.role -eq 'assistant') {
            $messageText = Get-PayloadText -Payload $payload
            foreach ($match in $markerRegex.Matches($messageText)) {
                try {
                    $data = $match.Groups['json'].Value | ConvertFrom-Json
                    $markerEvent = [string](Get-ObjectProperty $data 'event' '')
                    $milestoneValue = [string](Get-ObjectProperty $data 'milestoneId' '')
                    if ($markerEvent -in @('start', 'decision', 'end') -and -not [string]::IsNullOrWhiteSpace($milestoneValue)) {
                        $markers.Add([pscustomobject]@{
                            Index = $eventIndex
                            Timestamp = $timestamp
                            Event = $markerEvent.ToLowerInvariant()
                            MilestoneId = $milestoneValue
                            Data = $data
                        })
                    }
                }
                catch { }
            }
        }
        if ($payload.type -in @('function_call', 'custom_tool_call')) {
            $rawInput = if ($payload.PSObject.Properties.Name -contains 'arguments') { $payload.arguments } else { $payload.input }
            $callId = if ($payload.call_id) { [string]$payload.call_id } else { [string]$payload.id }
            $call = [pscustomobject]@{
                Index = $eventIndex
                Timestamp = $timestamp
                CallId = $callId
                Name = [string]$payload.name
                RawInput = $rawInput
            }
            $calls.Add($call)
            if (-not [string]::IsNullOrWhiteSpace($callId)) { $callById[$callId] = $call }
        }
        elseif ($payload.type -in @('function_call_output', 'custom_tool_call_output')) {
            $callId = [string]$payload.call_id
            $outputText = Get-PayloadText -Payload $payload
            $failed = Test-ActualToolFailure -Payload $payload -OutputText $outputText
            $outputs.Add([pscustomobject]@{
                Index = $eventIndex
                Timestamp = $timestamp
                CallId = $callId
                Call = if ($callById.ContainsKey($callId)) { $callById[$callId] } else { $null }
                Failed = $failed
                Category = if ($failed) { Get-FailureCategory -OutputText $outputText } else { '' }
            })
        }
    }

    $latestUsage = @($usagePoints | Select-Object -Last 1)[0]
    $wholeUsage = Get-UsageDelta -Start $null -End $latestUsage
    $sessionMinutes = if ($completedDurationMs -gt 0) {
        [math]::Round($completedDurationMs / 60000.0, 3)
    }
    elseif ($firstTimestamp -and $lastTimestamp) {
        [math]::Round(($lastTimestamp - $firstTimestamp).TotalMinutes, 3)
    }
    else { $null }

    $sessionMap[$id] = [pscustomobject]@{
        SessionId = $id
        Path = $matches[0].FullName
        Events = $events.ToArray()
        UsagePoints = $usagePoints.ToArray()
        Markers = $markers.ToArray()
        Calls = $calls.ToArray()
        Outputs = $outputs.ToArray()
        Model = $model
        ReasoningEffort = $reasoningEffort
        CompletedTurnCount = $completedTurnCount
        CompletedDurationMs = $completedDurationMs
        SessionMinutes = $sessionMinutes
        WholeUsage = $wholeUsage
        SpawnCount = @($calls | Where-Object { Test-ToolName $_.Name 'spawn_agent' }).Count
    }
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($parent in @($sessionMap.Values)) {
    foreach ($start in @($parent.Markers | Where-Object Event -eq 'start' | Sort-Object Index)) {
        $milestoneKey = $start.MilestoneId.ToLowerInvariant()
        if ($milestoneFilter.Count -gt 0 -and -not $milestoneFilter.ContainsKey($milestoneKey)) { continue }

        $sameMarkers = @($parent.Markers | Where-Object { $_.MilestoneId.ToLowerInvariant() -eq $milestoneKey })
        $decisions = @($sameMarkers | Where-Object { $_.Event -eq 'decision' -and $_.Index -gt $start.Index } | Sort-Object Index)
        $ends = @($sameMarkers | Where-Object { $_.Event -eq 'end' -and $_.Index -gt $start.Index } | Sort-Object Index)
        $decision = if ($decisions.Count -gt 0) { $decisions[0] } else { $null }
        $end = if ($ends.Count -gt 0) { $ends[0] } else { $null }
        $segmentEndIndex = if ($end) { $end.Index } else { $parent.Events.Count }
        $warnings = New-Object System.Collections.Generic.List[string]

        $structureValid = (
            @($sameMarkers | Where-Object Event -eq 'start').Count -eq 1 -and
            $decisions.Count -eq 1 -and
            $ends.Count -eq 1 -and
            $decision.Index -gt $start.Index -and
            $end.Index -gt $decision.Index
        )
        $overlappingStart = @(
            $parent.Markers | Where-Object {
                $_.Event -eq 'start' -and $_.MilestoneId -ne $start.MilestoneId -and
                $_.Index -gt $start.Index -and $_.Index -lt $segmentEndIndex
            }
        ).Count -gt 0
        if ($overlappingStart) { $structureValid = $false; Add-Warning $warnings 'overlapping milestone markers' }
        if (-not $decision) { Add-Warning $warnings 'missing decision marker' }
        if (-not $end) { Add-Warning $warnings 'missing end marker' }

        $decisionData = if ($decision) { $decision.Data } else { $null }
        $endData = if ($end) { $end.Data } else { $null }
        $route = [string](Get-ObjectProperty $decisionData 'route' '')
        $plannedProfiles = @((Get-ObjectProperty $decisionData 'plannedProfiles' @()) | ForEach-Object { [string]$_ })
        $segmentCalls = @($parent.Calls | Where-Object { $_.Index -gt $start.Index -and $_.Index -lt $segmentEndIndex })
        $segmentOutputs = @($parent.Outputs | Where-Object { $_.Index -gt $start.Index -and $_.Index -lt $segmentEndIndex })
        $spawnCalls = @($segmentCalls | Where-Object { Test-ToolName $_.Name 'spawn_agent' })
        $followupCount = @($segmentCalls | Where-Object { Test-ToolName $_.Name 'followup_task' }).Count
        $actualProfiles = New-Object System.Collections.Generic.List[string]
        $forkNoneCount = 0
        foreach ($spawn in $spawnCalls) {
            $arguments = Convert-ArgumentsObject $spawn.RawInput
            $actualProfiles.Add([string](Get-ObjectProperty $arguments 'agent_type' ''))
            if ([string](Get-ObjectProperty $arguments 'fork_turns' '') -eq 'none') { $forkNoneCount++ }
        }

        $expectedCount = switch ($route) {
            'DIRECT_SOL' { 0 }
            'DELEGATE_ONE' { 1 }
            'DELEGATE_TWO' { 2 }
            default { -1 }
        }
        $decisionBeforeSpawns = $decision -and @($spawnCalls | Where-Object { $_.Index -lt $decision.Index }).Count -eq 0
        $actualProfileArray = $actualProfiles.ToArray()
        $profilesAllowed = @($plannedProfiles + $actualProfileArray | Where-Object { $_ -notin $allowedProfiles }).Count -eq 0
        $delegationShapeValid = (
            $expectedCount -ge 0 -and
            $plannedProfiles.Count -eq $expectedCount -and
            $spawnCalls.Count -eq $expectedCount -and
            (Get-SortedSignature $plannedProfiles) -eq (Get-SortedSignature $actualProfileArray) -and
            $forkNoneCount -eq $spawnCalls.Count -and
            $decisionBeforeSpawns -and
            $profilesAllowed
        )
        if (-not $delegationShapeValid) { Add-Warning $warnings 'planned and actual delegation shape differ or use a prohibited profile/context' }
        if ($followupCount -gt 0) { Add-Warning $warnings 'followup_task is prohibited' }

        $childSessionIds = @((Get-ObjectProperty $endData 'childSessionIds' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $childIdCountValid = $childSessionIds.Count -eq $spawnCalls.Count -and @($childSessionIds | Select-Object -Unique).Count -eq $childSessionIds.Count
        if (-not $childIdCountValid) { Add-Warning $warnings 'child session IDs do not match actual starts' }
        $childRecords = New-Object System.Collections.Generic.List[object]
        foreach ($childId in $childSessionIds) {
            if ($sessionMap.ContainsKey($childId)) { $childRecords.Add($sessionMap[$childId]) }
        }
        $childEvidenceComplete = $childIdCountValid -and $childRecords.Count -eq $childSessionIds.Count
        if (-not $childEvidenceComplete -and $spawnCalls.Count -gt 0) { Add-Warning $warnings 'one or more child logs were not supplied' }

        $modelProfilesValid = $null
        if ($childEvidenceComplete) {
            $expectedSignatures = @($actualProfileArray | ForEach-Object { $profileSignatures[[string]$_] })
            $observedSignatures = @($childRecords | ForEach-Object { "$($_.Model)|$($_.ReasoningEffort)" })
            $modelProfilesValid = (Get-SortedSignature $expectedSignatures) -eq (Get-SortedSignature $observedSignatures)
            if (-not $modelProfilesValid) { Add-Warning $warnings 'child model or reasoning effort does not match its named profile' }
        }

        $preDecisionToolCalls = if ($decision) {
            @($segmentCalls | Where-Object { $_.Index -lt $decision.Index }).Count
        }
        else { $segmentCalls.Count }
        if ($preDecisionToolCalls -gt 8) { Add-Warning $warnings 'pre-decision parent tool call limit exceeded' }

        $failedOutputs = @($segmentOutputs | Where-Object Failed)
        foreach ($child in $childRecords) { $failedOutputs += @($child.Outputs | Where-Object Failed) }
        $confirmedAvoidable = @($failedOutputs | Where-Object { $_.Category -in @('syntax', 'parameter') }).Count
        $reviewFailureCount = @($failedOutputs | Where-Object { $_.Category -notin @('syntax', 'parameter') }).Count
        $reviewedAvoidable = [int](Convert-ToLongOrZero (Get-ObjectProperty $endData 'avoidableInvocationFailuresActual' 0))
        $effectiveAvoidable = [math]::Max($confirmedAvoidable, $reviewedAvoidable)
        if ($effectiveAvoidable -ge 2) { Add-Warning $warnings 'avoidable invocation failure breaker tripped' }

        $usageStart = Get-UsageAtOrBefore -Points $parent.UsagePoints -Index $start.Index
        $usageEnd = Get-UsageAtOrAfter -Points $parent.UsagePoints -Index $segmentEndIndex -MaximumIndex $parent.Events.Count
        $parentUsage = Get-UsageDelta -Start $usageStart -End $usageEnd
        $childTokens = [long]0
        foreach ($child in $childRecords) { $childTokens += [long]$child.WholeUsage.CostSensitiveTokens }
        $totalTokens = [long]$parentUsage.CostSensitiveTokens + $childTokens

        $measuredMinutes = if ($start.Timestamp -and $end -and $end.Timestamp) {
            [math]::Round(($end.Timestamp - $start.Timestamp).TotalMinutes, 3)
        }
        else { $null }

        $baselineSource = [string](Get-ObjectProperty $decisionData 'baselineSource' 'estimate')
        $baselineSessionId = [string](Get-ObjectProperty $decisionData 'baselineSessionId' '')
        $directLow = Convert-ToDoubleOrNull (Get-ObjectProperty $decisionData 'directSolMinutesLow')
        $directHigh = Convert-ToDoubleOrNull (Get-ObjectProperty $decisionData 'directSolMinutesHigh')
        $baselineRecord = if (-not [string]::IsNullOrWhiteSpace($baselineSessionId) -and $sessionMap.ContainsKey($baselineSessionId.ToLowerInvariant())) {
            $sessionMap[$baselineSessionId.ToLowerInvariant()]
        }
        else { $null }
        $baselineComparable = $false
        if ($baselineSource -in @('historical', 'measured') -and $baselineRecord -and $baselineRecord.CompletedTurnCount -gt 0) {
            $insideBand = $null -ne $directLow -and $null -ne $directHigh -and $null -ne $baselineRecord.SessionMinutes -and
                $baselineRecord.SessionMinutes -ge $directLow -and $baselineRecord.SessionMinutes -le $directHigh
            $baselineComparable = (
                $baselineRecord.Model -eq $parent.Model -and
                $baselineRecord.ReasoningEffort -eq $parent.ReasoningEffort -and
                $baselineRecord.SpawnCount -eq 0 -and
                $insideBand
            )
        }
        $baselineMinutes = if ($baselineRecord) { $baselineRecord.SessionMinutes } else { $null }
        $baselineTokens = if ($baselineRecord) { [long]$baselineRecord.WholeUsage.CostSensitiveTokens } else { [long]0 }
        $timeSavingsPercent = if ($baselineComparable -and $baselineMinutes -gt 0 -and $null -ne $measuredMinutes) {
            [math]::Round((1 - ($measuredMinutes / $baselineMinutes)) * 100, 2)
        }
        else { $null }
        $tokenSavingsPercent = if ($baselineComparable -and $childEvidenceComplete -and $baselineTokens -gt 0) {
            [math]::Round((1 - ($totalTokens / [double]$baselineTokens)) * 100, 2)
        }
        else { $null }

        $declaredQuality = [string](Get-ObjectProperty $endData 'qualityOutcome' '')
        $oraclePassed = Convert-ToBooleanOrFalse (Get-ObjectProperty $endData 'oraclePassed' $false)
        $evidenceComplete = Convert-ToBooleanOrFalse (Get-ObjectProperty $endData 'evidenceComplete' $false)
        $qualityCalculated = if (-not $end) { 'INCOMPLETE' }
        elseif ($declaredQuality -eq 'FAIL') { 'FAIL' }
        elseif ($oraclePassed -and $evidenceComplete) { 'PASS' }
        elseif ($oraclePassed -or $evidenceComplete -or $declaredQuality -eq 'PARTIAL') { 'PARTIAL' }
        else { 'FAIL' }
        if ($end -and $declaredQuality -ne $qualityCalculated) { Add-Warning $warnings 'declared and calculated quality differ' }

        $declaredDelegation = [string](Get-ObjectProperty $endData 'delegationOutcome' '')
        $solFallback = Convert-ToBooleanOrFalse (Get-ObjectProperty $endData 'solFallback' $false)
        $solSemanticRescue = Convert-ToBooleanOrFalse (Get-ObjectProperty $endData 'solSemanticRescue' $false)
        $leaseBreach = Convert-ToBooleanOrFalse (Get-ObjectProperty $endData 'leaseBreach' $false)
        $duplicateAuthorityRequests = [int](Convert-ToLongOrZero (Get-ObjectProperty $endData 'duplicateAuthorityRequests' 0))
        $broadGateRuns = [int](Convert-ToLongOrZero (Get-ObjectProperty $endData 'broadGateRunsActual' 0))
        $repeatedBroadGate = Convert-ToBooleanOrFalse (Get-ObjectProperty $endData 'repeatedUnchangedBroadGate' $false)
        $coordinationMinutes = Convert-ToDoubleOrNull (Get-ObjectProperty $endData 'coordinationMinutesActual')
        $reworkMinutes = Convert-ToDoubleOrNull (Get-ObjectProperty $endData 'reworkMinutes')
        $protocolValid = $structureValid -and
            [string](Get-ObjectProperty $start.Data 'version' '') -eq '1.0' -and
            [string](Get-ObjectProperty $decisionData 'version' '') -eq '1.0' -and
            [string](Get-ObjectProperty $endData 'version' '') -eq '1.0'

        $breaker = (
            -not $protocolValid -or -not $delegationShapeValid -or -not $childIdCountValid -or
            $followupCount -gt 0 -or $preDecisionToolCalls -gt 8 -or
            ($null -ne $modelProfilesValid -and -not $modelProfilesValid) -or
            $qualityCalculated -ne 'PASS' -or $solFallback -or $solSemanticRescue -or $leaseBreach -or
            $duplicateAuthorityRequests -gt 0 -or $effectiveAvoidable -ge 2 -or
            $broadGateRuns -gt 2 -or $repeatedBroadGate -or $declaredDelegation -eq 'LOSS'
        )
        $timeLoss = $baselineComparable -and $null -ne $measuredMinutes -and $null -ne $directHigh -and $measuredMinutes -gt $directHigh
        $tokenLoss = $baselineComparable -and $childEvidenceComplete -and $baselineTokens -gt 0 -and $totalTokens -gt ($baselineTokens * 1.10)
        $coordinationWithinGate = $baselineComparable -and $null -ne $coordinationMinutes -and $null -ne $directLow -and $coordinationMinutes -le ($directLow * 0.25)
        $reworkWithinGate = $null -eq $reworkMinutes -or $reworkMinutes -le 5
        $timeWin = $baselineComparable -and $null -ne $timeSavingsPercent -and $timeSavingsPercent -ge 15 -and -not $tokenLoss
        $tokenWin = $baselineComparable -and $childEvidenceComplete -and $null -ne $tokenSavingsPercent -and $tokenSavingsPercent -ge 15 -and
            $null -ne $measuredMinutes -and $null -ne $directHigh -and $measuredMinutes -le $directHigh

        $delegationCalculated = if (-not $end) { 'INCOMPLETE' }
        elseif ($route -eq 'DIRECT_SOL') {
            if ($spawnCalls.Count -eq 0 -and $delegationShapeValid) { 'NOT_USED' } else { 'LOSS' }
        }
        elseif ($breaker -or $timeLoss -or $tokenLoss) { 'LOSS' }
        elseif ($childEvidenceComplete -and $coordinationWithinGate -and $reworkWithinGate -and ($timeWin -or $tokenWin)) { 'WIN' }
        else { 'NEUTRAL' }
        if ($end -and $declaredDelegation -ne $delegationCalculated) { Add-Warning $warnings 'declared and calculated delegation outcomes differ' }

        $rows.Add([pscustomobject]@{
            Kind = 'milestone'
            AuditVersion = $auditVersion
            ParentSessionId = $parent.SessionId
            MilestoneId = $start.MilestoneId
            Route = $route
            PlannedProfiles = ($plannedProfiles -join ',')
            ActualProfiles = ($actualProfileArray -join ',')
            QualityOutcomeDeclared = $declaredQuality
            QualityOutcomeCalculated = $qualityCalculated
            DelegationOutcomeDeclared = $declaredDelegation
            DelegationOutcomeCalculated = $delegationCalculated
            ProtocolValid = $protocolValid
            DelegationShapeValid = $delegationShapeValid
            ChildIdCountValid = $childIdCountValid
            ChildEvidenceComplete = $childEvidenceComplete
            ModelProfilesValid = $modelProfilesValid
            ParentModel = $parent.Model
            ParentReasoningEffort = $parent.ReasoningEffort
            PreDecisionToolCallCount = $preDecisionToolCalls
            SpawnCount = $spawnCalls.Count
            FollowupCount = $followupCount
            ToolFailureCount = $failedOutputs.Count
            ConfirmedAvoidableFailureCount = $confirmedAvoidable
            ReviewFailureCount = $reviewFailureCount
            EffectiveAvoidableFailureCount = $effectiveAvoidable
            ParentCostSensitiveTokens = [long]$parentUsage.CostSensitiveTokens
            ChildCostSensitiveTokens = $childTokens
            CostSensitiveTokens = $totalTokens
            MeasuredElapsedMinutes = $measuredMinutes
            BaselineComparable = $baselineComparable
            BaselineSessionId = $baselineSessionId
            BaselineMeasuredMinutes = $baselineMinutes
            BaselineCostSensitiveTokens = $baselineTokens
            TimeSavingsPercent = $timeSavingsPercent
            TokenSavingsPercent = $tokenSavingsPercent
            SolFallback = $solFallback
            SolSemanticRescue = $solSemanticRescue
            LeaseBreach = $leaseBreach
            DuplicateAuthorityRequests = $duplicateAuthorityRequests
            BroadGateRunsActual = $broadGateRuns
            RepeatedUnchangedBroadGate = $repeatedBroadGate
            Warnings = ($warnings -join '; ')
        })
    }
}

foreach ($session in @($sessionMap.Values | Sort-Object SessionId)) {
    $rows.Add([pscustomobject]@{
        Kind = 'session'
        AuditVersion = $auditVersion
        SessionId = $session.SessionId
        Model = $session.Model
        ReasoningEffort = $session.ReasoningEffort
        CompletedTurnCount = $session.CompletedTurnCount
        SessionMinutes = $session.SessionMinutes
        SpawnCount = $session.SpawnCount
        ToolFailureCount = @($session.Outputs | Where-Object Failed).Count
        CostSensitiveTokens = [long]$session.WholeUsage.CostSensitiveTokens
        HasHybridMarkers = $session.Markers.Count -gt 0
        Path = $session.Path
    })
}

if (@($rows | Where-Object Kind -eq 'milestone').Count -eq 0 -and $milestoneFilter.Count -gt 0) {
    throw "No matching hybrid milestone found: $($milestoneFilter.Keys -join ',')"
}

$rows
