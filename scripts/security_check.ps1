[CmdletBinding()]
param(
    [string]$RemoteName = 'unknown-remote',
    [string]$RemoteUrl = 'unknown-url',
    [string]$RefsFile
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

if ([string]::IsNullOrWhiteSpace($RefsFile) -or -not (Test-Path -LiteralPath $RefsFile -PathType Leaf)) {
    [Console]::Error.WriteLine('[security-hook] refs file is missing.')
    exit 1
}

$repoRoot = (& git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot

$zeroSha = '0000000000000000000000000000000000000000'
$maxPromptChars = 28000
if ($env:SECURITY_HOOK_MAX_PROMPT_CHARS) {
    $parsedMax = 0
    if ([int]::TryParse($env:SECURITY_HOOK_MAX_PROMPT_CHARS, [ref]$parsedMax) -and $parsedMax -gt 0) {
        $maxPromptChars = $parsedMax
    }
}

$failOpen = $env:SECURITY_HOOK_FAIL_OPEN -eq '1'
$logDir = Join-Path $repoRoot 'logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "security-$timestamp.log"

function Write-Log {
    param([string]$Message)

    Add-Content -LiteralPath $logFile -Value $Message -Encoding UTF8
}

function Fail-OrPassOpen {
    param([string]$Message)

    [Console]::Error.WriteLine("[security-hook] $Message")

    if ($failOpen) {
        [Console]::Error.WriteLine('[security-hook] SECURITY_HOOK_FAIL_OPEN=1 のため push を継続します。')
        Write-Log 'Result: PASS (fail-open)'
        Write-Log "Reason: $Message"
        exit 0
    }

    Write-Log 'Result: FAIL'
    Write-Log "Reason: $Message"
    exit 1
}

function Should-CheckRef {
    param(
        [string]$LocalRef,
        [string]$RemoteRef
    )

    $effectiveRef = $LocalRef

    if (-not $effectiveRef.StartsWith('refs/heads/')) {
        $effectiveRef = $RemoteRef
    }

    if (-not $effectiveRef.StartsWith('refs/heads/')) {
        return $false
    }

    # Default: check every branch.
    # To limit checks to production branches only, replace this function body with:
    # switch ($effectiveRef) {
    #     'refs/heads/main' { return $true }
    #     'refs/heads/master' { return $true }
    #     default { return $false }
    # }
    return $true
}

function Collect-Commits {
    param(
        [string]$RemoteSha,
        [string]$LocalSha
    )

    if ($RemoteSha -ne $zeroSha) {
        return @(& git rev-list --reverse "$RemoteSha..$LocalSha")
    }

    return @(& git rev-list --reverse $LocalSha)
}

function Build-PatchPayload {
    param([string[]]$Commits)

    $builder = New-Object System.Text.StringBuilder
    foreach ($commit in $Commits) {
        if ([string]::IsNullOrWhiteSpace($commit)) {
            continue
        }

        $block = ((& git show --stat --patch --find-renames --format=medium $commit) | Out-String).TrimEnd()
        if (($builder.Length + $block.Length) -gt $maxPromptChars) {
            $null = $builder.AppendLine('[TRUNCATED] Prompt length limit reached.')
            break
        }

        $null = $builder.AppendLine($block)
        $null = $builder.AppendLine()
    }

    return $builder.ToString().TrimEnd()
}

function Collect-ChangedFiles {
    param([string[]]$Commits)

    $files = foreach ($commit in $Commits) {
        if ([string]::IsNullOrWhiteSpace($commit)) {
            continue
        }

        & git show --format= --name-only $commit
    }

    return @($files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Find-Matches {
    param(
        [string]$Path,
        [string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    return @(Select-String -LiteralPath $Path -Pattern $Pattern -AllMatches -Encoding UTF8)
}

function Build-StaticSignals {
    param([string[]]$Files)

    $findings = New-Object System.Collections.Generic.List[string]
    $secretPattern = '(api[_-]?key|secret|token|password)\s*[:=]\s*[''\"][^''\"]{8,}[''\"]'
    $commandPattern = 'os\.system\(|subprocess\.(Popen|run)\(|child_process\.exec\(|eval\('
    $xssPattern = 'res\.send\(.*req\.(query|body)|innerHTML\s*=.*(req\.|location\.)'
    $ssrfPattern = 'fetch\(req\.(query|body)|axios\.(get|post)\(req\.(query|body)|requests\.(get|post)\(request\.(args|form)'

    foreach ($file in $Files) {
        foreach ($match in Find-Matches -Path $file -Pattern $secretPattern) {
            $findings.Add("- hardcoded secret candidate in $file")
            $findings.Add("$($match.LineNumber):$($match.Line.Trim())")
        }

        foreach ($match in Find-Matches -Path $file -Pattern $commandPattern) {
            $findings.Add("- dangerous command execution candidate in $file")
            $findings.Add("$($match.LineNumber):$($match.Line.Trim())")
        }

        foreach ($match in Find-Matches -Path $file -Pattern $xssPattern) {
            $findings.Add("- XSS candidate in $file")
            $findings.Add("$($match.LineNumber):$($match.Line.Trim())")
        }

        foreach ($match in Find-Matches -Path $file -Pattern $ssrfPattern) {
            $findings.Add("- SSRF candidate in $file")
            $findings.Add("$($match.LineNumber):$($match.Line.Trim())")
        }
    }

    if ($findings.Count -eq 0) {
        return '- No high-signal regex matches found before the Copilot review.'
    }

    return ($findings -join "`n")
}

$copilotCommand = $null
$copilotKind = $null

foreach ($candidate in @('copilot', 'copilot.exe')) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command) {
        $copilotCommand = $command.Source
        $copilotKind = 'standalone'
        break
    }
}

if (-not $copilotCommand) {
    foreach ($candidate in @('gh', 'gh.exe')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) {
            $copilotCommand = $command.Source
            $copilotKind = 'gh-wrapper'
            break
        }
    }
}

if (-not $copilotCommand) {
    Write-Log "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "Remote: $RemoteName ($RemoteUrl)"
    Fail-OrPassOpen "Copilot CLI が見つかりません。standalone の 'copilot' コマンドをインストールしてください。"
}

$refsSummaryLines = New-Object System.Collections.Generic.List[string]
$commitSections = New-Object System.Collections.Generic.List[string]
$changedFiles = New-Object System.Collections.Generic.HashSet[string]
$reviewRequired = $false

foreach ($line in Get-Content -LiteralPath $RefsFile -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    $parts = $line -split '\s+'
    if ($parts.Count -lt 4) {
        continue
    }

    $localRef = $parts[0]
    $localSha = $parts[1]
    $remoteRef = $parts[2]
    $remoteSha = $parts[3]

    if ($localRef -eq '(delete)') {
        continue
    }

    if (-not (Should-CheckRef -LocalRef $localRef -RemoteRef $remoteRef)) {
        continue
    }

    $reviewRequired = $true
    $refsSummaryLines.Add("- $localRef ($localSha) -> $remoteRef ($remoteSha)")

    $commitsForRef = @(Collect-Commits -RemoteSha $remoteSha -LocalSha $localSha | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($commitsForRef.Count -eq 0) {
        continue
    }

    $payloadForRef = Build-PatchPayload -Commits $commitsForRef
    if (-not [string]::IsNullOrWhiteSpace($payloadForRef)) {
        $commitSections.Add("### Ref: $localRef -> $remoteRef`n$payloadForRef")
    }

    foreach ($file in Collect-ChangedFiles -Commits $commitsForRef) {
        if (-not [string]::IsNullOrWhiteSpace($file)) {
            $null = $changedFiles.Add($file)
        }
    }
}

if (-not $reviewRequired) {
    exit 0
}

$refsSummary = $refsSummaryLines -join "`n"
$changedFileList = @($changedFiles | Sort-Object)

if ($commitSections.Count -eq 0) {
    Write-Log "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "Remote: $RemoteName ($RemoteUrl)"
    Write-Log 'Refs:'
    Write-Log $refsSummary
    Write-Log 'Result: PASS'
    Write-Log 'Reason: no commits detected for the selected refs.'
    exit 0
}

$staticSignals = Build-StaticSignals -Files $changedFileList
$commitPayload = $commitSections -join "`n`n"
$changedFilesText = if ($changedFileList.Count -gt 0) { $changedFileList -join "`n" } else { 'none' }

$prompt = @"
You are performing a strict pre-push security review for changed code.

Context:
- Repository: $(Split-Path $repoRoot -Leaf)
- Remote: $RemoteName
- Review date: $(Get-Date -Format 'yyyy-MM-dd')
- Goal: block pushes that introduce representative security risks.

Review these categories at minimum:
1. SQL injection
2. Command injection / unsafe shell execution
3. XSS or unsafe HTML rendering
4. SSRF or arbitrary outbound requests
5. Hardcoded secrets or credentials
6. Broken authentication or authorization
7. Unsafe deserialization / eval-like execution
8. Sensitive information leakage or insecure defaults

Respond in Japanese.
Do not use tools. Review only the patch data provided in this prompt.
If the patch is acceptable, include exactly one line containing: SECURITY_CHECK: PASS
If the patch is not acceptable, include exactly one line containing: SECURITY_CHECK: FAIL

Output format:
SECURITY_CHECK: PASS or FAIL
Summary: one short sentence
Findings:
- [severity] file[:line] - issue - why it matters - suggested fix

If there are no findings, write exactly:
Findings:
- none

Refs being pushed:
$refsSummary

Changed files:
$changedFilesText

Static pre-scan signals:
$staticSignals

Patch data:
$commitPayload
"@

Write-Log '=== Security Check Log ==='
Write-Log "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Remote: $RemoteName ($RemoteUrl)"
Write-Log 'Refs:'
Write-Log $refsSummary
Write-Log 'Changed files:'
Write-Log $changedFilesText
Write-Log "Prompt max chars: $maxPromptChars"

$copilotOutput = ''
$copilotStatus = 0
if ($copilotKind -eq 'standalone') {
    Write-Log "Copilot CLI command: $copilotCommand -p <prompt> --silent --no-ask-user --add-dir $repoRoot"
    $copilotOutput = (& $copilotCommand -p $prompt --silent --no-ask-user --add-dir $repoRoot 2>&1 | Out-String).TrimEnd()
    if ($LASTEXITCODE) {
        $copilotStatus = $LASTEXITCODE
    }
}
else {
    Write-Log "Copilot CLI command: $copilotCommand copilot -- -p <prompt>"
    $copilotOutput = (& $copilotCommand copilot -- -p $prompt 2>&1 | Out-String).TrimEnd()
    if ($LASTEXITCODE) {
        $copilotStatus = $LASTEXITCODE
    }
}

Write-Log '--- Copilot Output ---'
Write-Log $copilotOutput
Write-Log '========================'

if ($copilotStatus -ne 0) {
    Fail-OrPassOpen "Copilot CLI の実行に失敗しました。ログを確認してください: $logFile"
}

if ($copilotOutput -match 'SECURITY_CHECK:\s*PASS') {
    [Console]::Error.WriteLine('[security-hook] PASS: security review passed.')
    Write-Log 'Result: PASS'
    exit 0
}

if ($copilotOutput -match 'SECURITY_CHECK:\s*FAIL') {
    [Console]::Error.WriteLine('[security-hook] FAIL: push blocked by security review.')
    [Console]::Error.WriteLine($copilotOutput)
    Write-Log 'Result: FAIL'
    exit 1
}

Fail-OrPassOpen "Copilot の応答を判定できませんでした。ログを確認してください: $logFile"