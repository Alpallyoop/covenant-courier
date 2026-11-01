param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$SessionId,
  # Both node devices live on this machine (local demo, or one operator running both nodes): the
  # identity fingerprints are read from the two local states, so the pin is genuine.
  [switch]$LocalPair,
  # Two machines: the session was already established with vtp2.ps1 (bundle, trust with an
  # out-of-band fingerprint, session-init / session-accept); record it here.
  [string]$Vtp2SessionId,
  [string]$SenderFingerprint,
  [string]$RecipientFingerprint
)

# Binds a Courier session to a VTP v2 session (covenant_courier.vtp2_binding.v1), so profiles with
# payload_encryption "vtp2" can deliver over it. Prints COURIER_SECURE_SESSION_OK.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_courier_vtp2_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$sessionPath = Join-Path $RepoRoot ("registry\sessions\" + $SessionId + ".json")
[void](CV2-BindingPath $RepoRoot $SessionId)
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw "COURIER_SECURE_SESSION_FAIL:SESSION_UNKNOWN" }
$session = CC-ReadJsonFile $sessionPath
if([string]$session.status -cne "open"){ throw "COURIER_SECURE_SESSION_FAIL:SESSION_NOT_OPEN" }
$sender = [string]$session.sender_node_id
$recipient = [string]$session.recipient_node_id
$sDev = CV2-DeviceId $sender; $rDev = CV2-DeviceId $recipient
$sState = CV2-StatePath $RepoRoot $sender; $rState = CV2-StatePath $RepoRoot $recipient
$work = Join-Path $RepoRoot ("runtime\vtp2\pairing\" + $SessionId)
CC-EnsureDir $work

function V([string[]]$A,[string]$Fail){
  $r = CV2-Invoke $A
  if($r.Code -ne 0){ Write-Host $r.Text.Trim(); throw ("COURIER_SECURE_SESSION_FAIL:" + $Fail + ":" + (CV2-Token $r.Text "EXIT_$($r.Code)")) }
  return $r.Text
}
function Last([string]$Text,[string]$Prefix){
  $v = $null; foreach($l in ($Text -split "`r?`n")){ if($l.StartsWith($Prefix)){ $v = $l.Substring($Prefix.Length).Trim() } }
  if([string]::IsNullOrWhiteSpace($v)){ throw ("COURIER_SECURE_SESSION_FAIL:NO_" + $Prefix.TrimEnd(':')) }
  return $v
}

if($LocalPair){
  CC-EnsureDir (Split-Path -Parent $sState)
  foreach($p in @(@($sState,$sDev),@($rState,$rDev))){
    if(-not (Test-Path -LiteralPath $p[0] -PathType Leaf)){ [void](V @("init","--state",$p[0],"--device",$p[1]) "INIT") }
  }
  $sBundle = Join-Path $work "sender.bundle.json"; $rBundle = Join-Path $work "recipient.bundle.json"
  $SenderFingerprint = Last (V @("bundle","--state",$sState,"--out",$sBundle) "BUNDLE") "VTP2_BUNDLE_OK:"
  $RecipientFingerprint = Last (V @("bundle","--state",$rState,"--out",$rBundle) "BUNDLE") "VTP2_BUNDLE_OK:"
  [void](V @("trust","--state",$sState,"--bundle",$rBundle,"--fingerprint",$RecipientFingerprint) "TRUST")
  [void](V @("trust","--state",$rState,"--bundle",$sBundle,"--fingerprint",$SenderFingerprint) "TRUST")
  $req = Join-Path $work "session-init.json"
  $Vtp2SessionId = Last (V @("session-init","--state",$sState,"--peer-bundle",$rBundle,"--out",$req) "SESSION_INIT") "VTP2_SESSION_INIT_OK:"
  [void](V @("session-accept","--state",$rState,"--request",$req) "SESSION_ACCEPT")
} else {
  if([string]::IsNullOrWhiteSpace($Vtp2SessionId) -or [string]::IsNullOrWhiteSpace($SenderFingerprint) -or [string]::IsNullOrWhiteSpace($RecipientFingerprint)){
    throw "COURIER_SECURE_SESSION_USAGE:LocalPair_or_Vtp2SessionId_SenderFingerprint_RecipientFingerprint"
  }
}
foreach($f in @($SenderFingerprint,$RecipientFingerprint)){ if($f -cnotmatch '^[0-9a-f]{64}\z'){ throw "COURIER_SECURE_SESSION_FAIL:BAD_FINGERPRINT" } }
if($Vtp2SessionId -cnotmatch '^[0-9a-f]{32}\z'){ throw "COURIER_SECURE_SESSION_FAIL:BAD_VTP2_SESSION_ID" }

$binding = [ordered]@{
  schema = "covenant_courier.vtp2_binding.v1"
  session_id = $SessionId
  sender_node_id = $sender
  recipient_node_id = $recipient
  sender_device_id = $sDev
  recipient_device_id = $rDev
  vtp2_session_id = $Vtp2SessionId
  sender_fingerprint = $SenderFingerprint
  recipient_fingerprint = $RecipientFingerprint
}
$bp = CV2-BindingPath $RepoRoot $SessionId
[void](CC-WriteDocument $bp $binding)
Write-Host ("COURIER_SECURE_SESSION_BINDING: " + $bp)
Write-Host ("COURIER_SECURE_SESSION_VTP2: " + $Vtp2SessionId)
Write-Host "COURIER_SECURE_SESSION_OK"
