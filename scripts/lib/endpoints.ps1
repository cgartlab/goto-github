# scripts/lib/endpoints.ps1 -- the full GitHub service surface (PowerShell twin)
#
# Mirrors scripts/lib/endpoints.sh. Both must agree on the endpoint key set;
# shared/parity-check.sh asserts that.
#
# Why the full surface and not "the 5 endpoints": a developer reaches GitHub
# through many paths and they fail independently. A narrow probe reports
# "GitHub is fine" while `docker pull ghcr.io/...` or `ssh -T git@github.com`
# is dead. See references/judgment-criteria.md.
#
# PowerShell 5.1 compatible: no -Parallel, no ??, no ternary operator.

if (Get-Variable -Name 'GOTO_GITHUB_ENDPOINTS_LOADED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_ENDPOINTS_LOADED = $true

function Get-Endpoints {
    <#
    .SYNOPSIS
        Return the endpoint table for this platform.
    .PARAMETER Scope
        "fast" (default) covers everything except registries/assets;
        "all" adds them.
    .OUTPUTS
        Array of hashtables: Key, Url, Group, Kind
        Kind is http | git-smart | tcp
    #>
    param([ValidateSet('fast', 'all')][string]$Scope = 'fast')

    $repo = if ($script:PROBE_REPO) { $script:PROBE_REPO } else { 'cgartlab/goto-github' }

    $list = New-Object System.Collections.Generic.List[hashtable]

    # -- Core HTTP surface ----------------------------------------------------
    $list.Add(@{ Key = 'web';       Url = 'https://github.com/';                                         Group = 'web';      Kind = 'http' })
    $list.Add(@{ Key = 'api';       Url = 'https://api.github.com/';                                      Group = 'api';      Kind = 'http' })
    $list.Add(@{ Key = 'git_read';  Url = "https://github.com/$repo/info/refs?service=git-upload-pack";  Group = 'git';      Kind = 'git-smart' })
    $list.Add(@{ Key = 'git_write'; Url = "https://github.com/$repo/info/refs?service=git-receive-pack"; Group = 'git';      Kind = 'git-smart' })
    $list.Add(@{ Key = 'raw';       Url = "https://raw.githubusercontent.com/$repo/main/README.md";       Group = 'raw';      Kind = 'http' })
    $list.Add(@{ Key = 'gist';      Url = 'https://gist.githubusercontent.com/';                          Group = 'raw';      Kind = 'http' })
    $list.Add(@{ Key = 'download';  Url = "https://codeload.github.com/$repo/tar.gz/refs/heads/main";     Group = 'download'; Kind = 'http' })
    $list.Add(@{ Key = 'assets';    Url = 'https://github.githubassets.com/';                             Group = 'assets';   Kind = 'http' })

    # -- SSH transport (TCP only; auth is a separate dimension) ---------------
    $list.Add(@{ Key = 'ssh22';     Url = 'tcp://github.com:22';                                          Group = 'ssh';      Kind = 'tcp' })
    $list.Add(@{ Key = 'ssh443';    Url = 'tcp://ssh.github.com:443';                                     Group = 'ssh';      Kind = 'tcp' })

    # -- Package registries (slow; only in "all") -----------------------------
    if ($Scope -eq 'all') {
        $list.Add(@{ Key = 'ghcr';     Url = 'https://ghcr.io/v2/';                             Group = 'registry'; Kind = 'http' })
        $list.Add(@{ Key = 'npmpkg';   Url = 'https://npm.pkg.github.com/';                     Group = 'registry'; Kind = 'http' })
        $list.Add(@{ Key = 'mavenpkg'; Url = 'https://maven.pkg.github.com/';                   Group = 'registry'; Kind = 'http' })
        $list.Add(@{ Key = 'avatars';  Url = 'https://avatars.githubusercontent.com/';          Group = 'assets';   Kind = 'http' })
        $list.Add(@{ Key = 'objects';  Url = 'https://objects.githubusercontent.com/';          Group = 'assets';   Kind = 'http' })
        $list.Add(@{ Key = 'pages';    Url = 'https://cgartlab.github.io/';                     Group = 'web';      Kind = 'http' })
    }

    return $list
}
