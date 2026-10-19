@echo off
REM tests\mocks\mock-curl.cmd
REM Mock curl.exe for PowerShell tests.
REM PowerShell's call operator `& $path args` parses args as PS parameters,
REM which breaks for `-o NUL` (ambiguous with -OutVariable/-OutBuffer).
REM A .cmd file sidesteps this: cmd.exe receives the raw %* line.
REM
REM Usage (called by Test-IpQuick / Test-Ip):
REM   mock-curl.cmd --resolve "github.com:443:IP" -s -o NUL -w "format" ...
REM
REM Canned responses:
REM   140.82.112.3  -> 200 (valid)        -> 200,0.050,150000
REM   140.82.112.4  -> 500 (server error) -> 500,0.100,0
REM   185.199.*     -> 404 (not found)    -> 404,0.200,0
REM   192.30.*      -> 200 small body     -> 200,0.080,50000
REM   143.55.*      -> 200 valid          -> 200,0.150,150000
REM   default       -> 200 valid          -> 200,0.123,150000

setlocal
set "code=200"
set "time=0.123"
set "size=150000"
set "full=0"

REM Detect Test-Ip (full triple) vs Test-IpQuick (code only) by -w format
echo %* | findstr /C:"%%{http_code},%%{time_total},%%{size_download}" >nul && set "full=1"

REM Match IP in the full arg line
echo %* | findstr /C:"github.com:443:140.82.112.3" >nul && (
    set "code=200" & set "time=0.050" & set "size=150000" & goto :output
)
echo %* | findstr /C:"github.com:443:140.82.112.4" >nul && (
    set "code=500" & set "time=0.100" & set "size=0" & goto :output
)
echo %* | findstr /C:"github.com:443:185.199." >nul && (
    set "code=404" & set "time=0.200" & set "size=0" & goto :output
)
echo %* | findstr /C:"github.com:443:192.30." >nul && (
    set "code=200" & set "time=0.080" & set "size=50000" & goto :output
)
echo %* | findstr /C:"github.com:443:143.55." >nul && (
    set "code=200" & set "time=0.150" & set "size=150000" & goto :output
)

:output
if "%full%"=="1" (
    echo %code%,%time%,%size%
) else (
    echo %code%
)
endlocal
