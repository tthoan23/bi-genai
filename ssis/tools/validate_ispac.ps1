# Mở file .ispac do Visual Studio build ra và Validate từng package với database thật (không chạy package).
#   powershell -ExecutionPolicy Bypass -File ssis\tools\validate_ispac.ps1 [-Ispac <đường dẫn>]
param([string]$Ispac)
if (-not $Ispac) { $Ispac = Join-Path $PSScriptRoot '..\OlistETL\OlistETL\bin\Development\OlistETL.ispac' }
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -Path 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.SqlServer.ManagedDTS\v4.0_17.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.ManagedDTS.dll'
function Set-Eager($executables) {
    foreach ($e in $executables) {
        if ($e.PSObject.Properties['DelayValidation']) { $e.DelayValidation = $false }
        if ($e -is [Microsoft.SqlServer.Dts.Runtime.Sequence]) { Set-Eager $e.Executables }
    }
}
$project = [Microsoft.SqlServer.Dts.Runtime.Project]::OpenProject((Resolve-Path $Ispac).Path)
$bad = 0
foreach ($item in $project.PackageItems) {
    $p = $item.Package
    Set-Eager $p.Executables
    $result = $p.Validate($null, $null, $null, $null)
    "{0,-28} {1}" -f $item.StreamName, $result
    if ("$result" -ne 'Success') { $bad++; foreach ($err in $p.Errors) { "    " + $err.Description.Trim() } }
}
$project.Dispose()
if ($bad) { exit 1 }
