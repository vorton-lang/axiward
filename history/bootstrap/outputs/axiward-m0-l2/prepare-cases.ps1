$ErrorActionPreference = 'Stop'
$outputs = Split-Path -Parent $PSScriptRoot
$work = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\work\m0-l2'))
$candidateRoot = Join-Path $work 'candidates'
$queue = [IO.File]::ReadAllText((Join-Path $outputs 'axiward-m0-l1\Axiward\Queue.lean'))
$proofs = [IO.File]::ReadAllText((Join-Path $outputs 'axiward-m0-l1\Axiward\Proofs.lean'))
$rootProof = "theorem satisfies_Q0 (α : Type u) (n : Nat) : SatisfiesQ0 α n :=`n  ⟨created α n, enqueue_room, enqueue_full, dequeue_some, dequeue_empty, measured⟩"
if (!$proofs.Contains($rootProof)) { throw 'L1 proof shape changed; inspect before generating fixtures' }
$wrongQueue = $queue.Replace('let nextItems := q.items ++ [item]', 'let nextItems := item :: q.items')
$functionStart = $queue.IndexOf('def enqueue ')
$functionEnd = $queue.IndexOf('def dequeue ')
$enqueue = $queue.Substring($functionStart, $functionEnd-$functionStart)
$runtime = $enqueue.Replace('def enqueue ', 'def enqueueRuntime ').Replace('let nextItems := q.items ++ [item]', 'let nextItems := item :: q.items')
$runtimeQueue = $queue.Replace($enqueue, $runtime + "@[implemented_by enqueueRuntime]`n" + $enqueue)
$cases = @(
    @{name='correct'; queue=$queue; proofs=$proofs},
    @{name='wrong-fifo'; queue=$wrongQueue; proofs=$proofs},
    @{name='goal-swap'; queue=$queue; proofs=$proofs.Replace($rootProof, 'theorem satisfies_Q0 (_α : Type u) (_n : Nat) : True := True.intro')},
    @{name='extra-axiom'; queue=$queue; proofs=$proofs.Replace($rootProof, "axiom trustMe (α : Type u) (n : Nat) : SatisfiesQ0 α n`n`ntheorem satisfies_Q0 (α : Type u) (n : Nat) : SatisfiesQ0 α n := trustMe α n")},
    @{name='sorry-proof'; queue=$queue; proofs=$proofs.Replace($rootProof, 'theorem satisfies_Q0 (α : Type u) (n : Nat) : SatisfiesQ0 α n := by sorry')},
    @{name='runtime-swap'; queue=$runtimeQueue; proofs=$proofs},
    @{name='stale-proof'; queue=$wrongQueue; proofs=$proofs},
    @{name='spec-swap'; queue=$queue; proofs=$proofs}
)
foreach ($case in $cases) {
    $directory = Join-Path $candidateRoot $case.name
    if (Test-Path -LiteralPath $directory) { throw "Candidate already exists: $directory" }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory 'Queue.lean'), $case.queue)
    [IO.File]::WriteAllText((Join-Path $directory 'Proofs.lean'), $case.proofs)
}
[IO.File]::WriteAllText((Join-Path $candidateRoot 'spec-swap\Spec.lean'), 'def fakeSpecification : Prop := True')
$staleDir = Join-Path $candidateRoot 'stale-proof\.lake\build\lib\lean\Axiward'
New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
$oldProof = Join-Path $outputs 'axiward-m0-l1\evidence\20260917T152318Z-24a3ab\project\.lake\build\lib\lean\Axiward\Proofs.olean'
Copy-Item -LiteralPath $oldProof -Destination (Join-Path $staleDir 'Proofs.olean')
$cases | ForEach-Object {
    $directory = Join-Path $candidateRoot $_.name
    [PSCustomObject]@{name=$_.name; queueHash=(Get-FileHash -LiteralPath (Join-Path $directory 'Queue.lean') -Algorithm SHA256).Hash; proofHash=(Get-FileHash -LiteralPath (Join-Path $directory 'Proofs.lean') -Algorithm SHA256).Hash}
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $work 'candidate-inputs.json') -Encoding utf8
$cases.name
