param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RegSelf = Join-Path $PSScriptRoot "_selftest_courier_registry_v1.ps1"
$OpenSes = Join-Path $PSScriptRoot "courier_open_session_v1.ps1"
$Bootstrap = Join-Path $PSScriptRoot "courier_bootstrap_local_trust_v1.ps1"
$Pipeline = Join-Path $PSScriptRoot "courier_cli_run_pipeline_v1.ps1"
$Send = Join-Path $PSScriptRoot "courier_transport_send_v1.ps1"
$Loop = Join-Path $PSScriptRoot "vtp_node_loop_v1.ps1"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Reset-Dir([string]$Path){
  if(Test-Path -LiteralPath $Path){
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  [void][System.IO.Directory]::CreateDirectory($Path)
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = ($Text -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

$Root = Join-Path $RepoRoot "test_vectors\vtp_node_loop"
$Drop = Join-Path $Root "drop"
$Accepted = Join-Path $Root "accepted"
$Rejected = Join-Path $Root "rejected"
$ConfigPath = Join-Path $Root "listener.config.json"

Reset-Dir $Root
Ensure-Dir $Drop
Ensure-Dir $Accepted
Ensure-Dir $Rejected

$cfg = [ordered]@{
  drop_root = ($Drop.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  accepted_root = ($Accepted.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
  rejected_root = ($Rejected.Substring($RepoRoot.Length).TrimStart('\','/')).Replace('\','/')
}
Write-Utf8NoBomLf $ConfigPath (($cfg | ConvertTo-Json -Depth 10 -Compress))

& $RegSelf -RepoRoot $RepoRoot
& $OpenSes -RepoRoot $RepoRoot -SessionId "session-node-loop-001" -SenderNodeId "node-alpha" -RecipientNodeId "node-beta" -NetworkId "courier-internal-net-v1" -SessionRole "message-delivery"
& $Bootstrap -RepoRoot $RepoRoot
& $Pipeline -RepoRoot $RepoRoot -InputDir (Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep")

$MessagePath = Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json"

& $Send `
  -RepoRoot $RepoRoot `
  -MessagePath $MessagePath `
  -SenderIdentity "courier-local@covenant" `
  -RecipientIdentity "courier-local@covenant" `
  -SenderNodeId "node-alpha" `
  -RecipientNodeId "node-beta" `
  -NetworkId "courier-internal-net-v1" `
  -SessionId "session-node-loop-001" `
  -SenderRole "message-delivery" `
  -DropRoot $Drop

& $Loop -RepoRoot $RepoRoot -NodeId "node-beta" -ConfigPath $ConfigPath -Once

$accepted = @(Get-ChildItem -LiteralPath $Accepted -Directory -ErrorAction SilentlyContinue)
$rejected = @(Get-ChildItem -LiteralPath $Rejected -Directory -ErrorAction SilentlyContinue)

if($accepted.Count -ne 1){
  throw ("VTP_NODE_LOOP_SELFTEST_FAIL:EXPECTED_ONE_ACCEPTED:COUNT_" + $accepted.Count)
}
if($rejected.Count -ne 0){
  throw ("VTP_NODE_LOOP_SELFTEST_FAIL:UNEXPECTED_REJECTED:COUNT_" + $rejected.Count)
}

Write-Host "VTP_NODE_LOOP_SELFTEST_OK"
