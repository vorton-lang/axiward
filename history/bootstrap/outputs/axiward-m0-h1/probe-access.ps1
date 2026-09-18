param([Parameter(Mandatory)][string]$Lab)

$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.List[object]]::new()
function Observe([string]$Name, [scriptblock]$Action) {
    try {
        $value = & $Action
        $results.Add([PSCustomObject]@{ name = $Name; allowed = $true; value = $value })
    } catch {
        $results.Add([PSCustomObject]@{ name = $Name; allowed = $false; error = $_.Exception.Message })
    }
}

Observe 'read-view' { [IO.File]::ReadAllText((Join-Path $Lab 'view\visible.txt')) }
Observe 'write-view' { [IO.File]::WriteAllText((Join-Path $Lab 'view\candidate.txt'), 'candidate=1'); 'written' }
Observe 'read-repository' { [IO.File]::ReadAllText((Join-Path $Lab 'repository\private.txt')) }
Observe 'read-repository-traversal' { [IO.File]::ReadAllText((Join-Path $Lab 'view\..\repository\private.txt')) }
Observe 'write-repository' { [IO.File]::WriteAllText((Join-Path $Lab 'repository\write-attempt.txt'), 'unexpected direct write'); 'written' }
Observe 'read-other-task' { [IO.File]::ReadAllText((Join-Path $Lab 'other-task\visible.txt')) }
Observe 'write-other-task' { [IO.File]::WriteAllText((Join-Path $Lab 'other-task\write-attempt.txt'), 'unexpected cross-task write'); 'written' }

[PSCustomObject]@{ user = [Security.Principal.WindowsIdentity]::GetCurrent().Name; cwd = (Get-Location).Path; results = $results } | ConvertTo-Json -Depth 4
