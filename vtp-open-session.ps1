param([string]$RepoRoot=".")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Scripts = Join-Path $RepoRoot "scripts"

& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File (Join-Path $Scripts "courier_open_session_v1.ps1") `
  -RepoRoot $RepoRoot `
  -SessionId "session-alpha-beta-001" `
  -SenderNodeId "node-alpha" `
  -RecipientNodeId "node-beta" `
  -NetworkId "courier-internal-net-v1" `
  -SessionRole "message-delivery"

if($LASTEXITCODE -ne 0){ throw "VTP_OPEN_SESSION_FAIL" }

Write-Host "VTP_OPEN_SESSION_OK"
