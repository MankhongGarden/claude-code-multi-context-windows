@echo off
REM Claude CLI wrapper - Personal/secondary account
REM Routes config to D:\ClaudeData\.claude-personal\
REM Usage: claude-personal [args]   (from any shell: cmd, pwsh, bash, etc.)

set "CLAUDE_CONFIG_DIR=D:\ClaudeData\.claude-personal"
set "MEMORY_FILE_PATH=D:\ClaudeData\.claude-personal\memory-graph.json"

REM Update 2026-10: optional loading-screen intro + safe updater.
REM matrix-intro.exe starts claude-update-safe.ps1 hidden, then shows the intro
REM until Claude draws its first screen. Both live next to this file on PATH.
REM Source and how they work: https://github.com/MankhongGarden/claude-code-mods-field-notes
REM Pair it with "env": { "DISABLE_AUTOUPDATER": "1" } in this context's settings.json.
REM Without matrix-intro.exe in this folder, the wrapper just runs claude.
set "CC_INTRO_MARK=%TEMP%\claude-intro-%RANDOM%%RANDOM%.flag"
if exist "%~dp0matrix-intro.exe" start "" /b "%~dp0matrix-intro.exe" %*

REM claude is npm's claude.cmd: without "call", nothing after this line runs.
call claude %*
set "CC_RC=%ERRORLEVEL%"
if exist "%CC_INTRO_MARK%" (
  del "%CC_INTRO_MARK%" >nul 2>&1
  cls
)
exit /b %CC_RC%
