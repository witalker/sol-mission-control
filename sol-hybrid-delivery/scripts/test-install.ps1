[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install.ps1'
$sourceSkillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempBase ('sol-hybrid-install-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot).TrimEnd('\')
if (-not $resolvedTestRoot.StartsWith($tempBase + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe test root: $resolvedTestRoot"
}

try {
    $first = & $installer -CodexRoot $resolvedTestRoot | ConvertFrom-Json
    $targetSkill = Join-Path $resolvedTestRoot 'skills\sol-hybrid-delivery'
    $targetAgents = Join-Path $resolvedTestRoot 'agents'
    Assert-True (Test-Path -LiteralPath (Join-Path $targetSkill 'SKILL.md') -PathType Leaf) 'skill installs into a clean Codex root'
    Assert-True ($first.RestartRequired -eq $true) 'installer reports restart requirement'

    foreach ($name in @('luna-fast.toml', 'luna-executor.toml', 'terra-fast.toml', 'terra-executor.toml')) {
        $source = Join-Path $sourceSkillRoot "assets\agent-profiles\$name"
        $target = Join-Path $targetAgents $name
        Assert-True (Test-Path -LiteralPath $target -PathType Leaf) "profile installed: $name"
        Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash -eq (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash) "profile hash matches: $name"
    }

    $stoppedWithoutForce = $false
    try { & $installer -CodexRoot $resolvedTestRoot | Out-Null } catch { $stoppedWithoutForce = $true }
    Assert-True $stoppedWithoutForce 'existing targets require -Force'

    & $installer -CodexRoot $resolvedTestRoot -Force | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $targetSkill 'agents\openai.yaml') -PathType Leaf) 'forced upgrade preserves complete skill structure'

    'HYBRID_INSTALL_TESTS_PASSED'
}
finally {
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        $allItems = @(Get-ChildItem -LiteralPath $resolvedTestRoot -Recurse -Force)
        foreach ($item in $allItems) {
            $full = [System.IO.Path]::GetFullPath($item.FullName)
            if (-not $full.StartsWith($resolvedTestRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Cleanup target escaped test root: $full"
            }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to remove reparse point: $full"
            }
        }
        foreach ($file in @($allItems | Where-Object { -not $_.PSIsContainer })) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
        foreach ($directory in @($allItems | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending)) {
            if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -ne 0) {
                throw "Refusing to remove non-empty directory: $($directory.FullName)"
            }
            Remove-Item -LiteralPath $directory.FullName -Force
        }
        if (@(Get-ChildItem -LiteralPath $resolvedTestRoot -Force).Count -ne 0) {
            throw "Refusing to remove non-empty test root: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Force
    }
}
