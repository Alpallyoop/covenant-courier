param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$Cli       = Join-Path $RepoRoot "scripts\courier_cli_v1.ps1"
$Send       = Join-Path $RepoRoot "scripts\courier_transport_send_v1.ps1"
$Listen     = Join-Path $RepoRoot "scripts\courier_transport_listen_v1.ps1"
$ConfigPath = Join-Path $RepoRoot "test_vectors\courier_v1\transport\listener.config.json"

$ComposeIn = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline\compose.input.json"
$DictIn    = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json"
$WorkRoot  = Join-Path $RepoRoot "test_vectors\courier_v1\transport\prep"
$TokOut    = Join-Path $WorkRoot "message.tokenized.json"

$DropRoot  = Join-Path $RepoRoot "test_vectors\courier_v1\transport\drop"
$Accepted  = Join-Path $RepoRoot "test_vectors\courier_v1\transport\accepted"
$Rejected  = Join-Path $RepoRoot "test_vectors\courier_v1\transport\rejected"

foreach($p in @($WorkRoot,$DropRoot,$Accepted,$Rejected)){
  if(Test-Path -LiteralPath $p){
    Remove-Item -LiteralPath $p -Recurse -Force
  }
  [void][System.IO.Directory]::CreateDirectory($p)
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Cli `
  -RepoRoot $RepoRoot `
  -Command run-pipeline `
  -ComposePath $ComposeIn `
  -DictionaryPath $DictIn `
  -WorkRoot $WorkRoot
if($LASTEXITCODE -ne 0){ throw ("COURIER_TRANSPORT_POS_FAIL:PIPELINE_EXIT_" + $LASTEXITCODE) }

# Registry preconditions: nodes, network and an open session for this test's frames.
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\_selftest_courier_registry_v1.ps1") -RepoRoot $RepoRoot | Out-Null
if($LASTEXITCODE -ne 0){ throw ("COURIER_TRANSPORT_POS_FAIL:REGISTRY_EXIT_" + $LASTEXITCODE) }
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\courier_open_session_v1.ps1") -RepoRoot $RepoRoot -SessionId "session-transport-selftest-001" -SenderNodeId "node-alpha" -RecipientNodeId "node-beta" -NetworkId "courier-internal-net-v1" -SessionRole "message-delivery" | Out-Null
if($LASTEXITCODE -ne 0){ throw ("COURIER_TRANSPORT_POS_FAIL:OPEN_SESSION_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Send `
  -RepoRoot $RepoRoot `
  -SenderNodeId "node-alpha" `
  -RecipientNodeId "node-beta" `
  -NetworkId "courier-internal-net-v1" `
  -SessionId "session-transport-selftest-001" `
  -SenderRole "message-delivery" `
  -MessagePath $TokOut `
  -DropRoot $DropRoot `
  -SenderIdentity "courier-local@covenant" `
  -RecipientIdentity "recipient-a"
if($LASTEXITCODE -ne 0){ throw ("COURIER_TRANSPORT_POS_FAIL:SEND_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Listen `
  -RepoRoot $RepoRoot `
  -ConfigPath $ConfigPath
if($LASTEXITCODE -ne 0){ throw ("COURIER_TRANSPORT_POS_FAIL:LISTEN_EXIT_" + $LASTEXITCODE) }

$acceptedDirs = @(Get-ChildItem -LiteralPath $Accepted -Directory)
if($acceptedDirs.Count -lt 1){
  throw "COURIER_TRANSPORT_POS_FAIL:NO_ACCEPTED_FRAME"
}

Write-Host "COURIER_TRANSPORT_POSITIVE_SELFTEST_OK"
