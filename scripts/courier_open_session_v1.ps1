param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$SenderNodeId,
  [Parameter(Mandatory=$true)][string]$RecipientNodeId,
  [Parameter(Mandatory=$true)][string]$NetworkId,
  [Parameter(Mandatory=$true)][string]$SessionRole,
  [string]$TransportNamespace = "courier/message",
  [string]$SessionPolicyRef = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    [void][System.IO.Directory]::CreateDirectory($Path)
  }
}

function Require-File([string]$Path,[string]$Code){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw $Code }
}

if([string]::IsNullOrWhiteSpace($SessionId)){ throw "COURIER_SESSION_FAIL:MISSING_SESSION_ID" }
if([string]::IsNullOrWhiteSpace($SenderNodeId)){ throw "COURIER_SESSION_FAIL:MISSING_SENDER_NODE_ID" }
if([string]::IsNullOrWhiteSpace($RecipientNodeId)){ throw "COURIER_SESSION_FAIL:MISSING_RECIPIENT_NODE_ID" }
if([string]::IsNullOrWhiteSpace($NetworkId)){ throw "COURIER_SESSION_FAIL:MISSING_NETWORK_ID" }
if([string]::IsNullOrWhiteSpace($SessionRole)){ throw "COURIER_SESSION_FAIL:MISSING_SESSION_ROLE" }

$NodeRoot = Join-Path $RepoRoot "registry\nodes"
$NetRoot  = Join-Path $RepoRoot "registry\networks"
$SessRoot = Join-Path $RepoRoot "registry\sessions"
Ensure-Dir $SessRoot

Require-File (Join-Path $NodeRoot ($SenderNodeId + ".json")) "COURIER_SESSION_FAIL:UNKNOWN_SENDER_NODE"
Require-File (Join-Path $NodeRoot ($RecipientNodeId + ".json")) "COURIER_SESSION_FAIL:UNKNOWN_RECIPIENT_NODE"
Require-File (Join-Path $NetRoot ($NetworkId + ".json")) "COURIER_SESSION_FAIL:UNKNOWN_NETWORK"

foreach($id in @($SessionId,$SenderNodeId,$RecipientNodeId,$NetworkId)){
  if($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[A-Za-z0-9_-]\z|^[A-Za-z0-9]\z' -or $id.Contains("..")){ throw "COURIER_SESSION_FAIL:BAD_ID" }
}
$Path = Join-Path $SessRoot ($SessionId + ".json")
# A session is opened once. Opening it again with the same bindings is a no-op; a closed session stays
# closed (it is never silently reopened), and a session id is never rebound to other nodes.
if(Test-Path -LiteralPath $Path){
  $old = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  if([string]$old.status -cne "open"){ throw "COURIER_SESSION_FAIL:SESSION_CLOSED" }
  if([string]$old.sender_node_id -cne $SenderNodeId -or [string]$old.recipient_node_id -cne $RecipientNodeId -or [string]$old.network_id -cne $NetworkId -or [string]$old.session_role -cne $SessionRole -or [string]$old.session_policy_ref -cne [string]$SessionPolicyRef -or [string]$old.transport_namespace -cne $TransportNamespace){ throw "COURIER_SESSION_FAIL:SESSION_EXISTS_WITH_OTHER_BINDING" }
  Write-Host ("COURIER_OPEN_SESSION_OK: " + $Path)
  Write-Host "COURIER_OPEN_SESSION_ALREADY_OPEN"
  exit 0
}

$obj = [ordered]@{
  schema = "courier.session_registry.v1"
  session_id = $SessionId
  sender_node_id = $SenderNodeId
  recipient_node_id = $RecipientNodeId
  network_id = $NetworkId
  session_role = $SessionRole
  session_policy_ref = $SessionPolicyRef
  transport_namespace = $TransportNamespace
  opened_utc = (Get-Date).ToUniversalTime().ToString("o")
  closed_utc = $null
  status = "open"
}

$enc = New-Object System.Text.UTF8Encoding($false)
$json = $obj | ConvertTo-Json -Depth 20 -Compress
[System.IO.File]::WriteAllText($Path, ($json + "`n"), $enc)

Write-Host ("COURIER_OPEN_SESSION_OK: " + $Path)
