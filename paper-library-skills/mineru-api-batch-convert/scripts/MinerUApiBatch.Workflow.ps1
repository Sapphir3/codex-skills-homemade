# Dot-sourced by the core module. Network workers never receive an API token.
$script:ModulePath = Join-Path $PSScriptRoot 'MinerUApiBatch.Core.psm1'

function Wait-MinerUFilesReady {
    param([object[]]$Items, [int]$TimeoutSeconds, [int]$StabilitySeconds)
    $pending = @{}
    foreach ($item in $Items) { $pending[$item.pdfPath] = @{ signature=$null; since=[datetime]::UtcNow } }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($pending.Count -gt 0) {
        foreach ($path in @($pending.Keys)) {
            $entry = $pending[$path]
            try {
                $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                $stream.Dispose()
                $file = Get-Item -LiteralPath $path -ErrorAction Stop
                $signature = "$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
                if ($signature -ne $entry.signature) { $entry.signature=$signature; $entry.since=[datetime]::UtcNow }
                if (([datetime]::UtcNow-$entry.since).TotalSeconds -ge $StabilitySeconds) { $pending.Remove($path) }
            }
            catch { $entry.signature=$null; $entry.since=[datetime]::UtcNow }
        }
        if ($pending.Count -eq 0) { break }
        if ([datetime]::UtcNow -ge $deadline) { throw "PDFs did not become readable and stable: $(@($pending.Keys) -join '; ')" }
        Start-Sleep -Milliseconds 200
    }
}

function Protect-MinerUUploadUrl {
    param([string]$Url)
    return ConvertFrom-SecureString (ConvertTo-SecureString $Url -AsPlainText -Force)
}

function Unprotect-MinerUUploadUrl {
    param([string]$Value)
    $secret = ConvertTo-SecureString $Value
    return [Net.NetworkCredential]::new('', $secret).Password
}

function Invoke-MinerUWorkers {
    param([object[]]$Work, [ValidateSet('Upload','Publish')][string]$Operation,
          [int]$Concurrency, [scriptblock]$Completed)
    if ($Work.Count -eq 0) { return }
    $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
    $pool.Open()
    $jobs = [Collections.Generic.List[object]]::new()
    $worker = {
        param($ModulePath, $Task, $Operation)
        $ErrorActionPreference='Stop'
        Import-Module $ModulePath -Force
        & (Get-Module MinerUApiBatch.Core) {
            param($Task, $Operation)
            try {
                if ($Operation -eq 'Upload') {
                    if ((Get-FileHash -LiteralPath $Task.pdfPath -Algorithm SHA256).Hash -ine $Task.sourceSha256) { throw 'Source PDF changed before upload.' }
                    Send-MinerUUpload -SignedUrl $Task.url -FilePath $Task.pdfPath
                    if ((Get-FileHash -LiteralPath $Task.pdfPath -Algorithm SHA256).Hash -ine $Task.sourceSha256) { throw 'Source PDF changed during upload.' }
                    return [pscustomobject]@{status='Uploaded'; dataId=$Task.dataId; pdfPath=$Task.pdfPath}
                }
                $stage = Join-Path ([IO.Path]::GetTempPath()) ('mineru-api-stage-'+[guid]::NewGuid().ToString('N'))
                $null = New-Item -ItemType Directory -Path $stage
                try {
                    Receive-MinerUBinary -Uri $Task.url -Destination (Join-Path $stage 'result.zip')
                    Expand-MinerUSafeZip -ZipPath (Join-Path $stage 'result.zip') -Destination (Join-Path $stage 'result')
                    $result = Publish-MinerUApiOutput -PdfPath $Task.pdfPath -StagePath (Join-Path $stage 'result') -Model $Task.model -Language $Task.language -BatchId $Task.batchId -SourceSha256 $Task.sourceSha256 -AllowReplaceStale:$Task.allowReplaceStale
                    $result | Add-Member dataId $Task.dataId
                    return $result
                }
                finally {
                    if ((Test-PathWithin -Path $stage -Root ([IO.Path]::GetTempPath())) -and (Split-Path $stage -Leaf) -like 'mineru-api-stage-*') { Remove-Item -LiteralPath $stage -Recurse -Force }
                }
            }
            catch {
                # Never emit signed URLs or remote error bodies in reports.
                $message = [regex]::Replace($_.Exception.Message, 'https?://\S+', '[redacted URL]')
                return [pscustomobject]@{status='Failed'; dataId=$Task.dataId; pdfPath=$Task.pdfPath; error=$message}
            }
        } $Task $Operation
    }
    try {
        foreach ($task in $Work) {
            $ps = [powershell]::Create()
            $ps.RunspacePool=$pool
            $null=$ps.AddScript($worker.ToString()).AddArgument($script:ModulePath).AddArgument($task).AddArgument($Operation)
            $jobs.Add([pscustomobject]@{shell=$ps; handle=$ps.BeginInvoke(); task=$task})
        }
        while ($jobs.Count -gt 0) {
            for ($i=$jobs.Count-1; $i -ge 0; $i--) {
                $job=$jobs[$i]
                if (!$job.handle.IsCompleted) { continue }
                $values=@($job.shell.EndInvoke($job.handle))
                if ($job.shell.HadErrors -or $values.Count -ne 1) {
                    $result=[pscustomobject]@{status='Failed'; dataId=$job.task.dataId; pdfPath=$job.task.pdfPath; error='Transfer worker failed; pending state was retained.'}
                } else { $result=$values[0] }
                $job.shell.Dispose()
                $jobs.RemoveAt($i)
                & $Completed $result
            }
            if ($jobs.Count -gt 0) { Start-Sleep -Milliseconds 30 }
        }
    }
    finally {
        foreach ($job in $jobs) { $job.shell.Stop(); $job.shell.Dispose() }
        $pool.Close(); $pool.Dispose()
    }
}

function Save-MinerUBatchState {
    param([Parameter(Mandatory)]$State, [string]$StateRoot)
    $root=Get-MinerUStateRoot -ExplicitPath $StateRoot
    $null=New-Item -ItemType Directory -Path $root -Force
    # A hash filename avoids trusting the remote batch id as a filesystem path.
    $idHash=[Security.Cryptography.SHA256]::Create()
    try { $name=([BitConverter]::ToString($idHash.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$State.batchId)))).Replace('-','').ToLowerInvariant() }
    finally { $idHash.Dispose() }
    $path=Join-Path $root ($name+'.json')
    if ($State.PSObject.Properties['statePath'] -and $State.statePath -and (Test-PathWithin -Path $State.statePath -Root $root)) { $path=$State.statePath }
    $temp=$path+'.tmp-'+[guid]::NewGuid().ToString('N')
    $State | Add-Member statePath $path -Force
    [IO.File]::WriteAllText($temp, ($State|ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
    try {
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp, $path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $path) }
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    return $path
}

function Start-MinerUApiBatch {
    param([object[]]$Items, [string]$Token, [string]$ApiBase, [string]$Model,
          [string]$Language, [switch]$Ocr, [string]$PageRanges,
          [int]$OneDriveTimeoutSeconds, [int]$StabilitySeconds, [string]$StateRoot,
          [int]$TransferConcurrency=3)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Wait-MinerUFilesReady -Items $Items -TimeoutSeconds $OneDriveTimeoutSeconds -StabilitySeconds $StabilitySeconds
    $entries=@(); $stateItems=@()
    for ($i=0; $i -lt $Items.Count; $i++) {
        $pdf=Get-Item -LiteralPath $Items[$i].pdfPath
        if ($pdf.Length -gt $script:MaxFileBytes) { throw "PDF exceeds 200 MB: $($pdf.Name)" }
        $signature=Get-FileSignature -Path $pdf.FullName -IncludeHash
        $id=New-MinerUDataId -Index $i -Stem $pdf.BaseName
        $entry=[ordered]@{name=$pdf.Name; data_id=$id; is_ocr=[bool]$Ocr}
        if ($PageRanges) { $entry.page_ranges=$PageRanges }
        $entries += $entry
        $stateItems += [pscustomobject]@{dataId=$id; pdfPath=$pdf.FullName; sourceLength=$signature.length; sourceLastWriteUtc=$signature.lastWriteUtc; sourceSha256=$signature.sha256; uploaded=$false; published=$false; terminalFailure=$null; uploadUrlProtected=$null}
    }
    $base=$ApiBase.TrimEnd('/')
    # Persist intent before POST. An ambiguous network failure must not cause resubmission.
    $state=[pscustomobject]@{schemaVersion=2; skillVersion=$script:SkillVersion; batchId=('unconfirmed-'+[guid]::NewGuid().ToString('N')); apiBase=$base; model=$Model; language=$Language; createdUtc=[datetime]::UtcNow.ToString('o'); submissionConfirmed=$false; items=$stateItems}
    $intentPath=Save-MinerUBatchState -State $state -StateRoot $StateRoot
    try {
        $data=Invoke-MinerUApiRequest -Uri "$base/file-urls/batch" -Token $Token -Method POST -Body @{files=$entries; model_version=$Model; language=$Language; enable_formula=$true; enable_table=$true}
    }
    catch {
        if ($_.Exception.Data['MinerUSubmissionRejected']) { Remove-Item -LiteralPath $intentPath -Force }
        throw
    }
    if (!$data.batch_id) { throw 'MinerU returned no batch id; submission intent retained for review.' }
    $state.batchId=[string]$data.batch_id
    $state.submissionConfirmed=$true
    $null=Save-MinerUBatchState -State $state -StateRoot $StateRoot
    $urls=@($data.file_urls)
    if ($urls.Count -ne $Items.Count) { throw 'Upload URL count does not match the submitted files; batch retained.' }
    for ($i=0; $i -lt $urls.Count; $i++) { $state.items[$i].uploadUrlProtected=Protect-MinerUUploadUrl $urls[$i] }
    $null=Save-MinerUBatchState -State $state -StateRoot $StateRoot
    $script:RunTiming.preparationSeconds += $watch.Elapsed.TotalSeconds
    Write-Information "Prepared $($Items.Count) PDFs; batch recorded before upload." -InformationAction Continue
    Send-MinerUPendingUploads -State $state -Items $state.items -StateRoot $StateRoot -TransferConcurrency $TransferConcurrency
    return $state
}

function Send-MinerUPendingUploads {
    param($State, [object[]]$Items, [string]$StateRoot, [int]$TransferConcurrency)
    $work=@(); $byId=@{}
    foreach ($item in $Items) {
        if ($item.uploaded -or $item.published -or $item.terminalFailure) { continue }
        if (!$item.uploadUrlProtected) { throw 'Pending upload has no recoverable URL; batch retained for review.' }
        $work += [pscustomobject]@{dataId=$item.dataId; pdfPath=$item.pdfPath; sourceSha256=$item.sourceSha256; url=(Unprotect-MinerUUploadUrl $item.uploadUrlProtected)}
        $byId[$item.dataId]=$item
    }
    $failures=[Collections.Generic.List[string]]::new()
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-MinerUWorkers -Work $work -Operation Upload -Concurrency $TransferConcurrency -Completed {
        param($result)
        if ($result.status -eq 'Uploaded') {
            $byId[$result.dataId].uploaded=$true
            $byId[$result.dataId].uploadUrlProtected=$null
            $null=Save-MinerUBatchState -State $State -StateRoot $StateRoot
        } else { $failures.Add($result.error) }
    }
    $script:RunTiming.uploadSeconds += $watch.Elapsed.TotalSeconds
    if ($failures.Count -gt 0) { throw "Upload incomplete ($($failures.Count) files); resume the recorded batch. $($failures[0])" }
    if ($work.Count -gt 0) { Write-Information "Uploaded $($work.Count) PDFs." -InformationAction Continue }
}

function Complete-MinerUApiBatch {
    param($State, [string]$Token, [int]$IntervalSeconds, [int]$TimeoutSeconds,
          [int]$TransferConcurrency=3, [string]$StateRoot, [string[]]$AllowedPaths,
          [switch]$Resumed, [switch]$AllowReplaceStale,
          [Collections.Generic.List[object]]$Results = [Collections.Generic.List[object]]::new())
    if ($State.PSObject.Properties['submissionConfirmed'] -and !$State.submissionConfirmed) { throw 'A previous submission has an unknown outcome. Review its local state before submitting again.' }
    # Older v1 states were written only after all uploads succeeded.
    foreach ($item in $State.items) {
        if (!$item.PSObject.Properties['uploaded']) { $item|Add-Member uploaded $true }
        if (!$item.PSObject.Properties['published']) { $item|Add-Member published $false }
        if (!$item.PSObject.Properties['terminalFailure']) { $item|Add-Member terminalFailure $null }
        if (!$item.PSObject.Properties['uploadUrlProtected']) { $item|Add-Member uploadUrlProtected $null }
    }
    $selected=@($State.items | Where-Object { $AllowedPaths -contains $_.pdfPath })
    $byId=@{}; foreach ($item in $selected) { $byId[$item.dataId]=$item }
    $attempted=@{}
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay=[math]::Min(2,$IntervalSeconds)
    $pollFailure=$null
    do {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try { $remote=Invoke-MinerUApiRequest -Uri "$($State.apiBase)/extract-results/batch/$($State.batchId)" -Token $Token }
        catch {
            if ($_.Exception.Data['MinerUAuthFailure']) { throw }
            $pollFailure=$_.Exception.Message
            break
        }
        $script:RunTiming.pollRequests++
        $script:RunTiming.waitSeconds += $watch.Elapsed.TotalSeconds
        $seen=@{}; $ready=@(); $uploadAgain=@()
        foreach ($record in @($remote.extract_result)) {
            $id=[string]$record.data_id
            if (!$byId.ContainsKey($id)) { continue }
            if ($seen.ContainsKey($id)) { throw 'Duplicate document identity in MinerU result; batch retained.' }
            $seen[$id]=$true
            $item=$byId[$id]
            if ($item.published -or $item.terminalFailure) { continue }
            $remoteState=[string]$record.state
            if ($remoteState -in @('done','failed','running','pending','converting')) {
                $item.uploaded=$true; $item.uploadUrlProtected=$null
            }
            if ($remoteState -eq 'waiting-file' -and !$item.uploaded) { $uploadAgain += $item; continue }
            if ($remoteState -eq 'failed') {
                $item.terminalFailure='MinerU reported document parsing failure.'
                $results.Add([pscustomobject]@{status='Failed'; pdfPath=$item.pdfPath; batchId=$State.batchId; resumed=[bool]$Resumed; error=$item.terminalFailure})
            }
            elseif ($remoteState -eq 'done' -and !$attempted.ContainsKey($id)) {
                # Crash after publishing but before checkpoint: recognize only this source and batch.
                $status=Get-PdfStatus -PdfPath $item.pdfPath
                if ($status.status -like 'Current*' -and $status.marker -and $status.marker.PSObject.Properties['batchId'] -and $status.marker.batchId -eq $State.batchId -and $status.marker.sourceSha256 -eq $item.sourceSha256) {
                    $item.published=$true
                    continue
                }
                $ready += [pscustomobject]@{dataId=$id; pdfPath=$item.pdfPath; sourceSha256=$item.sourceSha256; url=[string]$record.full_zip_url; batchId=$State.batchId; model=$State.model; language=$State.language; allowReplaceStale=[bool]$AllowReplaceStale}
                $attempted[$id]=$true
            }
        }
        $null=Save-MinerUBatchState -State $State -StateRoot $StateRoot
        if ($uploadAgain.Count -gt 0) { Send-MinerUPendingUploads -State $State -Items $uploadAgain -StateRoot $StateRoot -TransferConcurrency $TransferConcurrency }
        if ($ready.Count -gt 0) {
            $watch.Restart()
            Invoke-MinerUWorkers -Work $ready -Operation Publish -Concurrency $TransferConcurrency -Completed {
                param($result)
                $result | Add-Member resumed ([bool]$Resumed) -Force
                if (!$result.PSObject.Properties['batchId']) { $result|Add-Member batchId $State.batchId }
                if ($result.status -eq 'Converted') { $byId[$result.dataId].published=$true }
                $results.Add($result)
                $null=Save-MinerUBatchState -State $State -StateRoot $StateRoot
                Write-Information "$($result.status): $([IO.Path]::GetFileName($result.pdfPath))" -InformationAction Continue
            }
            $script:RunTiming.downloadPublishSeconds += $watch.Elapsed.TotalSeconds
            $delay=[math]::Min(2,$IntervalSeconds)
        }
        # Every selected data_id must be accounted for; a partial remote list is not completion.
        $pending=@($selected|Where-Object { !$_.published -and !$_.terminalFailure -and !$attempted.ContainsKey($_.dataId) })
        if ($pending.Count -eq 0) { break }
        if ([datetime]::UtcNow -ge $deadline) { break }
        Write-Information "Waiting for $($pending.Count) PDFs; $($results.Count) results handled." -InformationAction Continue
        if ($delay -gt 0) {
            $sleep=[math]::Min($delay,[math]::Max(0,($deadline-[datetime]::UtcNow).TotalSeconds))
            Start-Sleep -Milliseconds ([int]($sleep*1000))
            $script:RunTiming.waitSeconds += $sleep
        }
        else { Start-Sleep -Milliseconds 20 }
        $delay=[math]::Min($IntervalSeconds,[math]::Max(1,$delay*1.5))
    } while ([datetime]::UtcNow -lt $deadline)
    foreach ($item in $selected) {
        if (!$item.published -and !$item.terminalFailure -and !$attempted.ContainsKey($item.dataId)) {
            $message=if ($pollFailure) { $pollFailure } else { 'Timed out or result missing; recorded batch retained for resume.' }
            $results.Add([pscustomobject]@{status='Failed'; pdfPath=$item.pdfPath; batchId=$State.batchId; resumed=[bool]$Resumed; error=$message})
        }
    }
    $unresolved=@($State.items|Where-Object { !$_.published -and !$_.terminalFailure })
    if ($unresolved.Count -eq 0) { Remove-Item -LiteralPath $State.statePath -Force }
    return $results.ToArray()
}

function Invoke-MinerUApiConversions {
    param($ScanReport, [string]$Token, [string]$ApiBase, [string]$Model='vlm',
          [string]$Language='en', [switch]$Ocr, [string]$PageRanges,
          [int]$BatchSize=20, [int]$IntervalSeconds=10, [int]$TimeoutSeconds=1800,
          [int]$OneDriveTimeoutSeconds=120, [int]$StabilitySeconds=2,
          [string]$StateRoot, [ValidateRange(1,8)][int]$TransferConcurrency=3,
          [switch]$AllowReplaceStale)
    $script:RunTiming=[ordered]@{preparationSeconds=0.0; uploadSeconds=0.0; waitSeconds=0.0; downloadPublishSeconds=0.0; pollRequests=0}
    $all=[Collections.Generic.List[object]]::new()
    $allowed=@($ScanReport.items|Where-Object { $_.status -like 'Current*' -or $_.status -eq 'Missing' -or ($_.status -eq 'Stale' -and $AllowReplaceStale) }|ForEach-Object { $_.pdfPath })
    foreach ($item in $ScanReport.items) {
        if ($allowed -notcontains $item.pdfPath) {
            $message = if ($item.status -eq 'Stale') { 'Stale output preserved; explicit -AllowReplaceStale consent is required.' } else { "Output status $($item.status) requires review; no upload or overwrite." }
            $all.Add([pscustomobject]@{status='ReviewRequired'; pdfPath=$item.pdfPath; batchId=$null; resumed=$false; error=$message})
        }
    }
    $pendingPaths=@{}
    $states=@(Get-MinerUPendingStates -StateRoot $StateRoot | Where-Object {
        @($_.items|Where-Object {
            $allowed -contains $_.pdfPath -and
            !($_.PSObject.Properties['published'] -and $_.published) -and
            !($_.PSObject.Properties['terminalFailure'] -and $_.terminalFailure)
        }).Count -gt 0
    })
    $candidates=@($ScanReport.items|Where-Object {$_.status -eq 'Missing' -or ($_.status -eq 'Stale' -and $AllowReplaceStale)})
    if ($candidates.Count -eq 0 -and $states.Count -eq 0) { return $all.ToArray() }
    try { if (!$Token) { $Token=Get-MinerUApiToken } }
    catch { $_.Exception.Data['MinerUPartialResults']=$all.ToArray(); throw }
    foreach ($state in $states) {
        $inScope=@($state.items|Where-Object {$allowed -contains $_.pdfPath})
        foreach ($item in $inScope) { $pendingPaths[$item.pdfPath]=$true }
        $completed=[Collections.Generic.List[object]]::new()
        try {
            if ($state.apiBase.TrimEnd('/') -ne $ApiBase.TrimEnd('/')) { throw 'Pending batch uses a different API endpoint; explicit recovery is required.' }
            $null=Complete-MinerUApiBatch -State $state -Token $Token -IntervalSeconds $IntervalSeconds -TimeoutSeconds $TimeoutSeconds -TransferConcurrency $TransferConcurrency -StateRoot $StateRoot -AllowedPaths $allowed -Resumed -AllowReplaceStale:$AllowReplaceStale -Results $completed
        }
        catch {
            if ($_.Exception.Data['MinerUAuthFailure']) {
                $_.Exception.Data['MinerUPartialResults']=@($all.ToArray()) + @($completed.ToArray())
                throw
            }
            foreach ($item in $inScope) {
                if (($item.PSObject.Properties['published'] -and $item.published) -or @($completed|Where-Object pdfPath -eq $item.pdfPath).Count -gt 0) { continue }
                $completed.Add([pscustomobject]@{status='Failed'; pdfPath=$item.pdfPath; batchId=$state.batchId; resumed=$true; error=$_.Exception.Message})
            }
        }
        foreach ($result in $completed) { $all.Add($result) }
    }
    $candidates=@($candidates|Where-Object { !$pendingPaths.ContainsKey($_.pdfPath) })
    for ($offset=0; $offset -lt $candidates.Count; $offset+=$BatchSize) {
        $batch=@($candidates[$offset..([math]::Min($offset+$BatchSize-1,$candidates.Count-1))])
        $completed=[Collections.Generic.List[object]]::new()
        $state=$null
        try {
            $state=Start-MinerUApiBatch -Items $batch -Token $Token -ApiBase $ApiBase -Model $Model -Language $Language -Ocr:$Ocr -PageRanges $PageRanges -OneDriveTimeoutSeconds $OneDriveTimeoutSeconds -StabilitySeconds $StabilitySeconds -StateRoot $StateRoot -TransferConcurrency $TransferConcurrency
            $null=Complete-MinerUApiBatch -State $state -Token $Token -IntervalSeconds $IntervalSeconds -TimeoutSeconds $TimeoutSeconds -TransferConcurrency $TransferConcurrency -StateRoot $StateRoot -AllowedPaths $allowed -AllowReplaceStale:$AllowReplaceStale -Results $completed
        }
        catch {
            if ($_.Exception.Data['MinerUAuthFailure']) {
                $_.Exception.Data['MinerUPartialResults']=@($all.ToArray()) + @($completed.ToArray())
                throw
            }
            foreach ($item in $batch) {
                if (@($completed|Where-Object pdfPath -eq $item.pdfPath).Count -gt 0) { continue }
                $completed.Add([pscustomobject]@{status='Failed'; pdfPath=$item.pdfPath; batchId=if ($state) {$state.batchId} else {$null}; resumed=$false; error=$_.Exception.Message})
            }
        }
        foreach ($result in $completed) { $all.Add($result) }
    }
    return $all.ToArray()
}

function Get-MinerURunTiming { return [pscustomobject]$script:RunTiming }
