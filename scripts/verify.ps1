$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $root
try {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
    & dart format --output=none --set-exit-if-changed lib test integration_test tool
    if ($LASTEXITCODE -ne 0) { throw 'Formatting check failed' }
    & flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
    & flutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
} finally { Pop-Location }
