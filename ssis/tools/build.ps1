# Biên dịch và chạy trình dựng package SSIS. Cần Visual Studio có extension SSIS, SQL Server đang chạy,
# và đã chạy sql_server/00..08 (trình dựng đọc metadata bảng thật để cấu hình từng cột).
#   powershell -ExecutionPolicy Bypass -File ssis\tools\build.ps1                       # ghi đè .dtsx trong project
#   powershell -ExecutionPolicy Bypass -File ssis\tools\build.ps1 -Output C:\tam -Only Clean
param(
    [string]$Server = 'localhost\SQLEXPRESS',
    [string]$Output,
    [string]$Only
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Output) { $Output = Join-Path $repo 'ssis\OlistETL\OlistETL' }
$gac = 'C:\Windows\Microsoft.NET\assembly'
$ver = 'v4.0_17.0.0.0__89845dcd8080cc91'
# Execute SQL Task (đọc kết quả truy vấn vào biến) không nằm trong GAC: lấy từ bản cài SQL Server 2025
$sqlTask = 'C:\Program Files\Microsoft SQL Server\170\DTS\Tasks\Microsoft.SqlServer.SQLTask.dll'
$refs = @(
    "$gac\GAC_MSIL\Microsoft.SqlServer.ManagedDTS\$ver\Microsoft.SqlServer.ManagedDTS.dll",
    "$gac\GAC_MSIL\Microsoft.SqlServer.DTSPipelineWrap\$ver\Microsoft.SqlServer.DTSPipelineWrap.dll",
    "$gac\GAC_64\Microsoft.SqlServer.DTSRuntimeWrap\$ver\Microsoft.SqlServer.DTSRuntimeWrap.dll",
    $sqlTask
) | ForEach-Object { "-r:$_" }
$work = Join-Path $env:TEMP 'olist-ssis-build'
New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item $sqlTask $work -Force
$exe = Join-Path $work 'BuildOlistEtl.exe'
& 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' -nologo -codepage:65001 -platform:x64 "-out:$exe" $refs `
    (Join-Path $PSScriptRoot 'SsisBuilder.cs') (Join-Path $PSScriptRoot 'BuildOlistEtl.cs')
if ($LASTEXITCODE -ne 0) { throw 'Biên dịch thất bại' }
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$extra = @($repo, $Server, $Output); if ($Only) { $extra += $Only }
& $exe $extra
exit $LASTEXITCODE
