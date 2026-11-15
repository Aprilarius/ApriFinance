$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$previous = $env:APRIFINANCE_NATIVE_TEST
Push-Location $root
try {
    $env:APRIFINANCE_NATIVE_TEST = '1'
    foreach ($name in @('local_flow_test', 'series_flow_test', 'completion_flow_test', 'ledger_flow_test', 'windows_instance_test', 'secure_credentials_test')) {
        & flutter test ("integration_test/$name.dart") -d windows
        if ($LASTEXITCODE -ne 0) { throw "Native test failed: $name" }
    }
} finally {
    if ($null -eq $previous) { Remove-Item Env:APRIFINANCE_NATIVE_TEST -ErrorAction SilentlyContinue } else { $env:APRIFINANCE_NATIVE_TEST = $previous }
    Pop-Location
}
