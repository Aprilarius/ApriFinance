param(
    [Parameter(Mandatory = $true)][string]$Compiler,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$RuntimeDirectory,
    [switch]$InstallerQA
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$match = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Pattern '^version: (\d+\.\d+\.\d+)\+(\d+)$'
if (!$match) { throw 'Missing numeric app version' }
$version = $match.Matches[0].Groups[1].Value
$internalVersion = $version + '.' + $match.Matches[0].Groups[2].Value
$release = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$exe = Join-Path $release 'ApriFinance.exe'
if (!(Test-Path -LiteralPath $exe)) { throw 'Build ApriFinance Windows release first' }
if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne ($version + '+' + $match.Matches[0].Groups[2].Value)) { throw 'Stale executable build number' }
$compiledDart = Join-Path $release 'data/app.so'
$latestSource = (Get-ChildItem -LiteralPath (Join-Path $projectRoot 'lib') -Filter '*.dart' -Recurse -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
if ((Get-Item -LiteralPath $compiledDart).LastWriteTimeUtc -lt $latestSource) { throw 'Dart payload predates source changes; rebuild Windows release' }
$stage = Join-Path $projectRoot ('build/windows/nsis-stage/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
# Allowlist the app entry point: old personal_finance.exe can remain in build output.
Copy-Item -LiteralPath $exe -Destination $stage
Get-ChildItem -LiteralPath $release -File | Where-Object { $_.Extension -in @('.dll', '.json') } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage }
Copy-Item -LiteralPath (Join-Path $release 'data') -Destination $stage -Recurse
if (!$RuntimeDirectory) {
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vsRoot = & $vsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$vsRoot) { throw 'Visual C++ tools missing; specify RuntimeDirectory' }
    . (Join-Path $PSScriptRoot 'find-runtime.ps1')
    $RuntimeDirectory = Find-AprifinanceVcRuntime -VisualStudioRoot $vsRoot
}
Get-ChildItem -LiteralPath $RuntimeDirectory -Filter '*.dll' -File | ForEach-Object {
    $signature = Get-AuthenticodeSignature -LiteralPath $_.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') { throw "Unverified CRT: $($_.Name)" }
    Copy-Item -LiteralPath $_.FullName -Destination $stage -Force
}
foreach ($required in @('ApriFinance.exe', 'flutter_windows.dll', 'sqlite3.dll', 'data/app.so', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (!(Test-Path -LiteralPath (Join-Path $stage $required))) { throw "Missing payload: $required" }
}
$files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
foreach ($file in $files) {
    if ($file.Name -match '\.(sqlite|sqlite-wal|sqlite-shm|mfin|jks|keystore|pfx)$' -or $file.Name -in @('key.properties', '.env', 'cloud.json', 'reminders.json')) { throw 'Private file in payload' }
}
$include = Join-Path (Split-Path -Parent $stage) ([guid]::NewGuid().ToString('N') + '-uninstall.nsh')
function Escape-Nsis([string]$Value) { return $Value.Replace('$', '$$').Replace('"', '$\"') }
$lines = [Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($stage, $file.FullName)
    $lines.Add('Delete "$INSTDIR\' + (Escape-Nsis $relative) + '"')
}
Get-ChildItem -LiteralPath $stage -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    $lines.Add('RMDir "$INSTDIR\' + (Escape-Nsis ([IO.Path]::GetRelativePath($stage, $_.FullName))) + '"')
}
$lines | Set-Content -LiteralPath $include -Encoding utf8
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$suffix = if ($InstallerQA) { '-QA' } else { '' }
$installer = Join-Path $outputRoot "ApriFinance-$version-Windows-x64-Setup$suffix.exe"
$arguments = @('/V2', '/WX', '/INPUTCHARSET', 'UTF8', ('/DAppVersion=' + $version), ('/DAppInternalVersion=' + $internalVersion), ('/DPayloadDir=' + $stage), ('/DOutputFile=' + $installer), ('/DUninstallFiles=' + $include), ('/DAppIcon=' + (Join-Path $projectRoot 'windows/runner/resources/app_icon.ico')))
if ($InstallerQA) { $arguments += '/DInstallerQA' }
$arguments += (Join-Path $PSScriptRoot 'setup.nsi')
& $Compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'NSIS compilation failed' }
[ordered]@{
    version = $version; internalVersion = $internalVersion; installer = $installer; compiler = 'NSIS 3.13'; testIdentity = [bool]$InstallerQA
    installerSha256 = (Get-FileHash -LiteralPath $installer).Hash.ToLowerInvariant()
    payload = $stage
    files = @($files | ForEach-Object { [ordered]@{ path = [IO.Path]::GetRelativePath($stage, $_.FullName); sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() } })
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath ($installer + '.manifest.json') -Encoding utf8
Write-Output $installer
