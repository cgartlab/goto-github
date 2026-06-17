# Bootstrap installer — pure ASCII, no BOM, iex-compatible
param([string]$InstallArgs)
$_POLICY = Get-ExecutionPolicy
if ($_POLICY -eq "Restricted" -or $_POLICY -eq "AllSigned") {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}
# Primary: GitHub raw (no BOM, always fresh)
# Fallback: jsDelivr (may have stale cache)
$primaryUrl='https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1'
$fallbackUrl='https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.ps1'
$t=$env:TEMP+'\goto-github-install.ps1'

# Download with primary first, fallback on error
try {
    Invoke-WebRequest -Uri $primaryUrl -OutFile $t -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
} catch {
    Invoke-WebRequest -Uri $fallbackUrl -OutFile $t -TimeoutSec 30 -UseBasicParsing
}

# Add UTF-8 BOM so Windows PS 5.1 reads as UTF-8 (not GB2312)
$bytes = [System.IO.File]::ReadAllBytes($t)
if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {
    $bom = [byte[]](239, 187, 191)
    [System.IO.File]::WriteAllBytes($t, $bom + $bytes)
}

& $t @PSBoundParameters