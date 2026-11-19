@echo off
REM tests\mocks\mock-curl.cmd
REM Mock curl.exe for PowerShell tests.
REM PowerShell's call operator `& $path args` parses args as PS parameters,
REM which breaks for `-o NUL` (ambiguous with -OutVariable/-OutBuffer).
REM A .cmd file sidesteps this: cmd.exe receives the raw %* line.
REM
REM Usage (called by Test-IpQuick / Test-Ip, and by the ForEach-Object -Parallel
REM scan blocks in Test-PriorityIp / Test-CidrRange):
REM   mock-curl.cmd --resolve "github.com:443:IP" -s -o BODYFILE -w "format" ...
REM
REM Canned responses (code, timing, size, body written to the -o target):
REM   140.82.112.3  -> 200 valid advertisement   -> 200,0.050,150000
REM   140.82.112.4  -> 500 server error          -> 500,0.100,0
REM   140.82.112.9  -> 200 FAKE, body "OK"       -> 200,0.030,0
REM   185.199.*     -> 404 not found             -> 404,0.200,0
REM   192.30.*      -> 200 small body            -> 200,0.080,50000
REM   143.55.*      -> 200 valid                 -> 200,0.150,150000
REM   default       -> 200 valid                 -> 200,0.123,150000
REM
REM A passing probe must see a real git smart-http advertisement (starting with
REM a 4-hex-digit pkt-line length such as "001e"), so a 200 with body "OK" must
REM be rejected -- that is the fake-edge case seen on CN lines.

setlocal enableextensions enabledelayedexpansion

set "code=200"
set "time=0.123"
set "size=150000"
set "body=001e# service=git-upload-pack"
set "full=0"
set "outfile="

REM Detect Test-Ip (full triple) vs Test-IpQuick (code only) by -w format
echo %* | findstr /C:"%%{http_code},%%{time_total},%%{size_download}" >nul && set "full=1"

REM Extract the -o target: the token right after "-o".
set "_prev_o="
for %%A in (%*) do (
    if defined _prev_o (
        set "outfile=%%~A"
        set "_prev_o="
    )
    if "%%~A"=="-o" set "_prev_o=1"
)

echo %* | findstr /C:"github.com:443:140.82.112.3" >nul && (
    set "code=200"& set "time=0.050"& set "size=150000"& goto :output
)
echo %* | findstr /C:"github.com:443:140.82.112.4" >nul && (
    set "code=500"& set "time=0.100"& set "size=0"& set "body="& goto :output
)
echo %* | findstr /C:"github.com:443:140.82.112.9" >nul && (
    set "code=200"& set "time=0.030"& set "size=0"& set "body=OK"& goto :output
)
echo %* | findstr /C:"github.com:443:185.199." >nul && (
    set "code=404"& set "time=0.200"& set "size=0"& set "body="& goto :output
)
echo %* | findstr /C:"github.com:443:192.30." >nul && (
    set "code=200"& set "time=0.080"& set "size=50000"& goto :output
)
echo %* | findstr /C:"github.com:443:143.55." >nul && (
    set "code=200"& set "time=0.150"& set "size=150000"& goto :output
)

:output
if defined outfile if /I not "%outfile%"=="NUL" (
    if defined body (
        >"%outfile%" echo(!body!
    )
)

if "%full%"=="1" (
    echo %code%,%time%,%size%
) else (
    echo %code%
)
endlocal
