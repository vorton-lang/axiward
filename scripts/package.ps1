param(
    [Parameter(Mandatory = $true)][string]$Toolchain,
    [Parameter(Mandatory = $true)][string]$Destination
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $outputRoot) { throw 'Destination must be a new directory; existing files are never removed.' }
$lake = Join-Path $Toolchain 'bin\lake.exe'
Push-Location -LiteralPath $sourceRoot
try {
    & $lake build axiward Axiward
    if ($LASTEXITCODE -ne 0) { throw 'Lean build failed.' }
    & $lake env lean Tests/Audit.lean
    if ($LASTEXITCODE -ne 0) { throw 'Kernel audit failed.' }
    & $lake env leanchecker Axiward
    if ($LASTEXITCODE -ne 0) { throw 'Kernel replay failed.' }
    New-Item -ItemType Directory -Path $outputRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot '.lake\build\bin\axiward.exe') -Destination $outputRoot
    foreach ($file in @('LICENSE', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination $outputRoot
    }
    foreach ($directory in @('docs', 'examples')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $directory) -Destination $outputRoot -Recurse
    }
    $adapterOutput = Join-Path $outputRoot 'adapter'
    New-Item -ItemType Directory -Path $adapterOutput | Out-Null
    foreach ($file in @('server.py', 'native.py')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot "adapter\$file") -Destination $adapterOutput
    }
    $noticeOutput = Join-Path $outputRoot 'third-party'
    New-Item -ItemType Directory -Path $noticeOutput | Out-Null
    Copy-Item -LiteralPath (Join-Path $Toolchain 'LICENSE') -Destination (Join-Path $noticeOutput 'Lean-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $Toolchain 'LICENSES') -Destination (Join-Path $noticeOutput 'Lean-LICENSES.txt')
    'Axiward project code is MIT licensed. The compiled executable includes Lean runtime components. Upstream Lean 4.34.0 license and bundled-component notices are retained here; the full external toolchain is not included.' |
        Set-Content -LiteralPath (Join-Path $noticeOutput 'README.txt') -Encoding utf8NoBOM
    $manifest = Get-ChildItem -LiteralPath $outputRoot -File -Recurse | ForEach-Object {
        [ordered]@{
            file = [IO.Path]::GetRelativePath($outputRoot, $_.FullName).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    [ordered]@{ version = '0.1.0'; platform = 'windows-x64'; lean = '4.34.0'; files = @($manifest) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'manifest.json') -Encoding utf8NoBOM
    & (Join-Path $outputRoot 'axiward.exe') --version
    if ($LASTEXITCODE -ne 0) { throw 'Packaged executable cannot start.' }
    Compress-Archive -LiteralPath $outputRoot -DestinationPath ($outputRoot + '.zip')
    Write-Output "Package: $outputRoot.zip"
} finally {
    Pop-Location
}
