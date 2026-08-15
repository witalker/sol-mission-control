[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Read-RequiredFile {
    param([string]$RelativePath)
    $path = Join-Path $skillRoot $RelativePath
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "required file exists: $RelativePath"
    return Get-Content -Raw -LiteralPath $path
}

$skill = Read-RequiredFile 'SKILL.md'
$metadata = Read-RequiredFile 'agents\openai.yaml'
$routing = Read-RequiredFile 'references\model-routing.md'
$auditSchema = Read-RequiredFile 'references\audit-schema.md'
$usage = Read-RequiredFile 'references\usage.md'
$auditor = Read-RequiredFile 'scripts\audit-session-usage.ps1'
$installer = Read-RequiredFile 'scripts\install.ps1'

Assert-True ($skill -match '(?m)^name: sol-hybrid-delivery$') 'frontmatter name is exact'
Assert-True ($skill -match '# Sol Hybrid Delivery v1\.0') 'core version is visible'
Assert-True ($skill -notmatch 'TODO') 'no scaffold TODO remains'
Assert-True ($skill -match 'DIRECT_SOL' -and $skill -match 'DELEGATE_ONE' -and $skill -match 'DELEGATE_TWO') 'all route shapes are defined'
Assert-True ($skill -match 'Use `DIRECT_SOL` by default') 'Direct Sol is the default route'
Assert-True ($skill -match 'Never ask the user to authorize model fallback') 'internal fallback is not a permission boundary'
Assert-True ($skill -match 'at most two child sessions') 'child count is bounded'
Assert-True ($skill -match 'Never use `followup_task`') 'follow-up loops are prohibited'
Assert-True ($skill -match 'qualityOutcome=PASS.*delegationOutcome=LOSS') 'quality and delegation outcomes are independent'

$wordCount = @($skill -split '\s+' | Where-Object { $_ }).Count
Assert-True ($wordCount -le 1300) "core Skill remains lean (words=$wordCount)"
Assert-True ((Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md')).Count -le 170) 'core Skill remains compact'

Assert-True ($metadata -match 'display_name: "Sol Hybrid Delivery v1\.0"') 'UI version matches core'
Assert-True ($metadata -match 'default_prompt: "Use \$sol-hybrid-delivery') 'default prompt invokes the skill explicitly'
Assert-True ($metadata -match 'allow_implicit_invocation: false') 'implicit invocation is disabled'

foreach ($profile in @('luna_fast', 'luna_executor', 'terra_fast', 'terra_executor')) {
    Assert-True ($routing -match [regex]::Escape($profile)) "routing covers $profile"
}
Assert-True ($routing -match 'mixed `luna_fast` plus `terra_executor`') 'mixed-wave scenario is documented'
Assert-True ($routing -match 'Retry a failed child through another model: prohibited') 'replacement-child loop is prohibited'

Assert-True (($auditSchema | Select-String -Pattern 'SOL_HYBRID_DELIVERY_V1' -AllMatches).Matches.Count -eq 3) 'schema defines exactly three marker examples'
Assert-True ($auditSchema -match 'qualityOutcome.*delegationOutcome') 'schema records two-axis outcomes'
Assert-True ($auditor -match 'QualityOutcomeCalculated' -and $auditor -match 'DelegationOutcomeCalculated') 'auditor calculates both axes'
Assert-True ($auditor -match 'Test-ActualToolFailure') 'auditor classifies actual tool failures'

Assert-True ($usage -match '\$sol-hybrid-delivery') 'usage guide contains explicit invocation prompts'
Assert-True ($usage -match 'Plan') 'usage guide covers plan-only work'
Assert-True ($usage -match 'Luna \+ Terra') 'usage guide covers safe mixed execution'

$profileExpectations = @{
    'luna-fast.toml' = @('model = "gpt-5.6-luna"', 'model_reasoning_effort = "low"')
    'luna-executor.toml' = @('model = "gpt-5.6-luna"', 'model_reasoning_effort = "medium"')
    'terra-fast.toml' = @('model = "gpt-5.6-terra"', 'model_reasoning_effort = "low"')
    'terra-executor.toml' = @('model = "gpt-5.6-terra"', 'model_reasoning_effort = "medium"')
}
foreach ($entry in $profileExpectations.GetEnumerator()) {
    $profileText = Read-RequiredFile (Join-Path 'assets\agent-profiles' $entry.Key)
    foreach ($expected in $entry.Value) {
        Assert-True ($profileText.Contains($expected)) "$($entry.Key) contains $expected"
    }
    Assert-True ($profileText -match 'Other agents share the workspace') "$($entry.Key) protects concurrent work"
}

Assert-True ($installer -match "luna-fast\.toml.*luna-executor\.toml.*terra-fast\.toml.*terra-executor\.toml") 'installer owns exactly the four executor profiles'

'HYBRID_SKILL_CONTRACT_TESTS_PASSED'
