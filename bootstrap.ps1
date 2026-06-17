param([string]$InstallArgs)
$u='https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.ps1'
$t=$env:TEMP+'\goto-github-install.ps1'
try {
    Invoke-WebRequest -Uri $u -OutFile $t -TimeoutSec 30 -UseBasicParsing
} catch {
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1" -OutFile $t -TimeoutSec 30 -UseBasicParsing
}
if ($InstallArgs) {
    & $t $InstallArgs
} else {
    & $t
}
