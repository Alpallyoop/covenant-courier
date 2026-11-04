param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

# The receiver decides for itself (courier_receive_message_v1.ps1), in a sandbox data root:
#   1. an honest delivery is received; the inbox notification is built from the receiver's profile
#   2. an envelope signed with the node key that claims "allow" for a restricted payload is refused by
#      the receiver's own policy (nothing reaches the inbox)
#   3. a sender-chosen notification (full_safe preview) is replaced by the receiver's
#   4. an accepted frame re-framed under a new frame id is a replay (same signed payload)
#   5. a receipt log with unchained lines is not used

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$PS = CC-HostExe
$Run = Join-Path $RepoRoot ("runtime\selftest_receive_policy\" + (CC-UtcStampId))
$Sandbox = Join-Path $Run "repo"
$Cases = 0
function Must([bool]$c,[string]$code){ if(-not $c){ throw ("COURIER_RECEIVE_POLICY_SELFTEST_FAIL:" + $code) } }
function Child([string]$Script,[string[]]$A){ $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; try { $o = & $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @A 2>&1; $c = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }; return @{ Code = $c; Text = ($o | Out-String) } }
function S([string]$Name){ return (Join-Path $PSScriptRoot $Name) }
$Log = Join-Path $Sandbox "proofs\receipts\covenant_courier_product.ndjson"

# Data only (policy files); the code runs from this installation.
CC-EnsureDir $Sandbox
foreach($p in @("policy","policies")){ Copy-Item -LiteralPath (Join-Path $RepoRoot $p) -Destination $Sandbox -Recurse -Force }
$r = Child (S "courier_seed_demo_registry_v1.ps1") @("-RepoRoot",$Sandbox); Must ($r.Code -eq 0) ("SEED:" + $r.Text)
$r = Child (S "courier_open_session_v1.ps1") @("-RepoRoot",$Sandbox,"-SessionId","session-alpha-beta-001","-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery"); Must ($r.Code -eq 0) ("SESSION:" + $r.Text)
$r = Child (S "courier_bootstrap_local_trust_v1.ps1") @("-RepoRoot",$Sandbox); Must ($r.Code -eq 0) ("BOOTSTRAP:" + $r.Text)
$principal = "courier-local@covenant"

function Receive(){ return (Child (S "courier_receive_message_v1.ps1") @("-RepoRoot",$Sandbox,"-NodeId","node-beta")) }
function Inbox([string]$Id){ return (Join-Path $Sandbox ("runtime\product_messages\inbox\node-beta\" + $Id)) }

# 1. honest delivery
$r = Child (S "courier_prepare_message_v1.ps1") @("-RepoRoot",$Sandbox,"-From","local/sender/demo","-To","local/recipient/demo","-RecipientNodeId","node-beta","-SessionId","session-alpha-beta-001","-PolicyProfile","default","-PayloadText","quarterly numbers attached","-Origin","human")
Must ($r.Code -eq 0) ("PREPARE:" + $r.Text)
$msg = $null; $pay = $null
foreach($l in ($r.Text -split "`n")){ if($l -match 'COURIER_PREPARE_MESSAGE_OK:\s+(.+)$'){ $msg = $Matches[1].Trim() }; if($l -match 'COURIER_PREPARE_PAYLOAD_OK:\s+(.+)$'){ $pay = $Matches[1].Trim() } }
$out1 = Join-Path $Run "honest"
$r = Child (S "courier_deliver_v1.ps1") @("-RepoRoot",$Sandbox,"-MessagePath",$msg,"-PayloadPath",$pay,"-OutDir",$out1)
Must ($r.Code -eq 0) ("DELIVER:" + $r.Text)
$honest = CC-ReadJsonFile $msg
$honestFrame = [string](CC-ReadJsonFile (Join-Path $out1 "product_receipt.json")).frame_id
$r = Receive
Must ($r.Code -eq 0 -and $r.Text -match "COVENANT_COURIER_RECEIVE_OK") ("RECEIVE_HONEST:" + $r.Text)
$nt = CC-ReadJsonFile (Join-Path (Inbox ([string]$honest.message_id)) "notification.json")
Must ([string]$nt.display_mode -eq "generic" -and [string]$nt.preview -eq "New secure message") "HONEST_NOTIFICATION"
$Cases++; Write-Host "COURIER_RECEIVE_POLICY_CASE_OK: honest delivery -> received, notification from the receiver's profile"

# A delivery envelope built and signed by hand with the node key (what a holder of that key can do),
# framed with the real transport and logged as "sent".
function Forge([string]$Id,[string]$PayloadText,[string]$Mode,[string]$Preview){
  $bytes = (CC-Utf8NoBom).GetBytes($PayloadText)
  $sha = CC-Sha256Bytes $bytes
  $dir = Join-Path $Run ("forge-" + $Id); CC-EnsureDir $dir
  $m = [ordered]@{
    schema = "covenant_courier.message.v1"; message_id = $Id; sender_identity = "local/sender/demo"; recipient_identity = "local/recipient/demo"
    sender_node_id = "node-alpha"; recipient_node_id = "node-beta"; session_id = "session-alpha-beta-001"; policy_profile = "default"
    notification_preview = $Preview; payload_sha256 = $sha; created_utc = (CC-UtcNow); origin = "human"
  }
  $envelope = [ordered]@{
    schema = "covenant_courier.delivery.v1"; message = $m
    policy_decision = [ordered]@{ schema = "covenant_courier.policy_decision.v1"; decision_id = "ccdec-forged"; message_id = $Id; decision = "allow"; reason_code = "POLICY_ALLOW"; policy_profile = "default"; decided_utc = (CC-UtcNow) }
    notification = [ordered]@{ schema = "covenant_courier.notification.v1"; message_id = $Id; recipient_identity = "local/recipient/demo"; display_mode = $Mode; preview = $Preview; created_utc = (CC-UtcNow) }
    payload_b64 = [Convert]::ToBase64String($bytes)
  }
  $dp = Join-Path $dir "delivery.json"
  [void](CC-WriteDocument $dp $envelope)
  $s = Child (S "courier_sign_message_v1.ps1") @("-RepoRoot",$Sandbox,"-MessagePath",$dp,"-SignerIdentity",$principal,"-Namespace","courier/message")
  Must ($s.Code -eq 0) ("FORGE_SIGN:" + $s.Text)
  $t = Child (S "courier_transport_send_v1.ps1") @("-RepoRoot",$Sandbox,"-MessagePath",$dp,"-SenderIdentity",$principal,"-RecipientIdentity",$principal,"-SenderNodeId","node-alpha","-RecipientNodeId","node-beta","-NetworkId","courier-internal-net-v1","-SessionId","session-alpha-beta-001","-SenderRole","message-delivery","-DropRoot",(Join-Path $Sandbox "runtime\nodes\node-beta\inbox\drop"))
  Must ($t.Code -eq 0) ("FORGE_SEND:" + $t.Text)
  $frameId = $null; foreach($l in ($t.Text -split "`n")){ if($l -match 'COURIER_TRANSPORT_SEND_OK:\s+(.+)$'){ $frameId = Split-Path -Leaf $Matches[1].Trim() } }
  Add-SentLine $Id $frameId $sha
  return $frameId
}
function Add-SentLine([string]$Id,[string]$FrameId,[string]$Sha){
  $line = CC-ToJson ([ordered]@{ schema = "covenant_courier.product_receipt.v1"; receipt_id = ("ccreceipt-forged-" + [guid]::NewGuid().ToString("N").Substring(0,8)); message_id = $Id; event_type = "covenant_courier.product.send.v1"; time_utc = (CC-UtcNow); frame_id = $FrameId; payload_sha256 = $Sha; decision = "sent"; reason_code = "POLICY_ALLOW" })
  CC-AppendLine $Log $line
  $c = Child (S "courier_receipt_chain_v1.ps1") @("-RepoRoot",$Sandbox); Must ($c.Code -eq 0) ("CHAIN:" + $c.Text)
}

# 2. "allow" claimed for a payload the receiver's policy quarantines
Start-Sleep -Milliseconds 1100
[void](Forge "ccmsg-forged-restricted" "meet by the rose at noon" "minimal" "")
$r = Receive
Must ($r.Code -ne 0 -and $r.Text -match "DELIVERY_ENVELOPE_INVALID:RECEIVER_POLICY_QUARANTINE:RESTRICTED_TERM") ("FORGED_ALLOW:" + $r.Text)
Must (-not (Test-Path -LiteralPath (Inbox "ccmsg-forged-restricted"))) "FORGED_NOT_IN_INBOX"
$Cases++; Write-Host "COURIER_RECEIVE_POLICY_CASE_OK: forged allow for a restricted payload -> refused by the receiver's policy"

# 3. a sender-chosen notification is not shown
Start-Sleep -Milliseconds 1100
[void](Forge "ccmsg-forged-notification" "nothing restricted here" "full_safe" "Open this now")
$r = Receive
Must ($r.Code -eq 0) ("FORGED_NOTIFICATION:" + $r.Text)
$nt = CC-ReadJsonFile (Join-Path (Inbox "ccmsg-forged-notification") "notification.json")
Must ([string]$nt.display_mode -eq "generic" -and [string]$nt.preview -eq "New secure message") ("NOTIFICATION_REPLACED:" + [string]$nt.display_mode)
$Cases++; Write-Host "COURIER_RECEIVE_POLICY_CASE_OK: sender-chosen full_safe notification -> receiver's generic notification"

# 4. the honest accepted frame, re-framed under a new frame id
Start-Sleep -Milliseconds 1100
$newFrame = "frame-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ").Replace(".","")
$src = Join-Path $Sandbox ("runtime\nodes\node-beta\accepted\" + $honestFrame)
$dst = Join-Path $Sandbox ("runtime\nodes\node-beta\inbox\drop\" + $newFrame)
Copy-Item -LiteralPath $src -Destination $dst -Recurse
$fj = CC-ReadJsonFile (Join-Path $dst "frame.json"); $fj.frame_id = $newFrame
[void](CC-WriteDocument (Join-Path $dst "frame.json") (CC-ToOrderedTree $fj))
Add-SentLine ([string]$honest.message_id) $newFrame ([string]$honest.payload_sha256)
$r = Receive
Must ($r.Code -ne 0 -and $r.Text -match "REPLAY_DETECTED") ("REFRAMED_REPLAY:" + $r.Text)
$Cases++; Write-Host "COURIER_RECEIVE_POLICY_CASE_OK: accepted frame re-framed under a new id -> REPLAY_DETECTED"

# 5. unchained lines in the log
CC-AppendLine $Log (CC-ToJson ([ordered]@{ schema = "covenant_courier.product_receipt.v1"; receipt_id = "ccreceipt-unchained"; message_id = "ccmsg-unchained"; event_type = "covenant_courier.product.send.v1"; time_utc = (CC-UtcNow); frame_id = "frame-20260101T000000000Z"; payload_sha256 = ("0" * 64); decision = "sent"; reason_code = "POLICY_ALLOW" }))
$r = Receive
Must ($r.Code -ne 0 -and $r.Text -match "RECEIPT_LOG_HAS_UNCHAINED_LINES") ("UNCHAINED:" + $r.Text)
$Cases++; Write-Host "COURIER_RECEIVE_POLICY_CASE_OK: unchained receipt line -> log not used"

Remove-Item -LiteralPath (Join-Path $Sandbox "proofs\keys") -Recurse -Force
Write-Host ("COURIER_RECEIVE_POLICY_SELFTEST_CASES: " + $Cases)
Write-Host "COURIER_RECEIVE_POLICY_SELFTEST_OK"
