$ErrorActionPreference = 'Stop'

$tools = $PSScriptRoot
$project = Split-Path -Parent $tools
$sources = Join-Path $project 'Scripts'
$assemblies = Join-Path $sources 'assemblies'
$template = Join-Path $tools 'script_component_template'
$temp = Join-Path $env:TEMP 'olistetl-build-assemblies'

if (!(Test-Path -LiteralPath $assemblies)) {
    New-Item -ItemType Directory -Path $assemblies | Out-Null
}
if (Test-Path -LiteralPath $temp) {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
New-Item -ItemType Directory -Path $temp | Out-Null

$sdk = Get-ChildItem 'C:\Program Files\dotnet\sdk' -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1 -ExpandProperty FullName
$csc = Join-Path $sdk 'Roslyn\bincore\csc.dll'
$fw = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319'
$gac = 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL'
$gac64 = 'C:\Windows\Microsoft.NET\assembly\GAC_64'

$taskRefs = @(
    "$fw\mscorlib.dll",
    "$fw\System.dll",
    "$fw\System.Core.dll",
    "$fw\System.Data.dll",
    "$fw\System.Xml.dll",
    "$gac\Microsoft.SqlServer.ManagedDTS\v4.0_16.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.ManagedDTS.dll",
    "$gac\Microsoft.SqlServer.ScriptTask\v4.0_16.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.ScriptTask.dll"
)

$scriptResults = @'
enum ScriptResults
{
    Success = Microsoft.SqlServer.Dts.Runtime.DTSExecResult.Success,
    Failure = Microsoft.SqlServer.Dts.Runtime.DTSExecResult.Failure
}
'@
Set-Content -LiteralPath (Join-Path $temp 'ScriptResults.cs') -Value $scriptResults -Encoding UTF8 -NoNewline

foreach ($name in 'CheckCsvHeader', 'ComputeSha256') {
    $cscArgs = @('/nologo', '/target:library', '/nostdlib+', "/out:$assemblies\$name.dll")
    foreach ($ref in $taskRefs) {
        $cscArgs += "/r:$ref"
    }
    $cscArgs += (Join-Path $sources "$name.cs")
    $cscArgs += (Join-Path $temp 'ScriptResults.cs')
    & dotnet $csc @cscArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Compile failed for $name"
    }
}

foreach ($i in 0, 3, 6, 9, 12, 15, 18, 21, 24, 27) {
    $fileName = (Get-Content -LiteralPath (Join-Path $template ('{0:D2}.txt' -f $i)) -Encoding UTF8 -TotalCount 1).Trim()
    $content = Get-Content -LiteralPath (Join-Path $template ('{0:D2}.txt' -f ($i + 2))) -Raw -Encoding UTF8
    if ($fileName -eq 'main.cs') {
        $content = Get-Content -LiteralPath (Join-Path $sources 'RowNumberScriptComponent.cs') -Raw -Encoding UTF8
    }
    $content = $content.
        Replace('SC_3135bfb0b3bf460c83f93b645813d067', 'SC_9f6a4c21e7b748d3a1c2e5f8b0d47a63').
        Replace('RowId', 'source_row_number')
    $destination = Join-Path $temp $fileName
    $directory = Split-Path -Parent $destination
    if (!(Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    Set-Content -LiteralPath $destination -Value $content -Encoding UTF8 -NoNewline
}

$componentRefs = @(
    "$fw\mscorlib.dll",
    "$fw\System.dll",
    "$fw\System.Core.dll",
    "$fw\System.Data.dll",
    "$fw\System.Drawing.dll",
    "$fw\System.Windows.Forms.dll",
    "$fw\System.Xml.dll",
    "$gac\Microsoft.SqlServer.TxScript\v4.0_16.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.TxScript.dll",
    "$gac64\Microsoft.SqlServer.DTSRuntimeWrap\v4.0_16.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.DTSRuntimeWrap.dll",
    "$gac\Microsoft.SqlServer.DTSPipelineWrap\v4.0_16.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.DTSPipelineWrap.dll",
    "$gac\Microsoft.SqlServer.PipelineHost\v4.0_16.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.PipelineHost.dll",
    "$gac\Microsoft.SqlServer.ManagedDTS\v4.0_16.0.0.0__89845dcd8080cc91\Microsoft.SqlServer.ManagedDTS.dll"
)

$componentCounts = [ordered]@{
    category_translation = 2
    sellers = 4
    customers = 5
    order_payments = 5
    geolocation = 5
    order_items = 6
    order_reviews = 7
    orders = 8
    products = 9
}

$vstaByTable = @{
    category_translation = 'SC_9f6a4c21e7b748d3a1c2e5f8b0001'
    customers = 'SC_9f6a4c21e7b748d3a1c2e5f8b0002'
    geolocation = 'SC_9f6a4c21e7b748d3a1c2e5f8b0003'
    order_items = 'SC_9f6a4c21e7b748d3a1c2e5f8b0004'
    order_payments = 'SC_9f6a4c21e7b748d3a1c2e5f8b0005'
    order_reviews = 'SC_9f6a4c21e7b748d3a1c2e5f8b0006'
    orders = 'SC_9f6a4c21e7b748d3a1c2e5f8b0007'
    products = 'SC_9f6a4c21e7b748d3a1c2e5f8b0008'
    sellers = 'SC_9f6a4c21e7b748d3a1c2e5f8b0009'
}
foreach ($entry in $componentCounts.GetEnumerator()) {
    $table = $entry.Key
    $count = $entry.Value
    $tableTemp = Join-Path $temp "src_$table"
    if (Test-Path -LiteralPath $tableTemp) {
        Remove-Item -LiteralPath $tableTemp -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tableTemp | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tableTemp 'Properties') | Out-Null
    Get-ChildItem -LiteralPath $temp -File -Filter '*.cs' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $tableTemp $_.Name)
    }
    Get-ChildItem -LiteralPath (Join-Path $temp 'Properties') -File -Filter '*.cs' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path -Path (Join-Path $tableTemp 'Properties') -ChildPath $_.Name)
    }
    $wrapper = Join-Path $tableTemp 'BufferWrapper.cs'
    $wrapperContent = Get-Content -LiteralPath $wrapper -Raw -Encoding UTF8
    $wrapperContent = $wrapperContent.
        Replace('this[14] = value;', "this[$count] = value;").
        Replace('SetNull(14);', "SetNull($count);")
    Set-Content -LiteralPath $wrapper -Value $wrapperContent -Encoding UTF8 -NoNewline

    $vsta = $vstaByTable[$table]
    Get-ChildItem -LiteralPath $tableTemp -Recurse -Filter '*.cs' | ForEach-Object {
        $source = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        $source = $source.Replace('SC_9f6a4c21e7b748d3a1c2e5f8b0d47a63', $vsta)
        Set-Content -LiteralPath $_.FullName -Value $source -Encoding UTF8 -NoNewline
    }

    $cscArgs = @('/nologo', '/target:library', '/nostdlib+', "/out:$assemblies\RowNumberScriptComponent_$table.dll")
    foreach ($ref in $componentRefs) {
        $cscArgs += "/r:$ref"
    }
    Get-ChildItem -LiteralPath $tableTemp -Recurse -Filter '*.cs' | ForEach-Object { $cscArgs += $_.FullName }
    & dotnet $csc @cscArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Compile failed for RowNumberScriptComponent_$table"
    }
}

Get-ChildItem -LiteralPath $assemblies -Filter '*.dll' | Select-Object Name, Length
