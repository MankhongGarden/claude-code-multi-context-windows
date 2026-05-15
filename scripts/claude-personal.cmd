@echo off
REM Claude CLI wrapper - Personal/secondary account
REM Routes config to D:\ClaudeData\.claude-personal\
REM Usage: claude-personal [args]   (from any shell: cmd, pwsh, bash, etc.)

set "CLAUDE_CONFIG_DIR=D:\ClaudeData\.claude-personal"
set "MEMORY_FILE_PATH=D:\ClaudeData\.claude-personal\memory-graph.json"

echo [claude-personal] CLAUDE_CONFIG_DIR=%CLAUDE_CONFIG_DIR%
echo [claude-personal] MEMORY_FILE_PATH=%MEMORY_FILE_PATH%

claude %*
