[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SkillPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [int]$Count = 6,
    [double]$TransferDelaySeconds = 0.4
)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('mineru-benchmark-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$server = $null
$previousToken = $env:MINERU_TOKEN
$previousLocal = $env:MINERU_API_LOCAL_DATA
try {
    $portFile = Join-Path $root 'port'
    $server = Start-Process python -ArgumentList @(('"'+(Join-Path $PSScriptRoot 'mock_mineru_server.py')+'"'), '--ready-file', ('"'+$portFile+'"'), '--delay', $TransferDelaySeconds) -WindowStyle Hidden -PassThru
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while (!(Test-Path -LiteralPath $portFile) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (!(Test-Path -LiteralPath $portFile)) { throw 'Mock server did not start.' }
    $port = [IO.File]::ReadAllText($portFile).Trim()
    $env:MINERU_TOKEN = 'test-token'
    $env:MINERU_API_LOCAL_DATA = Join-Path $root 'local-state'
    $files = @(for ($i=0; $i -lt $Count; $i++) {
        $pdf = Join-Path $root ("Benchmark $i.pdf")
        & python (Join-Path $PSScriptRoot 'make_probe.py') $pdf
        if ($LASTEXITCODE -ne 0) { throw 'Fixture generation failed.' }
        $pdf
    })
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $r = & (Join-Path $SkillPath 'scripts/Invoke-MinerUApiBatch.ps1') -Action Convert -PdfPath $files -ApiBase "http://127.0.0.1:$port/api/v4" -StateRoot (Join-Path $root 'state') -ReportPath (Join-Path $root 'report.json')
    $clock.Stop()
    $stats = Invoke-RestMethod "http://127.0.0.1:$port/stats"
    if ($r.summary.convertedCount -ne $Count) { throw 'Benchmark conversion was incomplete.' }
    $data = [ordered]@{ environment='local synthetic server; not cloud parsing speed'; files=$Count; transferDelaySeconds=$TransferDelaySeconds; elapsedSeconds=[math]::Round($clock.Elapsed.TotalSeconds,3); converted=$r.summary.convertedCount; maxConcurrentTransfers=$stats.max_active; batches=$stats.batches }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($data|ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [pscustomobject]$data
}
finally {
    $env:MINERU_TOKEN=$previousToken
    $env:MINERU_API_LOCAL_DATA=$previousLocal
    if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -Force; $server.WaitForExit() }
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'mineru-benchmark-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
