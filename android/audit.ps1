param([ValidateSet('Debug', 'Release')][string]$Variant = 'Debug')
$ErrorActionPreference = 'Stop'
$properties = Join-Path $PSScriptRoot 'local.properties'
if (!(Test-Path -LiteralPath $properties)) { throw 'Run a Flutter Android build to generate local.properties first' }
$registrant = Join-Path $PSScriptRoot 'app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
if ($Variant -eq 'Release' -and (Test-Path -LiteralPath $registrant) -and
    (Select-String -LiteralPath $registrant -Pattern 'dev.flutter.plugins.integration_test' -Quiet)) {
    throw 'Flutter generated a development plugin registrant. Run flutter build apk --release with your signing key immediately before release Lint.'
}
# Flutter's generated Windows drive colon triggers PropertyEscape in Android
# Lint. Normalize only generated SDK paths; don't suppress the detector.
$lines = Get-Content -LiteralPath $properties | ForEach-Object {
    if ($_ -match '^(flutter\.sdk|sdk\.dir)=(.*)$') {
        $propertyName = $Matches[1]
        $propertyValue = $Matches[2] -replace '(?<!\\):', '\:'
        "$propertyName=$propertyValue"
    } else { $_ }
}
$lines | Set-Content -LiteralPath $properties -Encoding utf8
Push-Location $PSScriptRoot
try {
    & './gradlew.bat' (':app:lint' + $Variant) '--console=plain'
    if ($LASTEXITCODE -ne 0) { throw "Android Lint $Variant failed" }
} finally { Pop-Location }
