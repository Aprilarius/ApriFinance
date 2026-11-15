param(
    [Parameter(Mandatory = $true)][string]$OldInstaller,
    [Parameter(Mandatory = $true)][string]$NewInstaller,
    [Parameter(Mandatory = $true)][string]$WorkDirectory,
    [Parameter(Mandatory = $true)][string]$FixtureDirectory
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($WorkDirectory)
$program = Join-Path $root 'Apri Finance program'
$oldProgram = Join-Path $root 'legacy-program'
$fixture = (Resolve-Path -LiteralPath $FixtureDirectory).Path
$newKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ApriFinance.InstallerQA'
$oldKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MyFinances.Personal.Desktop.InstallerQA_is1'
$title = 'ApriFinance — QA'
$oldTitle = 'Мои финансы — проверка установщика'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) "$title.lnk"
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) $title
$steps = [Collections.Generic.List[string]]::new()
function Assert([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
foreach ($installer in @($OldInstaller, $NewInstaller)) {
    $manifest = Get-Content -LiteralPath ($installer + '.manifest.json') -Raw | ConvertFrom-Json
    Assert ($manifest.testIdentity -eq $true) 'Only isolated QA installers allowed'
    Assert ((Get-FileHash -LiteralPath $installer).Hash.ToLowerInvariant() -eq $manifest.installerSha256) 'Installer hash mismatch'
}
$payload = Get-Content -LiteralPath ($NewInstaller + '.manifest.json') -Raw | ConvertFrom-Json
foreach ($path in @($newKey, $oldKey, $program, $oldProgram, $desktop, $menu,
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$oldTitle.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) $oldTitle))) {
    Assert (!(Test-Path -LiteralPath $path)) "Preexisting QA target: $path"
}
New-Item -ItemType Directory -Path $root -Force | Out-Null
function Hashes([string]$Directory) {
    $result = [ordered]@{}
    Get-ChildItem -LiteralPath $Directory -Recurse -File | Sort-Object FullName | ForEach-Object {
        $result[[IO.Path]::GetRelativePath($Directory, $_.FullName)] = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
    return ($result | ConvertTo-Json -Compress)
}
$original = Hashes $fixture
function Run([string]$File, [string[]]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
    return $process.ExitCode
}
function Check-Data {
    Assert ((Hashes $fixture) -eq $original) 'External fixture changed'
    foreach ($directory in @((Join-Path $oldProgram 'custom-local-data'), (Join-Path $program 'custom-local-data'))) {
        if (Test-Path -LiteralPath $directory) { Assert ((Hashes $directory) -eq $original) 'Unknown local files changed' }
    }
}
function Check-Installed {
    Assert ((Get-ItemProperty -LiteralPath $newKey).DisplayVersion -eq $payload.internalVersion) 'Wrong registered version'
    Assert ((Get-ItemProperty -LiteralPath $newKey).InstallLocation -eq $program) 'Wrong install location'
    foreach ($file in $payload.files) {
        Assert ((Get-FileHash -LiteralPath (Join-Path $program $file.path)).Hash.ToLowerInvariant() -eq $file.sha256) "Payload mismatch: $($file.path)"
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($link in @($desktop, (Join-Path $menu "$title.lnk"))) {
        Assert (Test-Path -LiteralPath $link) 'Shortcut missing'
        $shortcut = $shell.CreateShortcut($link)
        Assert ($shortcut.TargetPath -eq (Join-Path $program 'ApriFinance.exe')) 'Wrong shortcut target'
        Assert ($shortcut.WorkingDirectory -eq $program) 'Wrong shortcut working directory'
    }
    Check-Data
}
Assert ((Run $NewInstaller @('/S', ('/D=' + $fixture))) -ne 0) 'Data folder not protected'
Assert ((Hashes $fixture) -eq $original) 'Rejected setup changed data'
Assert (!(Test-Path -LiteralPath $newKey)) 'Rejected setup registered app'
$steps.Add('Data-directory installation rejected before writing files')
try {
    $oldExit = Run $OldInstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/TASKS=desktopicon', ('/DIR="' + $oldProgram + '"'))
    Assert ($oldExit -eq 0) 'Legacy QA install failed'
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $oldProgram 'custom-local-data') -Recurse
    $mutex = [Threading.Mutex]::new($false, 'Local\MyFinances.InstallerQA.Running')
    try {
        Assert ((Run $NewInstaller @('/S', ('/D=' + $program))) -ne 0) 'Running app not protected'
        Assert (Test-Path -LiteralPath $oldKey) 'Blocked setup removed old registration'
        Assert (!(Test-Path -LiteralPath $newKey)) 'Blocked setup registered new app'
        Check-Data
    } finally { $mutex.Dispose() }
    $steps.Add('Running-app mutex blocks migration without closing any process')
    Assert ((Run $NewInstaller @('/S', '/DESKTOP=1', ('/D=' + $program))) -eq 0) 'NSIS migration failed'
    Assert (!(Test-Path -LiteralPath $oldKey)) 'Old uninstall registration remains'
    Assert (!(Test-Path -LiteralPath (Join-Path $oldProgram 'personal_finance.exe'))) 'Old executable remains'
    Assert (!(Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) "$oldTitle.lnk"))) 'Old shortcut remains'
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $program 'custom-local-data') -Recurse
    Check-Installed
    $steps.Add('Inno 0.8.1 to NSIS 1.0 migration removes old program/registration and preserves financial fixtures')
    Assert ((Run $NewInstaller @('/S')) -eq 0) 'NSIS repair failed'
    Check-Installed
    $steps.Add('Same-version update reuses directory containing spaces; all payload hashes and both shortcuts match')
    $installedVersion = [version]$payload.internalVersion
    $newerInternal = $installedVersion.ToString(3) + '.' + ($installedVersion.Revision + 1)
    foreach ($newer in @('2.0.0', $newerInternal)) {
        Set-ItemProperty -LiteralPath $newKey -Name DisplayVersion -Value $newer
        try {
            Assert ((Run $NewInstaller @('/S')) -ne 0) 'Newer registered version not protected'
        } finally { Set-ItemProperty -LiteralPath $newKey -Name DisplayVersion -Value $payload.internalVersion }
    }
    Check-Installed
    $steps.Add('Simulated newer public and internal build versions block downgrade')
    $mutex = [Threading.Mutex]::new($false, 'Local\MyFinances.InstallerQA.Running')
    try {
        Assert ((Run (Join-Path $program 'Uninstall.exe') @('/S', ('_?=' + $program))) -ne 0) 'Running-app uninstall not blocked'
        Check-Installed
    } finally { $mutex.Dispose() }
    $steps.Add('Running-app mutex blocks uninstall and preserves files')
} finally {
    $uninstaller = Join-Path $program 'Uninstall.exe'
    if (Test-Path -LiteralPath $uninstaller) { $null = Run $uninstaller @('/S') }
    $legacyUninstaller = Join-Path $oldProgram 'unins000.exe'
    if (Test-Path -LiteralPath $legacyUninstaller) { $null = Run $legacyUninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') }
}
for ($attempt = 0; $attempt -lt 50 -and (Test-Path -LiteralPath $newKey); $attempt++) { Start-Sleep -Milliseconds 100 }
foreach ($path in @($newKey, $oldKey, $desktop, (Join-Path $menu "$title.lnk"), (Join-Path $program 'ApriFinance.exe'))) {
    Assert (!(Test-Path -LiteralPath $path)) "Uninstall left program item: $path"
}
Assert (Test-Path -LiteralPath (Join-Path $program 'custom-local-data/finance.sqlite')) 'Uninstall removed unknown data'
Check-Data
$steps.Add('Uninstall removes installed program, registry and shortcuts; SQLite/PDF/encrypted backup remain byte-for-byte in external and unknown nested directories')
[ordered]@{ passed = $true; compiler = 'NSIS 3.13'; version = $payload.internalVersion; realUserDataAccessed = $false; applicationLaunched = $false; steps = $steps.ToArray() } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'result.json') -Encoding utf8
$steps
