# Covenant Courier <-> VTP v2 (payload encryption for governed delivery).
#
# Each Courier node has one VTP v2 device state: runtime/vtp2/nodes/<node-id>.state, device id
# "courier-<node-id>". A Courier session (registry/sessions/<id>.json) is bound to one VTP v2
# session between its sender and recipient node devices by registry/vtp2_bindings/<id>.json
# (covenant_courier.vtp2_binding.v1). A profile with payload_encryption "vtp2" sends the payload
# only as a vtp.message.v2 envelope under that session; without a binding nothing is sent.
#
# State protection is VTP v2's own: DPAPI on Windows, VTP2_STATE_KEY_FILE elsewhere. Courier never
# creates or guesses that key.

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

function CV2-NodeIdOk([string]$NodeId){ return ($NodeId -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,71}\z') -and -not $NodeId.Contains("..") }
function CV2-DeviceId([string]$NodeId){ if(-not (CV2-NodeIdOk $NodeId)){ CC-Fail "CV2_FAIL:BAD_NODE_ID" }; return ("courier-" + $NodeId) }
function CV2-StatePath([string]$RepoRoot,[string]$NodeId){ if(-not (CV2-NodeIdOk $NodeId)){ CC-Fail "CV2_FAIL:BAD_NODE_ID" }; return (Join-Path $RepoRoot ("runtime\vtp2\nodes\" + $NodeId + ".state")) }
function CV2-BindingPath([string]$RepoRoot,[string]$SessionId){
  if($SessionId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or $SessionId.Contains("..")){ CC-Fail "CV2_FAIL:BAD_SESSION_ID" }
  return (Join-Path $RepoRoot ("registry\vtp2_bindings\" + $SessionId + ".json"))
}

# Runs vtp2.ps1 from this code's own repository (not the data root), current PowerShell host.
function CV2-Invoke([string[]]$VtpArgs){
  $vtp2 = Join-Path (Split-Path -Parent $PSScriptRoot) "vtp2.ps1"
  if(-not (Test-Path -LiteralPath $vtp2 -PathType Leaf)){ return [pscustomobject]@{ Code = 127; Text = "VTP2_CLI_MISSING" } }
  # Continue: under Stop, Windows PowerShell 5.1 turns the child's stderr (VTP v2 writes its failure
  # token there) into a terminating error, so the token and exit code would be lost.
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { $out = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vtp2 @VtpArgs 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prevEap }
  return [pscustomobject]@{ Code = $code; Text = ($out | Out-String) }
}

function CV2-Token([string]$Text,[string]$Fallback){
  foreach($l in ($Text -split "`r?`n")){ if($l -cmatch '^(VTP2_[A-Z0-9_]+(:[A-Za-z0-9_.-]+)?)\s*$'){ return $Matches[1] } }
  return $Fallback
}

# Returns the binding object, or $null when the session has none. Fails closed on a binding that
# does not describe this session's nodes.
function CV2-ReadBinding([string]$RepoRoot,[string]$SessionId,[string]$SenderNodeId,[string]$RecipientNodeId){
  $p = CV2-BindingPath $RepoRoot $SessionId
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ return $null }
  $b = CC-ReadJsonFile $p
  CC-RequireExactProps $b @("schema","session_id","sender_node_id","recipient_node_id","sender_device_id","recipient_device_id","vtp2_session_id","recipient_fingerprint","sender_fingerprint") @() "VTP2_BINDING"
  if([string]$b.schema -cne "covenant_courier.vtp2_binding.v1"){ CC-Fail "VTP2_BINDING:BAD_SCHEMA" }
  if([string]$b.session_id -cne $SessionId -or [string]$b.sender_node_id -cne $SenderNodeId -or [string]$b.recipient_node_id -cne $RecipientNodeId){ CC-Fail "VTP2_BINDING:NODE_MISMATCH" }
  if([string]$b.sender_device_id -cne (CV2-DeviceId $SenderNodeId) -or [string]$b.recipient_device_id -cne (CV2-DeviceId $RecipientNodeId)){ CC-Fail "VTP2_BINDING:DEVICE_MISMATCH" }
  if([string]$b.vtp2_session_id -cnotmatch '^[0-9a-f]{32}\z'){ CC-Fail "VTP2_BINDING:BAD_SESSION" }
  return $b
}
