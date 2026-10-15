param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RegSelf    = Join-Path $PSScriptRoot "_selftest_courier_registry_v1.ps1"
$OpenSes    = Join-Path $PSScriptRoot "courier_open_session_v1.ps1"
$Bootstrap  = Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1"
$Pipeline   = Join-Path $PSScriptRoot "courier_cli_run_pipeline_v1.ps1"
$Send       = Join-Path $PSScriptRoot "courier_transport_send_v1.ps1"
$Listen     = Join-Path $PSScriptRoot "courier_transport_listen_v1.ps1"

function Fail([string]$Code){ throw $Code }

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir)){
    [void][System.IO.Directory]::CreateDirectory($dir)
  }
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
    Fail ("NEGATIVE_FAIL:EXPECTED_ONE_DIR:" + $Root + ":COUNT_" + $dirs.Count)
  }
  return $dirs[0]
}

function Get-RejectReason([string]$RejectedRoot){
  $dir = Get-OnlyDir $RejectedRoot
  $reasonPath = Join-Path $dir.FullName "reject_reason.txt"
  if(-not (Test-Path -LiteralPath $reasonPath -PathType Leaf)){
    Fail "NEGATIVE_FAIL:MISSING_REJECT_REASON"
  }
  return (Get-Content -LiteralPath $reasonPath -Raw).Trim()
}

function Assert-Contains([string]$Text,[string]$Token,[string]$Name){
  if($Text -notmatch [regex]::Escape($Token)){
    Fail ("NEGATIVE_FAIL:" + $Name + ":EXPECTED_TOKEN_MISSING:" + $Token + ":ACTUAL:" + $Text)
  }
}

function Prepare-Base([string]$CaseRoot){
  $Drop     = Join-Path $CaseRoot "drop"
  $Accepted = Join-Path $CaseRoot "accepted"
  $Rejected = Join-Path $CaseRoot "rejected"
  $Cfg      = Join-Path $CaseRoot "listener.config.json"

  Reset-Dir $CaseRoot
  Reset-Dir $Drop
  Reset-Dir $Accepted
  Reset-Dir $Rejected

  # Distinct name: PowerShell variables are case-insensitive, so $cfg would overwrite the $Cfg path.
  $cfgObj = [ordered]@{
    drop_root = ($Drop.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
    accepted_root = ($Accepted.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
    rejected_root = ($Rejected.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  }
  Write-Utf8NoBomLf $Cfg (($cfgObj | ConvertTo-Json -Depth 10 -Compress))
  return [ordered]@{
    Drop = $Drop
    Accepted = $Accepted
    Rejected = $Rejected
    Config = $Cfg
  }
}

function Prepare-BaselineTransport([string]$CaseRoot){
  $roots = Prepare-Base $CaseRoot

  $code = Run-PS $RegSelf @{ RepoRoot = $RepoRoot }
  if($code -ne 0){ Fail ("NEGATIVE_FAIL:REGISTRY_SELFTEST_EXIT_" + $code) }

  $code = Run-PS $OpenSes @{
    RepoRoot = $RepoRoot
    SessionId = "session-alpha-beta-002"
    SenderNodeId = "node-alpha"
    RecipientNodeId = "node-beta"
    NetworkId = "courier-internal-net-v1"
    SessionRole = "message-delivery"
  }
  if($code -ne 0){ Fail ("NEGATIVE_FAIL:OPEN_SESSION_EXIT_" + $code) }

  $code = Run-PS $Bootstrap @{ RepoRoot = $RepoRoot }
  if($code -ne 0){ Fail ("NEGATIVE_FAIL:BOOTSTRAP_EXIT_" + $code) }

  $code = Run-PS $Pipeline @{
    RepoRoot = $RepoRoot
    InputDir = (Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep")
  }
  if($code -ne 0){ Fail ("NEGATIVE_FAIL:PIPELINE_EXIT_" + $code) }

  $MessagePath = Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json"

  $code = Run-PS $Send @{
    RepoRoot = $RepoRoot
    MessagePath = $MessagePath
    SenderIdentity = "courier-local@covenant"
    RecipientIdentity = "courier-local@covenant"
    SenderNodeId = "node-alpha"
    RecipientNodeId = "node-beta"
    NetworkId = "courier-internal-net-v1"
    SessionId = "session-alpha-beta-002"
    SenderRole = "message-delivery"
    DropRoot = $roots.Drop
  }
  if($code -ne 0){ Fail ("NEGATIVE_FAIL:SEND_EXIT_" + $code) }

  $frameDir  = Get-OnlyDir $roots.Drop
  $frameJson = Join-Path $frameDir.FullName "frame.json"
  return [ordered]@{
    Drop = $roots.Drop
    Accepted = $roots.Accepted
    Rejected = $roots.Rejected
    Config = $roots.Config
    FrameDir = $frameDir.FullName
    FrameJson = $frameJson
  }
}

function Run-Case([string]$Name,[string]$ExpectedToken,[scriptblock]$Mutator){
  Write-Host ("RUN_NEGATIVE: " + $Name)
  $caseRoot = Join-Path $RepoRoot ("test_vectors\courier_v1\negatives\" + $Name)
  $ctx = Prepare-BaselineTransport $caseRoot

  & $Mutator $ctx

  $code = Run-PS $Listen @{
    RepoRoot = $RepoRoot
    ConfigPath = $ctx.Config
  }
  if($code -ne 0){ Fail ("NEGATIVE_FAIL:" + $Name + ":LISTEN_EXIT_" + $code) }

  $reason = Get-RejectReason $ctx.Rejected
  Assert-Contains $reason $ExpectedToken $Name
  Write-Host ("NEGATIVE_OK: " + $Name + " -> " + $ExpectedToken)
}

Run-Case "unknown_sender_node" "COURIER_TRANSPORT_FAIL:UNKNOWN_SENDER_NODE" {
  param($ctx)
  $obj = Get-Content -LiteralPath $ctx.FrameJson -Raw | ConvertFrom-Json
  $obj.sender_node_id = "node-gamma"
  Write-Utf8NoBomLf $ctx.FrameJson (($obj | ConvertTo-Json -Depth 20 -Compress))
}

Run-Case "unknown_recipient_node" "COURIER_TRANSPORT_FAIL:UNKNOWN_RECIPIENT_NODE" {
  param($ctx)
  $obj = Get-Content -LiteralPath $ctx.FrameJson -Raw | ConvertFrom-Json
  $obj.recipient_node_id = "node-gamma"
  Write-Utf8NoBomLf $ctx.FrameJson (($obj | ConvertTo-Json -Depth 20 -Compress))
}

Run-Case "unknown_network" "COURIER_TRANSPORT_FAIL:UNKNOWN_NETWORK" {
  param($ctx)
  $obj = Get-Content -LiteralPath $ctx.FrameJson -Raw | ConvertFrom-Json
  $obj.network_id = "courier-unknown-net"
  Write-Utf8NoBomLf $ctx.FrameJson (($obj | ConvertTo-Json -Depth 20 -Compress))
}

Run-Case "unknown_session" "COURIER_TRANSPORT_FAIL:UNKNOWN_SESSION" {
  param($ctx)
  $obj = Get-Content -LiteralPath $ctx.FrameJson -Raw | ConvertFrom-Json
  $obj.session_id = "session-does-not-exist"
  Write-Utf8NoBomLf $ctx.FrameJson (($obj | ConvertTo-Json -Depth 20 -Compress))
}

Run-Case "sender_role_mismatch" "COURIER_TRANSPORT_FAIL:SENDER_ROLE_MISMATCH" {
  param($ctx)
  $obj = Get-Content -LiteralPath $ctx.FrameJson -Raw | ConvertFrom-Json
  $obj.sender_role = "wrong-role"
  Write-Utf8NoBomLf $ctx.FrameJson (($obj | ConvertTo-Json -Depth 20 -Compress))
}

Run-Case "node_not_allowed_on_network" "COURIER_TRANSPORT_FAIL:NODE_NOT_ALLOWED_ON_NETWORK" {
  param($ctx)
  $netPath = Join-Path $RepoRoot "registry\networks\courier-internal-net-v1.json"
  $net = Get-Content -LiteralPath $netPath -Raw | ConvertFrom-Json
  $net.allowed_nodes = @("node-alpha")
  Write-Utf8NoBomLf $netPath (($net | ConvertTo-Json -Depth 20 -Compress))
}

Run-Case "payload_hash_mismatch" "COURIER_TRANSPORT_FAIL:PAYLOAD_HASH_MISMATCH" {
  param($ctx)
  $obj = Get-Content -LiteralPath $ctx.FrameJson -Raw | ConvertFrom-Json
  $obj.payload_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
  Write-Utf8NoBomLf $ctx.FrameJson (($obj | ConvertTo-Json -Depth 20 -Compress))
}

Run-Case "verify_failed" "COURIER_TRANSPORT_FAIL:PAYLOAD_HASH_MISMATCH" {
  param($ctx)
  $obj = Get-Content -LiteralPath $ctx.FrameJson -Raw | ConvertFrom-Json
  $msgPath = Join-Path $ctx.FrameDir (($obj.message_rel) -replace '/','\')
  Add-Content -LiteralPath $msgPath -Value "tamper"
}

Write-Host "VTP_NEGATIVE_SUITE_OK"
