[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CodexRoot,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$sourceSkillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceSkillFile = Join-Path $sourceSkillRoot 'SKILL.md'
$sourceProfiles = Join-Path $sourceSkillRoot 'assets\agent-profiles'
$profileNames = @('luna-fast.toml', 'luna-executor.toml', 'terra-fast.toml', 'terra-executor.toml')

if (-not (Test-Path -LiteralPath $sourceSkillFile -PathType Leaf)) {
    throw "Invalid package: missing $sourceSkillFile"
}
if (-not (Select-String -LiteralPath $sourceSkillFile -SimpleMatch 'name: sol-hybrid-delivery' -Quiet)) {
    throw 'Invalid package: SKILL.md does not declare sol-hybrid-delivery.'
}
foreach ($profileName in $profileNames) {
    $profilePath = Join-Path $sourceProfiles $profileName
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "Invalid package: missing $profilePath"
    }
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
$targetSkillsRoot = Join-Path $resolvedCodexRoot 'skills'
$targetAgentsRoot = Join-Path $resolvedCodexRoot 'agents'
$targetSkillRoot = Join-Path $targetSkillsRoot 'sol-hybrid-delivery'
$installSkill = -not $sourceSkillRoot.TrimEnd('\').Equals(
    [System.IO.Path]::GetFullPath($targetSkillRoot).TrimEnd('\'),
    [System.StringComparison]::OrdinalIgnoreCase
)

$existingTargets = New-Object System.Collections.Generic.List[string]
if ($installSkill -and (Test-Path -LiteralPath $targetSkillRoot)) {
    $existingTargets.Add($targetSkillRoot)
}
foreach ($profileName in $profileNames) {
    $targetProfile = Join-Path $targetAgentsRoot $profileName
    if (Test-Path -LiteralPath $targetProfile) {
        $existingTargets.Add($targetProfile)
    }
}

if ($existingTargets.Count -gt 0 -and -not $Force) {
    throw "Installation stopped because targets already exist. Review them and rerun with -Force to overwrite package-owned files only:`n$($existingTargets -join [Environment]::NewLine)"
}

if ($PSCmdlet.ShouldProcess($resolvedCodexRoot, 'Install Sol Hybrid Delivery skill and four executor profiles')) {
    New-Item -ItemType Directory -Path $targetSkillsRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $targetAgentsRoot -Force | Out-Null

    if ($installSkill) {
        if (-not (Test-Path -LiteralPath $targetSkillRoot)) {
            Copy-Item -LiteralPath $sourceSkillRoot -Destination $targetSkillsRoot -Recurse
        }
        else {
            Get-ChildItem -LiteralPath $sourceSkillRoot -Force | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $targetSkillRoot -Recurse -Force
            }
        }
    }

    foreach ($profileName in $profileNames) {
        Copy-Item -LiteralPath (Join-Path $sourceProfiles $profileName) -Destination (Join-Path $targetAgentsRoot $profileName) -Force
    }
}

[pscustomobject]@{
    CodexRoot = $resolvedCodexRoot
    Skill = $targetSkillRoot
    Profiles = @($profileNames | ForEach-Object { Join-Path $targetAgentsRoot $_ })
    RestartRequired = $true
} | ConvertTo-Json -Depth 3
