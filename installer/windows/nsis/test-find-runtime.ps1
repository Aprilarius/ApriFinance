$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-runtime.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('apri-runtime-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $old = Join-Path $fixture 'VC/Redist/MSVC/14.40.33810/x64/Microsoft.VC143.CRT'
    $new = Join-Path $fixture 'VC/Redist/MSVC/14.51.36231/x64/Microsoft.VC145.CRT'
    $partial = Join-Path $fixture 'VC/Redist/MSVC/14.52.10000/x64/Microsoft.VC145.CRT'
    foreach ($directory in @($old, $new, $partial)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $files = if ($directory -eq $partial) { @('msvcp140.dll') } else { @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') }
        foreach ($name in $files) { [IO.File]::WriteAllText((Join-Path $directory $name), 'fixture') }
    }
    if ((Find-AprifinanceVcRuntime $fixture) -ne $new) { throw 'Newest complete x64 runtime not selected' }
    $onlyOld = Join-Path $fixture 'old-layout'
    $oldOnlyRuntime = Join-Path $onlyOld 'VC/Redist/MSVC/14.40.33810/x64/Microsoft.VC143.CRT'
    New-Item -ItemType Directory -Path $oldOnlyRuntime -Force | Out-Null
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        [IO.File]::WriteAllText((Join-Path $oldOnlyRuntime $name), 'fixture')
    }
    if ((Find-AprifinanceVcRuntime $onlyOld) -ne $oldOnlyRuntime) { throw 'VC143 compatibility lost' }
    $rejected = $false
    try { Find-AprifinanceVcRuntime (Join-Path $fixture 'missing') | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'Missing runtime accepted' }
    Write-Output 'PASS: VC143, newer CRT layout, partial-version fallback and missing-runtime rejection'
} finally {
    $actual = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (!$actual.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or !(Split-Path $actual -Leaf).StartsWith('apri-runtime-')) {
        throw 'Unexpected fixture cleanup path'
    }
    Remove-Item -LiteralPath $actual -Recurse -Force
}
