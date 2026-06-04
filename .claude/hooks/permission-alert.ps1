Add-Type -AssemblyName System.Windows.Forms

$inputJson = $input | Out-String
$data = $inputJson | ConvertFrom-Json

$command = $data.tool_input.command
$description = $data.tool_input.description

if (-not $description) { $description = "(no description)" }

# Truncate long commands for display
if ($command.Length -gt 200) { $command = $command.Substring(0, 200) + "..." }

$body = @"
Command: $command

Description: $description

Please check the Claude Code terminal and confirm the authorization request.
"@

# MessageBox with 30-second timeout via Wscript.Shell Popup (non-blocking within reason)
$ws = New-Object -ComObject WScript.Shell
$result = $ws.Popup($body, 30, "Claude Code - Permission Required", 48 + 4096)
