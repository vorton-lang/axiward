param([Parameter(Mandatory)][string]$CasesFile, [Parameter(Mandatory)][string]$RunLabel,
      [switch]$InspectUserRuleLoading)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$h1Work = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\work\m0-h1'))
$runDir = Join-Path $h1Work ('evidence\' + $RunLabel)
if (Test-Path -LiteralPath $runDir) { throw 'Use a new run label to preserve prior evidence' }
New-Item -ItemType Directory -Path $runDir | Out-Null
$CasesFile = (Resolve-Path -LiteralPath $CasesFile).Path
Copy-Item -LiteralPath $CasesFile -Destination (Join-Path $runDir 'cases.json')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixed-responses.py') -Destination (Join-Path $runDir 'fixed-responses-used.py')
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $runDir 'run-harness-used.ps1')
Copy-Item -LiteralPath (Join-Path $h1Work 'lab\view\.codex\rules\axiward-probe.rules') -Destination (Join-Path $runDir 'rules-used.rules')
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = (Get-Command python).Source
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
foreach ($arg in @((Join-Path $runDir 'fixed-responses-used.py'), '--cases', $CasesFile, '--evidence', $runDir)) { $psi.ArgumentList.Add($arg) }
$server = [Diagnostics.Process]::Start($psi)
$port = $null
try {
    $endpoint = Join-Path $runDir 'endpoint.json'
    $startupDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (!(Test-Path -LiteralPath $endpoint)) {
        if ($server.HasExited -or [DateTime]::UtcNow -gt $startupDeadline) { throw 'Local fixture failed to start' }
        Start-Sleep -Milliseconds 100
    }
    $port = (Get-Content -LiteralPath $endpoint -Raw | ConvertFrom-Json).port
    $previous = Get-Content -LiteralPath (Join-Path $h1Work 'evidence\harness-run-01\codex-arguments.json') -Raw | ConvertFrom-Json
    $arguments = @($previous | ForEach-Object {
        if ($_ -like 'model_providers.axiward_fixture*') { $_.Replace('127.0.0.1:51352', "127.0.0.1:$port") }
        elseif ($_ -like 'projects.*') {
            "projects = { '" + (Join-Path $h1Work 'lab\view').ToLowerInvariant() + "' = { trust_level = 'trusted' } }"
        } else { $_ }
    })
    if ($InspectUserRuleLoading) {
        $arguments = @($arguments | Where-Object { $_ -ne '--ignore-user-config' })
        $arguments = @($arguments[0..($arguments.Count-2)]) + @('-c', 'sandbox_mode="workspace-write"', $arguments[-1])
    }
    $arguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'codex-arguments.json') -Encoding utf8
    Push-Location -LiteralPath (Join-Path $h1Work 'lab\view')
    try {
        (Get-Location).Path | Set-Content -LiteralPath (Join-Path $runDir 'launcher-cwd.txt') -Encoding utf8
        & codex @arguments 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath (Join-Path $runDir 'codex-output.log')
        $exitCode = $LASTEXITCODE
    } finally { Pop-Location }
    [PSCustomObject]@{ codexExitCode=$exitCode; fixedResponseCount=(Get-ChildItem -LiteralPath $runDir -Filter 'request-*.json').Count } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'driver-result.json') -Encoding utf8
    if ($exitCode -ne 0) { throw "Codex fixture run exited $exitCode" }
} finally {
    if ($port) { try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/stop" -Method Post -TimeoutSec 3 } catch {} }
    if (!$server.WaitForExit(3000)) { $server.Kill(); $server.WaitForExit() }
    $server.Dispose()
}
