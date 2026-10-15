param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RegSelf   = Join-Path $PSScriptRoot "_selftest_courier_registry_v1.ps1"
$OpenSes   = Join-Path $PSScriptRoot "courier_open_session_v1.ps1"
$Bootstrap = Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1"
$Pipeline  = Join-Path $PSScriptRoot "courier_cli_run_pipeline_v1.ps1"
$Send      = Join-Path $PSScriptRoot "courier_transport_send_v1.ps1"
$Listen    = Join-Path $PSScriptRoot "courier_transport_listen_v1.ps1"

function Fail([string]$Code){ throw $Code }

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

function Reset-Dir([string]$Path){
  if(Test-Path -LiteralPath $Path){
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  [void][System.IO.Directory]::CreateDirectory($Path)
}

function Run-PS([string]$Script,[hashtable]$Params){
  try {
    & $Script @Params
    return 0
  }
  catch {
    Write-Host $_.ToString()
    return 1
  }
}

function Get-OnlyDir([string]$Root){
  $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
  if($dirs.Count -ne 1){
    Fail ("CROSS_NODE_FAIL:EXPECTED_ONE_DIR:" + $Root + ":COUNT_" + $dirs.Count)
  }
  return $dirs[0]
}

$CrossRoot = Join-Path $RepoRoot "proofs\cross_node\vtp_cross_node_v1"
$AlphaRoot = Join-Path $CrossRoot "node-alpha"
$BetaRoot  = Join-Path $CrossRoot "node-beta"

$AlphaOutbox   = Join-Path $AlphaRoot "outbox"
$BetaInboxDrop = Join-Path $BetaRoot  "inbox\drop"
$BetaAccepted  = Join-Path $BetaRoot  "accepted"
$BetaRejected  = Join-Path $BetaRoot  "rejected"
$BetaConfig    = Join-Path $BetaRoot  "listener.config.json"

Reset-Dir $CrossRoot
Reset-Dir $AlphaRoot
Reset-Dir $BetaRoot
Reset-Dir $AlphaOutbox
Reset-Dir $BetaInboxDrop
Reset-Dir $BetaAccepted
Reset-Dir $BetaRejected

$cfg = [ordered]@{
  drop_root     = ($BetaInboxDrop.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  accepted_root = ($BetaAccepted.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  rejected_root = ($BetaRejected.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
}
Write-Utf8NoBomLf $BetaConfig (($cfg | ConvertTo-Json -Depth 10 -Compress))

$code = Run-PS $RegSelf @{ RepoRoot = $RepoRoot }
if($code -ne 0){ Fail ("CROSS_NODE_FAIL:REGISTRY_SELFTEST_EXIT_" + $code) }

$code = Run-PS $OpenSes @{
  RepoRoot = $RepoRoot
  SessionId = "session-alpha-beta-cross-001"
  SenderNodeId = "node-alpha"
  RecipientNodeId = "node-beta"
  NetworkId = "courier-internal-net-v1"
  SessionRole = "message-delivery"
}
if($code -ne 0){ Fail ("CROSS_NODE_FAIL:OPEN_SESSION_EXIT_" + $code) }

$code = Run-PS $Bootstrap @{ RepoRoot = $RepoRoot }
if($code -ne 0){ Fail ("CROSS_NODE_FAIL:BOOTSTRAP_EXIT_" + $code) }

$code = Run-PS $Pipeline @{
  RepoRoot = $RepoRoot
  InputDir = (Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep")
}
if($code -ne 0){ Fail ("CROSS_NODE_FAIL:PIPELINE_EXIT_" + $code) }

$MessagePath = Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json"

# node-alpha sends into its own outbox
$code = Run-PS $Send @{
  RepoRoot = $RepoRoot
  MessagePath = $MessagePath
  SenderIdentity = "courier-local@covenant"
  RecipientIdentity = "courier-local@covenant"
  SenderNodeId = "node-alpha"
  RecipientNodeId = "node-beta"
  NetworkId = "courier-internal-net-v1"
  SessionId = "session-alpha-beta-cross-001"
  SenderRole = "message-delivery"
  DropRoot = $AlphaOutbox
}
if($code -ne 0){ Fail ("CROSS_NODE_FAIL:SEND_EXIT_" + $code) }

$alphaFrame = Get-OnlyDir $AlphaOutbox

# boundary handoff: move frame from alpha outbox to beta inbox/drop
$betaDropFrame = Join-Path $BetaInboxDrop $alphaFrame.Name
if(Test-Path -LiteralPath $betaDropFrame){
  Remove-Item -LiteralPath $betaDropFrame -Recurse -Force
}
Move-Item -LiteralPath $alphaFrame.FullName -Destination $betaDropFrame

Write-Host ("CROSS_NODE_TRANSFER_OK: " + $betaDropFrame)

# node-beta listens independently against its own roots
$code = Run-PS $Listen @{
  RepoRoot = $RepoRoot
  ConfigPath = $BetaConfig
}
if($code -ne 0){ Fail ("CROSS_NODE_FAIL:LISTEN_EXIT_" + $code) }

$accepted = @(Get-ChildItem -LiteralPath $BetaAccepted -Directory -ErrorAction SilentlyContinue)
$rejected = @(Get-ChildItem -LiteralPath $BetaRejected -Directory -ErrorAction SilentlyContinue)

if($accepted.Count -ne 1){
  Fail ("CROSS_NODE_FAIL:EXPECTED_ONE_ACCEPTED:COUNT_" + $accepted.Count)
}
if($rejected.Count -ne 0){
  Fail ("CROSS_NODE_FAIL:UNEXPECTED_REJECTED:COUNT_" + $rejected.Count)
}

$acceptedFrame = $accepted | Select-Object -First 1
Write-Host ("CROSS_NODE_ACCEPT_OK: " + $acceptedFrame.FullName)
Write-Host "VTP_CROSS_NODE_OK"
