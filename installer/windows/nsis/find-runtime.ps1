function Find-AprifinanceVcRuntime {
    param([Parameter(Mandatory = $true)][string]$VisualStudioRoot)
    $redist = Join-Path $VisualStudioRoot 'VC/Redist/MSVC'
    if (!(Test-Path -LiteralPath $redist -PathType Container)) {
        throw 'Visual C++ redistributable files missing; specify RuntimeDirectory'
    }
    $versions = Get-ChildItem -LiteralPath $redist -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending
    foreach ($version in $versions) {
        $x64 = Join-Path $version.FullName 'x64'
        if (!(Test-Path -LiteralPath $x64 -PathType Container)) { continue }
        $runtimes = Get-ChildItem -LiteralPath $x64 -Directory |
            Where-Object { $_.Name -match '^Microsoft\.VC\d+\.CRT$' } |
            Sort-Object Name -Descending
        foreach ($runtime in $runtimes) {
            $missing = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') |
                Where-Object { !(Test-Path -LiteralPath (Join-Path $runtime.FullName $_) -PathType Leaf) }
            if (!$missing) { return $runtime.FullName }
        }
    }
    throw 'Complete x64 Visual C++ runtime missing; specify RuntimeDirectory'
}
