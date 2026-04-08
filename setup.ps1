[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = (& git rev-parse --show-toplevel 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = (Get-Location).Path
}

$hooksDir = (& git rev-parse --git-path hooks 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($hooksDir)) {
    $hooksDir = Join-Path $repoRoot '.git/hooks'
}

$hooksDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $hooksDir))
$logsDir = Join-Path $repoRoot 'logs'
$hookSource = Join-Path $repoRoot 'hooks/pre-push'
$hookTarget = Join-Path $hooksDir 'pre-push'

$null = New-Item -ItemType Directory -Force -Path $hooksDir
$null = New-Item -ItemType Directory -Force -Path $logsDir
Copy-Item -LiteralPath $hookSource -Destination $hookTarget -Force

Write-Host "Installed pre-push hook to $hookTarget"
Write-Host 'Primary engine: scripts/security_check.ps1 (when pwsh / pwsh.exe is available)'
Write-Host 'Fallback engine: scripts/security_check.sh'
Write-Host "Logs will be written to $logsDir"