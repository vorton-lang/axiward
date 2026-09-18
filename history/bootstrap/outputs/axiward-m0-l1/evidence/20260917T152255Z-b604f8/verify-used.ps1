param(
    [Parameter(Mandatory)][string]$LeanBin,
    [string]$RunsRoot = (Join-Path $PSScriptRoot 'evidence')
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$LeanBin = (Resolve-Path -LiteralPath $LeanBin).Path
$runName = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
$runDir = Join-Path $RunsRoot $runName
New-Item -ItemType Directory -Path $runDir | Out-Null
$runDir = (Resolve-Path -LiteralPath $runDir).Path
$sourceFiles = @('lean-toolchain', 'lakefile.toml', 'Axiward.lean', 'Audit.lean', 'Main.lean',
    'Axiward/Spec.lean', 'Axiward/Queue.lean', 'Axiward/Proofs.lean')
$commands = [Collections.Generic.List[object]]::new()
$record = [ordered]@{
    package = 'M0-L1'; kind = 'exploration'; startedUtc = [DateTime]::UtcNow.ToString('o')
    status = 'running'; sourceRoot = $PSScriptRoot; leanBin = $LeanBin
    observerSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    commands = $commands
}
$lake = Join-Path $LeanBin 'lake.exe'
$originalPath = $env:PATH
$env:PATH = $LeanBin + [IO.Path]::PathSeparator + $env:PATH

function Get-SourceHashes([string]$Root) {
    foreach ($relative in $sourceFiles) {
        [PSCustomObject]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $Root $relative) -Algorithm SHA256).Hash }
    }
}

function Copy-Sources([string]$Destination) {
    New-Item -ItemType Directory -Path (Join-Path $Destination 'Axiward') -Force | Out-Null
    foreach ($relative in $sourceFiles) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination (Join-Path $Destination $relative)
    }
}

function Invoke-Step([string]$Name, [string]$File, [string[]]$Arguments,
                     [string]$Directory, [switch]$ExpectFailure) {
    $logName = $Name + '.log'
    $started = [DateTime]::UtcNow
    Push-Location -LiteralPath $Directory
    try {
        $lines = @(& $File @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    $output = $lines -join "`n"
    [IO.File]::WriteAllText((Join-Path $runDir $logName), $output + "`n")
    $commands.Add([PSCustomObject]@{
        name = $Name; file = $File; arguments = $Arguments; cwd = $Directory
        exitCode = $code; log = $logName; startedUtc = $started.ToString('o')
        durationSeconds = ([DateTime]::UtcNow - $started).TotalSeconds
    })
    Write-Host "$Name : exit $code"
    if ((!$ExpectFailure -and $code -ne 0) -or ($ExpectFailure -and $code -eq 0)) {
        throw "Unexpected exit for $Name ($code). Read $runDir\$logName"
    }
    return $output
}

try {
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $runDir 'verify-used.ps1')
    $project = Join-Path $runDir 'project'
    Copy-Sources $project
    $record.inputs = @(Get-SourceHashes $project)
    $record.toolExecutables = @(foreach ($name in @('lean.exe', 'lake.exe', 'leanchecker.exe', 'clang.exe', 'ld.lld.exe')) {
        [PSCustomObject]@{ name = $name; sha256 = (Get-FileHash -LiteralPath (Join-Path $LeanBin $name) -Algorithm SHA256).Hash }
    })
    $version = Invoke-Step '01-lean-version' (Join-Path $LeanBin 'lean.exe') @('--version') $project
    if ($version -notmatch 'version 4\.34\.0,') { throw "Expected Lean 4.34.0; received $version" }
    $record.leanVersion = $version
    $record.lakeVersion = Invoke-Step '02-lake-version' $lake @('--version') $project
    $null = Invoke-Step '03-build' $lake @('--no-cache', '--wfail', 'build') $project
    $audit = Invoke-Step '04-axioms' $lake @('env', 'lean', '-DwarningAsError=true', 'Audit.lean') $project
    # A manual-review aid for this fixed example, not an admission policy for hostile proofs.
    if ($audit -match 'sorryAx|trustCompiler|_native') { throw 'Unexpected proof assumption; inspect axiom log' }
    $null = Invoke-Step '05-kernel-replay' $lake @('env', 'leanchecker', '--fresh', 'Axiward.Proofs') $project

    $exe = Join-Path $project '.lake/build/bin/fifo_demo.exe'
    $regular = Invoke-Step '06-runtime-fifo' $exe @('2', 'alpha', 'beta', 'gamma') $project
    $expectedRegular = @(
        'created capacity=2 length=0',
        'enqueue alpha: accepted=true length=1 capacity=2',
        'enqueue beta: accepted=true length=2 capacity=2',
        'enqueue gamma: accepted=false length=2 capacity=2',
        'dequeue: value=alpha length=1 capacity=2',
        'dequeue: value=beta length=0 capacity=2',
        'dequeue: empty length=0 capacity=2'
    ) -join "`n"
    if ($regular -cne $expectedRegular) { throw 'Compiled FIFO example output differs from expectation' }
    $zero = Invoke-Step '07-runtime-zero' $exe @('0', 'alpha') $project
    $expectedZero = @(
        'created capacity=0 length=0',
        'enqueue alpha: accepted=false length=0 capacity=0',
        'dequeue: empty length=0 capacity=0'
    ) -join "`n"
    if ($zero -cne $expectedZero) { throw 'Compiled zero-capacity output differs from expectation' }

    # Change only the enqueue position; keep the specification and proof text identical.
    $mutant = Join-Path $runDir 'mutant'
    Copy-Sources $mutant
    $queuePath = Join-Path $mutant 'Axiward/Queue.lean'
    $queueText = [IO.File]::ReadAllText($queuePath)
    $original = 'let nextItems := q.items ++ [item]'
    $replacement = 'let nextItems := item :: q.items'
    if (($queueText.Split($original, [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw 'Expected exactly one mutation site'
    }
    [IO.File]::WriteAllText($queuePath, $queueText.Replace($original, $replacement))
    $record.mutantInputs = @(Get-SourceHashes $mutant)
    $record.mutation = @{ original = $original; replacement = $replacement }
    $null = Invoke-Step '08-mutant-build-executable' $lake @('--no-cache', '--wfail', 'build', 'fifo_demo') $mutant
    $mutantOutput = Invoke-Step '09-mutant-runtime' (Join-Path $mutant '.lake/build/bin/fifo_demo.exe') @('2', 'alpha', 'beta') $mutant
    if ($mutantOutput -notmatch 'dequeue: value=beta length=1 capacity=2\ndequeue: value=alpha length=0 capacity=2') {
        throw 'Negative control did not exhibit the intended LIFO error'
    }
    $rejection = Invoke-Step '10-mutant-proof-rejected' $lake @('--no-cache', '--wfail', 'build', 'Axiward') $mutant -ExpectFailure
    if ($rejection -notmatch 'Proofs\.lean' -or $rejection -notmatch 'unsolved goals') {
        throw 'Negative control failed for a reason other than the expected proof obligation'
    }

    $before = $record.inputs | ConvertTo-Json -Compress
    $after = @(Get-SourceHashes $project) | ConvertTo-Json -Compress
    if ($before -cne $after) { throw 'Accepted source snapshot changed during verification' }
    $record.products = @(foreach ($relative in @('.lake/build/bin/fifo_demo.exe',
        '.lake/build/ir/Axiward/Queue.c', '.lake/build/lib/lean/Axiward/Queue.olean',
        '.lake/build/lib/lean/Axiward/Proofs.olean')) {
        [PSCustomObject]@{ path = 'project/' + $relative; sha256 = (Get-FileHash -LiteralPath (Join-Path $project $relative) -Algorithm SHA256).Hash }
    })
    $record.status = 'passed'
} catch {
    $record.status = 'failed'
    $record.failure = $_.Exception.Message
    throw
} finally {
    $record.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDir 'result.json') -Encoding utf8
    $env:PATH = $originalPath
    Write-Host "Evidence: $runDir"
}
