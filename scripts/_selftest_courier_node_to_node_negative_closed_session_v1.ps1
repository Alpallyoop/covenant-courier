param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$RegSelf = Join-Path $PSScriptRoot "_selftest_courier_registry_v1.ps1"
$Bootstrap = Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1"
$Pipeline = Join-Path $PSScriptRoot "courier_cli_run_pipeline_v1.ps1"
$Send = Join-Path $PSScriptRoot "courier_transport_send_v1.ps1"
$Listen = Join-Path $PSScriptRoot "courier_transport_listen_v1.ps1"

$TransportRoot = Join-Path $RepoRoot "test_vectors\courier_v1\node_to_node_negative_closed"
$Prep = Join-Path $TransportRoot "prep"
$Drop = Join-Path $TransportRoot "drop"
$Accepted = Join-Path $TransportRoot "accepted"
$Rejected = Join-Path $TransportRoot "rejected"
$ConfigPath = Join-Path $TransportRoot "listener.config.json"

if(Test-Path -LiteralPath $TransportRoot){
  Remove-Item -LiteralPath $TransportRoot -Recurse -Force
}
[void][System.IO.Directory]::CreateDirectory($Prep)
[void][System.IO.Directory]::CreateDirectory($Drop)
[void][System.IO.Directory]::CreateDirectory($Accepted)
[void][System.IO.Directory]::CreateDirectory($Rejected)

$cfg = [ordered]@{
  drop_root = "test_vectors/courier_v1/node_to_node_negative_closed/drop"
  accepted_root = "test_vectors/courier_v1/node_to_node_negative_closed/accepted"
  rejected_root = "test_vectors/courier_v1/node_to_node_negative_closed/rejected"
}
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ConfigPath, (($cfg | ConvertTo-Json -Depth 10 -Compress) + "`n"), $enc)

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RegSelf -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("COURIER_NODE2NODE_NEG_FAIL:REGISTRY_SELFTEST_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("COURIER_NODE2NODE_NEG_FAIL:BOOTSTRAP_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Pipeline `
  -RepoRoot $RepoRoot `
  -InputDir (Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep")
if($LASTEXITCODE -ne 0){ throw ("COURIER_NODE2NODE_NEG_FAIL:PIPELINE_EXIT_" + $LASTEXITCODE) }

$MessagePath = Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json"
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Send `
  -RepoRoot $RepoRoot `
  -MessagePath $MessagePath `
  -SenderIdentity "courier-local@covenant" `
  -RecipientIdentity "courier-local@covenant" `
  -SenderNodeId "node-alpha" `
  -RecipientNodeId "node-beta" `
  -NetworkId "courier-internal-net-v1" `
  -SessionId "session-alpha-beta-001" `
  -SenderRole "message-delivery" `
  -DropRoot $Drop
if($LASTEXITCODE -ne 0){ throw ("COURIER_NODE2NODE_NEG_FAIL:SEND_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Listen `
  -RepoRoot $RepoRoot `
  -ConfigPath $ConfigPath
if($LASTEXITCODE -ne 0){ throw ("COURIER_NODE2NODE_NEG_FAIL:LISTEN_EXIT_" + $LASTEXITCODE) }

$rejected = @(Get-ChildItem -LiteralPath $Rejected -Directory -ErrorAction SilentlyContinue)
if($rejected.Count -lt 1){ throw "COURIER_NODE2NODE_NEG_FAIL:NO_REJECTED_FRAME" }

Write-Host "COURIER_NODE_TO_NODE_NEGATIVE_CLOSED_SESSION_OK"
