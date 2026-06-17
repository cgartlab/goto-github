# Bootstrap installer — pure ASCII, no BOM, iex-compatible
param([string]$InstallArgs)
$_POLICY = Get-ExecutionPolicy
if ($_POLICY -eq "Restricted" -or $_POLICY -eq "AllSigned") {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}
$u='https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.ps1'
$t=$env:TEMP+'\goto-github-install.ps1'
try {
    Invoke-WebRequest -Uri $u -OutFile $t -TimeoutSec 30 -UseBasicParsing
} catch {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1" -OutFile $t -TimeoutSec 30 -UseBasicParsing
}
& $t @PSBoundParameters
