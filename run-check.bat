@echo off
setlocal

rem ============================================================
rem  Codex Nerf Detector - launcher
rem
rem  IMPORTANT: keep this file pure ASCII.
rem  cmd reads a batch file byte by byte using the console codepage.
rem  Non-ASCII bytes (or any chcp in mid-file) shift its read position
rem  and garble the lines that follow. All non-ASCII text lives in
rem  nerf-check.sh, which handles UTF-8 correctly.
rem ============================================================

set "SCRIPT=%~dp0nerf-check.sh"

if not exist "%SCRIPT%" (
    echo.
    echo   [ERROR] nerf-check.sh not found next to this file
    echo           %SCRIPT%
    echo.
    pause
    exit /b 1
)

rem ---------- locate Git Bash ----------
set "BASH="

rem 1) manual override: a file named bash-path.txt next to this .bat
rem    (only accepted if that path actually exists, so a stale
rem     bash-path.txt copied from another machine is ignored)
if exist "%~dp0bash-path.txt" (
    for /f "usebackq delims=" %%i in ("%~dp0bash-path.txt") do if not defined BASH if exist "%%i" set "BASH=%%i"
)

rem 2) whatever "bash" is on PATH
if not defined BASH for /f "delims=" %%i in ('where bash 2^>nul') do if not defined BASH set "BASH=%%i"

rem 3) common install locations
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined BASH if exist "D:\Git\bin\bash.exe" set "BASH=D:\Git\bin\bash.exe"
if not defined BASH if exist "E:\Git\bin\bash.exe" set "BASH=E:\Git\bin\bash.exe"

if not defined BASH (
    echo.
    echo   [ERROR] Git Bash not found on this computer.
    echo.
    echo   Please install "Git for Windows" first:
    echo       https://git-scm.com/download/win
    echo.
    echo   If Git is already installed somewhere unusual, create a file
    echo   named  bash-path.txt  next to this .bat, containing the full
    echo   path to bash.exe on one line. For example:
    echo       C:\Program Files\Git\bin\bash.exe
    echo.
    pause
    exit /b 1
)

"%BASH%" "%SCRIPT%" %1
goto :eof
