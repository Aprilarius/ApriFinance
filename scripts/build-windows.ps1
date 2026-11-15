param([Parameter(Mandatory = $true)][string]$Compiler, [string]$OutputDirectory, [string]$RuntimeDirectory)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$compilerPath = (Resolve-Path -LiteralPath $Compiler).Path
if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
Push-Location $root
try {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    & flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    $parameters = @{ Compiler = $compilerPath; OutputDirectory = $outputPath }
    if ($RuntimeDirectory) { $parameters.RuntimeDirectory = $RuntimeDirectory }
    & './installer/windows/nsis/build.ps1' @parameters
} finally { Pop-Location }
