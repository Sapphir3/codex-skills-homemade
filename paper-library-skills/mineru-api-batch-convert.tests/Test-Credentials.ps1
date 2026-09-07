[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$module=Join-Path (Split-Path $PSScriptRoot -Parent) 'mineru-api-batch-convert/scripts/MinerUApiBatch.Core.psm1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('mineru-credentials-tests-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:MINERU_API_LOCAL_DATA; $oldToken=$env:MINERU_TOKEN
$env:MINERU_API_LOCAL_DATA=$root; $env:MINERU_TOKEN=$null
try {
    Import-Module $module -Force
    & (Get-Module MinerUApiBatch.Core) {
        $script:checks=0; $script:prompts=0; $script:answer='test-token'
        $script:desktop=$true
        function Test-MinerUInteractive { return $script:desktop }
        function Assert($Condition,$Message) { if (!$Condition) { throw "FAIL: $Message" }; $script:checks++ }
        # Exercise real form construction, masking, save and cancellation without showing UI.
        function Show-MinerUTokenDialog {
            param($Form)
            $script:prompts++
            $box=@($Form.Controls|Where-Object {$_ -is [Windows.Forms.TextBox]})[0]
            Assert $box.UseSystemPasswordChar 'Dialog input must be masked'
            Assert ($Form.CancelButton.DialogResult -eq 'Cancel') 'Dialog must permit cancellation'
            if ($script:answer -eq 'CANCEL') { return 'Cancel' }
            $box.Text=$script:answer
            return 'OK'
        }
        Assert ((Get-MinerUApiToken) -eq 'test-token') 'First run saves token'
        Assert ($script:prompts -eq 1) 'First run prompts once'
        Assert ((Get-MinerUApiToken) -eq 'test-token' -and $script:prompts -eq 1) 'Second run reuses saved token'
        $path=Get-MinerUApiCredentialPath
        Assert (![IO.File]::ReadAllText($path).Contains('test-token')) 'No plaintext token on disk'
        Set-MinerUApiCredential (ConvertTo-SecureString ' Bearer replacement-token ' -AsPlainText -Force)|Out-Null
        Assert ((Get-MinerUApiToken) -eq 'replacement-token') 'Normalize pasted prefix and whitespace'
        $before=(Get-FileHash -LiteralPath $path).Hash
        foreach($bad in @('', 'Bearer ', "one`ntwo", 'a b', '"quoted"')) {
            $failed=$false
            try { ConvertTo-MinerUToken $bad|Out-Null } catch {$failed=$true}
            Assert $failed 'Reject malformed token'
        }
        $script:answer='CANCEL'; $failed=$false
        try {Set-MinerUApiCredential|Out-Null} catch {$failed=$_.Exception.Message -match 'cancelled'}
        Assert ($failed -and (Get-FileHash -LiteralPath $path).Hash -eq $before) 'Cancel preserves previous credential'
        $script:answer='test-token'
        [IO.File]::WriteAllText($path,'corrupt credential fixture')
        Assert ((Get-MinerUApiToken) -eq 'test-token') 'Unreadable credential can be replaced'
        # Failure before atomic replacement preserves the existing saved token.
        $before=(Get-FileHash -LiteralPath $path).Hash
        function Export-Clixml { throw 'synthetic write failure' }
        $failed=$false
        try {Set-MinerUApiCredential (ConvertTo-SecureString 'another-token' -AsPlainText -Force)|Out-Null} catch {$failed=$true}
        Remove-Item Function:Export-Clixml
        Assert ($failed -and (Get-FileHash -LiteralPath $path).Hash -eq $before) 'Failed write leaves saved credential intact'
        Assert (@(Get-ChildItem -LiteralPath (Split-Path $path) -Filter '*.tmp').Count -eq 0) 'No temporary credentials remain'
        $script:scenario='auth'; $script:requests=0; $script:CredentialSetupUsed=$false
        function Invoke-MinerUApiRequestOnce {
            param($Uri,$Token,$Method,$Body)
            $script:requests++
            if ($script:scenario -eq 'auth' -and $Token -ne 'test-token') {throw (New-MinerUAuthException 'synthetic rejected token')}
            if ($script:scenario -eq 'alwaysauth') {throw (New-MinerUAuthException 'synthetic rejected token')}
            if ($script:scenario -in @('network','quota','rate','server')) {throw 'transient or quota failure'}
            return 'ok'
        }
        $beforePrompts=$script:prompts
        Assert ((Invoke-MinerUApiRequest -Uri 'https://example.invalid' -Token bad -Method POST) -eq 'ok') 'Auth replacement retries the rejected request'
        Assert ($script:requests -eq 2 -and $script:prompts -eq $beforePrompts+1) 'Only one replacement prompt and one retry'
        Assert ((Invoke-MinerUApiRequest -Uri 'https://example.invalid' -Token bad) -eq 'ok' -and $script:prompts -eq $beforePrompts+1) 'Later polls use replacement token without another prompt'
        foreach($scenario in @('network','quota','rate','server')) {
            $script:scenario=$scenario; $script:CredentialSetupUsed=$false; $beforePrompts=$script:prompts; $beforeRequests=$script:requests
            try {Invoke-MinerUApiRequest -Uri 'https://example.invalid' -Token bad|Out-Null} catch {}
            Assert ($script:prompts -eq $beforePrompts -and $script:requests -eq $beforeRequests+1) 'Non-auth failure must not prompt or retry'
        }
        $script:scenario='alwaysauth'; $script:CredentialSetupUsed=$false; $beforeRequests=$script:requests
        $failed=$false
        try {Invoke-MinerUApiRequest -Uri 'https://example.invalid' -Token bad|Out-Null} catch {$failed=[bool]$_.Exception.Data['MinerUAuthFailure']}
        Assert ($failed -and $script:requests -eq $beforeRequests+2) 'Rejected replacement stops without a loop'
        $script:CredentialSetupUsed=$false; $env:MINERU_TOKEN='override-token'; $beforePrompts=$script:prompts
        try {Invoke-MinerUApiRequest -Uri 'https://example.invalid' -Token bad|Out-Null} catch {}
        Assert ($script:prompts -eq $beforePrompts) 'Explicit environment override must not be silently replaced'
        $env:MINERU_TOKEN=$null; $script:CredentialPrompt='Never'; $beforePrompts=$script:prompts
        Clear-MinerUApiCredential; $failed=$false
        try {Get-MinerUApiToken|Out-Null} catch {$failed=$_.Exception.Message -match 'interactive'}
        Assert ($failed -and $script:prompts -eq $beforePrompts) 'Headless mode fails promptly without a dialog'
        $script:CredentialPrompt='Auto'; $script:desktop=$false; $failed=$false
        try {Get-MinerUApiToken|Out-Null} catch {$failed=$_.Exception.Message -match 'interactive'}
        Assert ($failed -and $script:prompts -eq $beforePrompts) 'Unavailable desktop must not open or wait for a dialog'
        Set-MinerUApiCredential (ConvertTo-SecureString 'process-test-token' -AsPlainText -Force)|Out-Null
        [pscustomobject]@{passed=$true; checks=$script:checks; suite='credential lifecycle and form controls'}
    }
    # A fresh process must load the file with no prompt or reconfiguration.
    $child='Import-Module '''+$module.Replace("'","''")+''' -Force; if ((Get-MinerUApiToken) -ne ''process-test-token'') { exit 1 }; Write-Output ''Cross-process credential reuse passed'''
    & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command $child
    if($LASTEXITCODE -ne 0){throw 'Cross-process credential reuse failed'}
}
finally {
    $env:MINERU_API_LOCAL_DATA=$oldLocal; $env:MINERU_TOKEN=$oldToken
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $root -Leaf) -like 'mineru-credentials-tests-*' -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
