# Loaded in module scope; tokens never enter command-line arguments or reports.
$script:CredentialPrompt = 'Auto'
$script:ReplacementToken = $null
$script:CredentialSetupUsed = $false

function Show-MinerUTokenDialog { param($Form) return $Form.ShowDialog() }
function Test-MinerUInteractive {
    return [Environment]::UserInteractive -and (Get-Process -Id $PID).SessionId -gt 0 -and
        [Environment]::GetCommandLineArgs() -notcontains '-NonInteractive'
}

function Read-MinerUToken {
    if ($script:CredentialPrompt -eq 'Never' -or !(Test-MinerUInteractive)) {
        throw 'Token setup requires an interactive desktop or terminal. Run -Action Configure on this computer.'
    }
    if ($script:CredentialPrompt -eq 'Console') {
        if ([Console]::IsInputRedirected) { throw 'No interactive terminal. Use -CredentialPrompt Auto on a Windows desktop.' }
        return Read-Host 'Enter MinerU API token (stored encrypted on this computer)' -AsSecureString
    }
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop }
    catch { throw 'Token dialog unavailable. Run -Action Configure -CredentialPrompt Console in a local terminal.' }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'MinerU API token'
    $form.ClientSize = New-Object Drawing.Size(480,165)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.TopMost = $true
    $label = New-Object Windows.Forms.Label
    $label.SetBounds(16,12,448,44)
    $label.Text = 'Paste your MinerU API token. It will be encrypted for this Windows user and reused on this computer.'
    $inputBox = New-Object Windows.Forms.TextBox
    $inputBox.SetBounds(16,62,448,26); $inputBox.UseSystemPasswordChar = $true
    $save = New-Object Windows.Forms.Button
    $save.Text = 'Save'; $save.SetBounds(274,112,90,30); $save.DialogResult = 'OK'
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.SetBounds(374,112,90,30); $cancel.DialogResult = 'Cancel'
    $form.Controls.AddRange(@($label,$inputBox,$save,$cancel))
    $form.AcceptButton = $save; $form.CancelButton = $cancel
    try {
        if ((Show-MinerUTokenDialog $form) -ne 'OK') { throw 'Token setup cancelled; rerun the same conversion when ready.' }
        if (!$inputBox.Text) { throw 'The API token cannot be empty.' }
        return ConvertTo-SecureString $inputBox.Text -AsPlainText -Force
    }
    finally { $inputBox.Clear(); $form.Dispose() }
}

function ConvertTo-MinerUToken {
    param([string]$Value)
    $value = $Value.Trim()
    if ($value -match '[\r\n]') { throw 'Paste one API token, not multiple lines.' }
    $value = ($value -replace '(?i)^Bearer\s+', '').Trim()
    if (!$value -or $value -ieq 'Bearer' -or $value -match '\s' -or $value -match '["'']') { throw 'Paste the raw API token without quotes or internal whitespace.' }
    return $value
}

function Set-MinerUApiCredential {
    param([Security.SecureString]$Token)
    if ($env:OS -ne 'Windows_NT') { throw 'Encrypted credential storage requires Windows.' }
    if ($null -eq $Token) { $Token = Read-MinerUToken }
    $plain = ConvertTo-MinerUToken ([Net.NetworkCredential]::new('', $Token).Password)
    $credential = [PSCredential]::new('mineru-api', (ConvertTo-SecureString $plain -AsPlainText -Force))
    $path = Get-MinerUApiCredentialPath
    $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $credential | Export-Clixml -LiteralPath $temporary -ErrorAction Stop
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    }
    finally { $plain = $null; if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    Write-Information 'MinerU token saved locally; the next API request verifies it.' -InformationAction Continue
    return $path
}

function Get-MinerUApiToken {
    if (![string]::IsNullOrWhiteSpace($env:MINERU_TOKEN)) { return ConvertTo-MinerUToken $env:MINERU_TOKEN }
    $path = Get-MinerUApiCredentialPath
    if (Test-Path -LiteralPath $path) {
        try { return ConvertTo-MinerUToken (Import-Clixml -LiteralPath $path -ErrorAction Stop).GetNetworkCredential().Password }
        catch { Write-Information 'Saved credential cannot be read for this Windows user; local setup is required.' -InformationAction Continue }
    }
    $script:CredentialSetupUsed = $true
    $null = Set-MinerUApiCredential
    return (Import-Clixml -LiteralPath $path -ErrorAction Stop).GetNetworkCredential().Password
}

function Invoke-MinerUApiRequest {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Token,
          [ValidateSet('GET','POST')][string]$Method='GET', $Body)
    if ($script:ReplacementToken) { $Token = $script:ReplacementToken }
    try { return Invoke-MinerUApiRequestOnce -Uri $Uri -Token $Token -Method $Method -Body $Body }
    catch {
        if (!$_.Exception.Data['MinerUAuthFailure'] -or $script:CredentialSetupUsed -or
            $script:CredentialPrompt -eq 'Never' -or ![string]::IsNullOrWhiteSpace($env:MINERU_TOKEN)) { throw }
        $script:CredentialSetupUsed = $true
        Write-Information 'MinerU rejected the stored token. Enter a replacement in the local prompt.' -InformationAction Continue
        try { $null = Set-MinerUApiCredential }
        catch { throw (New-MinerUAuthException -Message ('Token replacement not completed. ' + $_.Exception.Message)) }
        $script:ReplacementToken = Get-MinerUApiToken
        # Retry only a definite authentication rejection, never an ambiguous submission.
        return Invoke-MinerUApiRequestOnce -Uri $Uri -Token $script:ReplacementToken -Method $Method -Body $Body
    }
}
