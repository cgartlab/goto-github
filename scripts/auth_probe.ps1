#Requires -Version 5.1
<#
.SYNOPSIS
    Credential state probe for the goto-github skill (read-only).

.DESCRIPTION
    Why this exists: a failing `git push` has at least four distinct causes -
    no SSH key, key not authorized, no HTTPS credential, or no write permission.
    A pure connectivity probe reports all of them as "FAIL" and sends the user
    to fix the network, which is the wrong thing. This separates them.

    Nothing here is a network availability test. Reachability lives in
    connectivity_probe; this answers "do I have the credentials this path needs".

    PowerShell 5.1 compatible (Windows default) and 7+.

.PARAMETER Repo
    Repository used for the permission check.

.PARAMETER Help
    Show this help.

.EXAMPLE
    .\scripts\auth_probe.ps1
#>
[CmdletBinding()]
param(
    [string]$Repo = 'cgartlab/goto-github',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$showHelp = {
    Write-Output @'
Usage: auth_probe.ps1 [-Repo owner/repo] [-Help]

Credential state probe for the goto-github skill. Read-only, no network.

Separates authentication failures from network failures, which a connectivity
probe cannot do:
  ssh.state     transport-ok | auth-fail | blocked | no-key | unknown
  https.state   ok | no-credentials | permission-denied | unknown
  gh.state      keyring_ok | env_var_shadowed | none | error

Options:
  -Repo owner/repo  repository used for the permission check

Requires PowerShell 5.1+.
'@
}

if ($Help) { & $showHelp; exit 0 }

$script:Warnings = New-Object System.Collections.Generic.List[string]
function Add-Warning {
    param([string]$Message)
    $script:Warnings.Add($Message) | Out-Null
}

function ConvertTo-JsonLiteral {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 'null' }
    $v = $Value.Replace('\', '\\').Replace('"', '\"')
    $v = $v.Replace("`r", '').Replace("`n", '\n').Replace("`t", '\t')
    return "`"$v`""
}

# -- SSH ---------------------------------------------------------------------
# Order matters: a missing key produces the same "Permission denied (publickey)"
# as an unauthorized one, so check for a key first.
$sshState = 'unknown'
$sshDetail = $null

$sshDir = Join-Path $HOME '.ssh'
$hasKey = $false
foreach ($k in 'id_rsa', 'id_ed25519', 'id_ecdsa') {
    if (Test-Path (Join-Path $sshDir $k)) { $hasKey = $true; break }
}
if (-not $hasKey) {
    # ssh-agent may hold keys with no key file on disk. Get-Service is
    # Windows-only (it does not exist on Linux/macOS), so use a portable check:
    # ask ssh-add whether it can see any identities.
    $sshAdd = Get-Command ssh-add -ErrorAction SilentlyContinue
    if ($sshAdd) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $identities = (& $sshAdd -l 2>&1 | Out-String)
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($identities -match 'SHA256:|ssh-(rsa|ed25519|dss)') { $hasKey = $true }
    }
}

if (-not $hasKey) {
    $sshState = 'no-key'
    $sshDetail = "no private key in $sshDir and ssh-agent is not running"
} else {
    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $ssh) {
        $sshState = 'unknown'
        $sshDetail = 'ssh client not found'
    } else {
        # BatchMode prevents an interactive prompt from hanging the probe.
        # `ssh -T` writes its diagnostics to stderr, and with
        # $ErrorActionPreference='Stop' PowerShell 5.1 turns those into
        # terminating errors before the output can be inspected. Relax the
        # preference around the call and capture 2>&1 explicitly.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
                -o ConnectTimeout=8 -T git@github.com 2>&1 | Out-String
        } finally {
            $ErrorActionPreference = $prevEap
        }
        $text = "$out"

        if ($text -match 'successfully authenticated') {
            $sshState = 'transport-ok'
            $sshDetail = 'key is authorized on GitHub'
        } elseif ($text -match 'Permission denied \(publickey\)') {
            # Reached the auth phase, so transport is fine; the key is not
            # registered on the account matching this machine.
            $sshState = 'auth-fail'
            $sshDetail = 'transport OK but the key is not authorized on any GitHub account'
            Add-Warning 'SSH reaches GitHub but the key is not registered; use HTTPS or add the key to GitHub'
        } elseif ($text -match 'Connection refused|Connection timed out|Network is unreachable') {
            $sshState = 'blocked'
            $sshDetail = ($text -split "`n")[0].Trim()
            Add-Warning 'SSH transport is blocked (port 22/443); use HTTPS or ssh.github.com:443'
        } else {
            $sshState = 'unknown'
            $sshDetail = ($text -split "`n")[0].Trim()
        }
    }
}

# -- HTTPS / git credential --------------------------------------------------
$httpsState = 'unknown'
$httpsDetail = $null

$helper = ''
# Helpers below invoke external commands that routinely write to stderr
# (git config exits non-zero when a key is unset; gh prints errors). Under
# $ErrorActionPreference='Stop', PowerShell 5.1 promotes that stderr to a
# terminating error, so relax it for every external call.
function Invoke-External {
    param([scriptblock]$Action)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Action 2>&1 | Out-String) } finally { $ErrorActionPreference = $prev }
}

$helper = (Invoke-External { git config --get 'credential.https://github.com.helper' }).Trim()
if (-not $helper) {
    $helper = (Invoke-External { git config --get credential.helper }).Trim()
}

if (-not $helper) {
    $httpsState = 'no-credentials'
    $httpsDetail = 'no credential helper configured; git push over HTTPS will prompt or fail'
    Add-Warning 'no git credential helper configured for github.com'
} elseif ($helper -match 'gh') {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $perm = (Invoke-External { gh api "repos/$Repo" --jq '.permissions.push' }).Trim()
        if ($perm -eq 'true') {
            $httpsState = 'ok'
            $httpsDetail = "gh token has push permission on $Repo"
        } elseif ($perm -eq 'false') {
            $httpsState = 'permission-denied'
            $httpsDetail = "gh token is valid but lacks push permission on $Repo"
            Add-Warning "the GitHub token has no write permission on $Repo"
        } else {
            $httpsState = 'no-credentials'
            $httpsDetail = 'gh is present but has no usable token'
        }
    } else {
        $httpsState = 'unknown'
        $httpsDetail = 'credential helper references gh, which is not installed'
    }
} else {
    $httpsState = 'ok'
    $httpsDetail = "credential helper: $helper"
}

# -- gh auth state -----------------------------------------------------------
# env_var_shadowed is the subtle one: an invalid GITHUB_TOKEN shadows a valid
# keyring token, so every gh call returns 401 while git keeps working.
$ghState = 'error'
$ghWarning = $null
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $loginOut = (Invoke-External { gh api user --jq .login }).Trim()
    $ghOk = $loginOut -and $loginOut -notmatch 'error|401|Bad credentials'
    if ($env:GITHUB_TOKEN) {
        if ($ghOk) {
            $ghState = 'keyring_ok'
        } else {
            $ghState = 'env_var_shadowed'
            $ghWarning = 'GITHUB_TOKEN is set but invalid; it shadows a valid keyring token and breaks all gh commands (git operations are unaffected)'
            Add-Warning 'GITHUB_TOKEN is invalid and shadows the keyring token'
        }
    } else {
        if ($ghOk) { $ghState = 'keyring_ok' } else { $ghState = 'none' }
    }
} else {
    $ghState = 'none'
}

# -- Emit --------------------------------------------------------------------
$warnJson = if ($script:Warnings.Count -eq 0) { '[]' } else { '[' + (($script:Warnings | ForEach-Object { ConvertTo-JsonLiteral $_ }) -join ',') + ']' }

$json = '{'
$json += '"ssh":{"state":"' + $sshState + '","detail":' + (ConvertTo-JsonLiteral $sshDetail) + '},'
$json += '"https":{"state":"' + $httpsState + '","detail":' + (ConvertTo-JsonLiteral $httpsDetail) + '},'
$json += '"gh":{"state":"' + $ghState + '","warning":' + (ConvertTo-JsonLiteral $ghWarning) + '},'
$json += '"warnings":' + $warnJson
$json += '}'

[Console]::Out.Write($json)
