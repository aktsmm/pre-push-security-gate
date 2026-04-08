[CmdletBinding()]
param(
    [ValidateSet('all', 'fail', 'pass')]
    [string]$Scenario = 'all'
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)

    Write-Host "[test-hook] $Message"
}

function Assert-ExitCode {
    param(
        [int]$Actual,
        [int]$Expected,
        [string]$Context
    )

    if ($Actual -ne $Expected) {
        throw "$Context failed. Expected exit code $Expected but got $Actual."
    }
}

$repoRoot = (& git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot

$pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshCommand) {
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
}

if (-not $pwshCommand) {
    throw 'PowerShell 7 (pwsh / pwsh.exe) が見つかりません。'
}

$copilotCommand = Get-Command copilot -ErrorAction SilentlyContinue
if (-not $copilotCommand) {
    $copilotCommand = Get-Command copilot.exe -ErrorAction SilentlyContinue
}

if (-not $copilotCommand) {
    throw "standalone の 'copilot' コマンドが見つかりません。"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ag-hook-security-test-" + [guid]::NewGuid().ToString('N'))
$worktreePath = Join-Path $tempRoot 'worktree'
$branchName = "test-hook-" + [guid]::NewGuid().ToString('N').Substring(0, 8)

Write-Step "Creating temporary worktree at $worktreePath"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
& git worktree add --quiet -b $branchName $worktreePath HEAD | Out-Null
$remotePath = Join-Path $tempRoot 'remote.git'
& git init --bare $remotePath | Out-Null

try {
    Set-Location $worktreePath

    Write-Step 'Overlaying current workspace files into temporary worktree'
    foreach ($relativePath in @(
        'setup.ps1',
        'setup.sh',
        'hooks/pre-push',
        'scripts/security_check.ps1',
        'scripts/security_check.sh'
    )) {
        $sourcePath = Join-Path $repoRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            continue
        }

        $targetPath = Join-Path $worktreePath $relativePath
        $targetDir = Split-Path -Parent $targetPath
        if (-not [string]::IsNullOrWhiteSpace($targetDir)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    }

    & git config user.name 'Ag Hook Security Test' | Out-Null
    & git config user.email 'ag-hook-security-test@example.com' | Out-Null

    Write-Step 'Installing hook into temporary worktree'
    & $pwshCommand.Source -NoProfile -File (Join-Path $worktreePath 'setup.ps1') | Out-Null
    $hooksDir = (& git rev-parse --git-path hooks).Trim()
    if ([System.IO.Path]::IsPathRooted($hooksDir)) {
        $resolvedHooksDir = $hooksDir
    }
    else {
        $resolvedHooksDir = Join-Path $worktreePath $hooksDir
    }

    $hookPath = Join-Path $resolvedHooksDir 'pre-push'
    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
        throw "Hook installation failed. Hook file was not created at $hookPath."
    }

    if ($Scenario -in @('all', 'fail')) {
        Write-Step 'Running FAIL scenario against full history via real git push'
        if (git remote | Select-String -Pattern '^local-e2e$' -Quiet) {
            & git remote remove local-e2e | Out-Null
        }
        & git remote add local-e2e $remotePath | Out-Null
        $failOutput = (& git push local-e2e HEAD:refs/heads/test-fail 2>&1 | Out-String)
        $failExitCode = $LASTEXITCODE
        Assert-ExitCode -Actual $failExitCode -Expected 1 -Context 'FAIL scenario'

        if ($failOutput -notmatch 'SECURITY_CHECK:\s*FAIL') {
            throw 'FAIL scenario did not produce SECURITY_CHECK: FAIL.'
        }

        $remoteRefsAfterFail = (& git --git-dir=$remotePath show-ref 2>$null | Out-String)
        if ($remoteRefsAfterFail -match 'refs/heads/test-fail') {
            throw 'FAIL scenario unexpectedly updated the remote repository.'
        }
    }

    if ($Scenario -in @('all', 'pass')) {
        Write-Step 'Creating harmless commit for PASS scenario'
        $baseHead = (& git rev-parse HEAD).Trim()
        $testFile = Join-Path $worktreePath 'demo/safe_js/test-pass-marker.txt'
        Set-Content -LiteralPath $testFile -Value "pass scenario marker $(Get-Date -Format s)" -Encoding utf8
        & git add $testFile | Out-Null
        & git commit -m 'test: add harmless marker for PASS scenario' | Out-Null

        $newHead = (& git rev-parse HEAD).Trim()
        if (git remote | Select-String -Pattern '^local-e2e-pass$' -Quiet) {
            & git remote remove local-e2e-pass | Out-Null
        }
        & git remote add local-e2e-pass $remotePath | Out-Null

        Write-Step 'Seeding remote baseline for PASS scenario'
        $env:SKIP_COPILOT_SECURITY_HOOK = '1'
        try {
            & git push local-e2e-pass "${baseHead}:refs/heads/test-pass" | Out-Null
        }
        finally {
            Remove-Item Env:SKIP_COPILOT_SECURITY_HOOK -ErrorAction SilentlyContinue
        }

        $passOutput = (& git push local-e2e-pass HEAD:refs/heads/test-pass 2>&1 | Out-String)
        $passExitCode = $LASTEXITCODE
        Assert-ExitCode -Actual $passExitCode -Expected 0 -Context 'PASS scenario'

        if ($passOutput -notmatch 'PASS: security review passed') {
            throw 'PASS scenario did not produce a pass message.'
        }

        $remoteRefsAfterPass = (& git --git-dir=$remotePath show-ref refs/heads/test-pass 2>$null | Out-String)
        if ($remoteRefsAfterPass -notmatch [regex]::Escape($newHead)) {
            throw 'PASS scenario did not update the remote repository as expected.'
        }
    }

    Write-Step 'All requested scenarios completed successfully'
}
finally {
    Set-Location $repoRoot
    Write-Step 'Cleaning up temporary worktree'
    & git worktree remove $worktreePath --force | Out-Null
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    & git branch -D $branchName 2>$null | Out-Null
}