param(
  [string]$RepoRoot = ".",
  [string]$NodeId = "node-beta",
  [string]$ProductReceiptPath = ""
)

# Product receive: picks the newest sent product frame that is not yet settled (accepted or
# rejected), runs the recipient node's policy loop until the transport accepts or rejects it, then
# verifies the covenant_courier.delivery.v1 envelope against the sender's product receipt before
# anything is released to the recipient inbox. Every outcome writes a product receipt.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_courier_vtp2_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_courier_policy_eval_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
# Code comes from this installation, never from the data root.
$Vtp = Join-Path (Split-Path -Parent $PSScriptRoot) "vtp.ps1"
$ReceiptRoot = Join-Path $RepoRoot "proofs\receipts"
$ProductReceipt = Join-Path $ReceiptRoot "covenant_courier_product.ndjson"
$ChainPath = Join-Path $ReceiptRoot "covenant_courier_product.chain.ndjson"
if(-not [string]::IsNullOrWhiteSpace($ProductReceiptPath)){
  $ProductReceipt = $ProductReceiptPath
  $ChainPath = $ProductReceiptPath + ".chain.ndjson"
}
if($NodeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z'){ throw "COURIER_RECEIVE_FAIL:BAD_NODE_ID" }

[void][IO.Directory]::CreateDirectory($ReceiptRoot)
if(-not (Test-Path -LiteralPath $Vtp -PathType Leaf)){ throw "COURIER_RECEIVE_FAIL:MISSING_VTP_CLI" }
if(-not (Test-Path -LiteralPath $ProductReceipt -PathType Leaf)){ throw "COURIER_RECEIVE_FAIL:MISSING_PRODUCT_RECEIPTS" }

function Run-Child([string]$Script,[string[]]$ChildArgs){
  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $out = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ChildArgs 2>&1; $ErrorActionPreference = $eapPrev
  $code = $LASTEXITCODE
  $text = ($out | Out-String)
  Write-Host $text.Trim()
  if($code -ne 0){ throw ("COURIER_RECEIVE_FAIL:CHILD_EXIT:" + $code + ":" + $Script) }
  return $text
}

function Write-Receipt([string]$MessageId,[string]$FrameId,[string]$PayloadSha,[string]$Decision,$Reason,[string]$EventType){
  $receipt = [ordered]@{
    schema = "covenant_courier.product_receipt.v1"
    receipt_id = ("ccreceipt-" + (CC-UtcStampId) + "-" + ([guid]::NewGuid().ToString("N").Substring(0,8)))
    message_id = $MessageId
    event_type = $EventType
    time_utc = (CC-UtcNow)
    frame_id = $FrameId
    payload_sha256 = $PayloadSha
    decision = $Decision
    reason_code = $Reason
  }
  $line = CC-ToJson $receipt
  CC-AppendLine $ProductReceipt $line
  Run-Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$RepoRoot,"-ReceiptPath",$ProductReceipt,"-ChainPath",$ChainPath) | Out-Null
  Write-Host ("COURIER_RECEIVE_PRODUCT_RECEIPT_SHA256: " + (CC-Sha256Text $line))
}

# The log decides the target and the replay set: verify its chain before using it.
$chk = Run-Child (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") @("-RepoRoot",$RepoRoot,"-ReceiptPath",$ProductReceipt,"-ChainPath",$ChainPath,"-VerifyOnly")
if($chk -notmatch 'COVENANT_COURIER_RECEIPT_CHAIN_UNCHAINED: 0\b'){ throw "COURIER_RECEIVE_FAIL:RECEIPT_LOG_HAS_UNCHAINED_LINES" }

$receipts = New-Object System.Collections.Generic.List[object]
foreach($line in @(Get-Content -LiteralPath $ProductReceipt -ErrorAction Stop)){
  if([string]::IsNullOrWhiteSpace($line)){ continue }
  $receipts.Add((CC-ParseJson $line))
}

$settled = New-Object 'System.Collections.Generic.HashSet[string]'
$acceptedMessages = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach($r in $receipts){
  $d = $(if(CC-HasProp $r "decision"){ [string]$r.decision } else { "" })
  $f = $(if(CC-HasProp $r "frame_id"){ [string]$r.frame_id } else { "" })
  $e = $(if(CC-HasProp $r "event_type"){ [string]$r.event_type } else { "" })
  if($d -eq "accepted" -and (CC-HasProp $r "message_id")){ [void]$acceptedMessages.Add([string]$r.message_id) }
  if((($d -eq "accepted") -or ($d -eq "rejected" -and $e -eq "covenant_courier.product.receive_reject.v1")) -and -not [string]::IsNullOrWhiteSpace($f)){ [void]$settled.Add($f) }
}

$target = $null
for($i = $receipts.Count - 1; $i -ge 0; $i--){
  $r = $receipts[$i]
  $d = $(if(CC-HasProp $r "decision"){ [string]$r.decision } else { "" })
  $f = $(if(CC-HasProp $r "frame_id"){ [string]$r.frame_id } else { "" })
  if($d -eq "sent" -and -not [string]::IsNullOrWhiteSpace($f) -and $f -ne "no-frame" -and -not $settled.Contains($f)){ $target = $r; break }
}
if($null -eq $target){ throw "COURIER_RECEIVE_FAIL:NO_UNACCEPTED_SENT_PRODUCT_FRAME" }

$messageId = [string]$target.message_id
$frameId = [string]$target.frame_id
$payloadSha = [string]$target.payload_sha256
if([string]::IsNullOrWhiteSpace($messageId)){ throw "COURIER_RECEIVE_FAIL:MESSAGE_ID_MISSING" }
if($messageId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z' -or $messageId.Contains("..")){ throw "COURIER_RECEIVE_FAIL:BAD_MESSAGE_ID" }
if($frameId -cnotmatch '^frame-[0-9TZ]+\z'){ throw "COURIER_RECEIVE_FAIL:BAD_FRAME_ID" }
if($payloadSha -cnotmatch '^[a-f0-9]{64}\z'){ throw "COURIER_RECEIVE_FAIL:BAD_PAYLOAD_SHA256" }

$acceptedPath = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\accepted\" + $frameId)
$dropPath = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\inbox\drop\" + $frameId)
$rejectedPath = Join-Path $RepoRoot ("runtime\nodes\" + $NodeId + "\rejected\" + $frameId)

$attempt = 0
while($attempt -lt 8){
  if((Test-Path -LiteralPath $acceptedPath -PathType Container) -or (Test-Path -LiteralPath $rejectedPath -PathType Container)){ break }
  Run-Child $Vtp @("node-loop","-RepoRoot",$RepoRoot,"-NodeId",$NodeId) | Out-Null
  if((Test-Path -LiteralPath $acceptedPath -PathType Container) -or (Test-Path -LiteralPath $rejectedPath -PathType Container)){ break }
  Start-Sleep -Milliseconds 250
  $attempt++
}

if(-not (Test-Path -LiteralPath $acceptedPath -PathType Container)){
  Write-Host ("COURIER_RECEIVE_FRAME: " + $frameId)
  Write-Host ("COURIER_RECEIVE_ATTEMPTS: " + $attempt)
  Write-Host ("COURIER_RECEIVE_ACCEPTED_EXISTS: " + (Test-Path -LiteralPath $acceptedPath))
  Write-Host ("COURIER_RECEIVE_DROP_EXISTS: " + (Test-Path -LiteralPath $dropPath))
  Write-Host ("COURIER_RECEIVE_REJECTED_EXISTS: " + (Test-Path -LiteralPath $rejectedPath))
  if(Test-Path -LiteralPath $rejectedPath -PathType Container){
    $reasonText = "TRANSPORT_REJECTED"
    $reasonPath = Join-Path $rejectedPath "reject_reason.txt"
    if(Test-Path -LiteralPath $reasonPath -PathType Leaf){
      $reasonText = (Get-Content -LiteralPath $reasonPath -Raw).Trim()
      Write-Host ("COURIER_RECEIVE_REJECT_REASON: " + $reasonText)
    }
    $code = ("TRANSPORT_REJECTED:" + ($reasonText -replace '[^A-Za-z0-9_:]','_'))
    if($code.Length -gt 200){ $code = $code.Substring(0,200) }
    Write-Receipt $messageId $frameId $payloadSha "rejected" $code "covenant_courier.product.receive_reject.v1"
    throw ("COURIER_RECEIVE_FAIL:FRAME_REJECTED:" + $frameId)
  }
  throw ("COURIER_RECEIVE_FAIL:FRAME_NOT_ACCEPTED:" + $frameId)
}

# Verify the delivery envelope the transport accepted (signature and frame hash were verified by
# the listener; here the product binding is checked) before releasing anything.
$verdict = $null
$envelope = $null
$payloadBytes = $null
try {
  $frame = CC-ReadJsonFile (Join-Path $acceptedPath "frame.json")
  $rel = [string]$frame.message_rel
  if([string]::IsNullOrWhiteSpace($rel) -or [IO.Path]::IsPathRooted($rel) -or $rel.Contains("..")){ throw "ENVELOPE_PATH_INVALID" }
  $envPath = Join-Path $acceptedPath $rel
  if((CC-Sha256File $envPath) -cne [string]$frame.payload_sha256){ throw "FRAME_HASH_MISMATCH" }
  $envelope = CC-ReadJsonFile $envPath -MaxBytes 1200000
  if(-not (CC-HasProp $envelope "schema") -or [string]$envelope.schema -cne "covenant_courier.delivery.v1"){ throw "NOT_A_DELIVERY_ENVELOPE" }
  CC-RequireExactProps $envelope @("schema","message","policy_decision","notification") @("payload_b64","payload_vtp2_b64") "ENVELOPE"
  $hasPlain = CC-HasProp $envelope "payload_b64"; $hasSealed = CC-HasProp $envelope "payload_vtp2_b64"
  if($hasPlain -eq $hasSealed){ throw "ENVELOPE_PAYLOAD_FORM" }
  $m = $envelope.message
  if([string]$m.schema -cne "covenant_courier.message.v1"){ throw "ENVELOPE_MESSAGE_BAD_SCHEMA" }
  if([string]$m.message_id -cne $messageId){ throw "MESSAGE_ID_MISMATCH" }
  if($acceptedMessages.Contains($messageId)){ throw "MESSAGE_ALREADY_ACCEPTED" }
  if([string]$m.recipient_node_id -cne $NodeId){ throw "RECIPIENT_NODE_MISMATCH" }
  if([string]$m.sender_node_id -cne [string]$frame.sender_node_id -or [string]$m.session_id -cne [string]$frame.session_id){ throw "FRAME_BINDING_MISMATCH" }
  if($hasPlain){
    # A session bound to VTP v2 never accepts a plaintext payload (no silent downgrade), and neither
    # does a profile this receiver's own policy marks payload_encryption vtp2 (bound or not).
    if($null -ne (CV2-ReadBinding $RepoRoot ([string]$m.session_id) ([string]$m.sender_node_id) $NodeId)){ throw "VTP2_DOWNGRADE_REFUSED" }
    $rpPath = Join-Path $RepoRoot "policy\courier_product_policy_v1.json"
    if(Test-Path -LiteralPath $rpPath -PathType Leaf){
      $rp = CC-ReadJsonFile $rpPath
      $pn = [string]$m.policy_profile
      if((CC-HasProp $rp "profiles") -and (CC-HasProp $rp.profiles $pn)){
        $rprof = $rp.profiles.$pn
        if((CC-HasProp $rprof "payload_encryption") -and [string]$rprof.payload_encryption -ceq "vtp2"){ throw "VTP2_DOWNGRADE_REFUSED" }
      }
    }
    try { $payloadBytes = [Convert]::FromBase64String([string]$envelope.payload_b64) } catch { throw "PAYLOAD_NOT_BASE64" }
  } else {
    $binding = CV2-ReadBinding $RepoRoot ([string]$m.session_id) ([string]$m.sender_node_id) $NodeId
    if($null -eq $binding){ throw "VTP2_SESSION_NOT_BOUND" }
    $sealedBytes = $null
    try { $sealedBytes = [Convert]::FromBase64String([string]$envelope.payload_vtp2_b64) } catch { throw "PAYLOAD_NOT_BASE64" }
    $sealedObj = CC-ParseJson ((CC-Utf8NoBom).GetString($sealedBytes))
    if([string]$sealedObj.session_id -cne [string]$binding.vtp2_session_id -or [string]$sealedObj.recipient_device_id -cne [string]$binding.recipient_device_id -or [string]$sealedObj.sender_device_id -cne [string]$binding.sender_device_id){ throw "VTP2_SESSION_MISMATCH" }
    $tmpDir = Join-Path $RepoRoot "runtime\tmp"; CC-EnsureDir $tmpDir
    $sealedTmp = Join-Path $tmpDir ("vtp2-in-" + [guid]::NewGuid().ToString("N") + ".json")
    $plainTmp = Join-Path $tmpDir ("vtp2-out-" + [guid]::NewGuid().ToString("N") + ".bin")
    try {
      [System.IO.File]::WriteAllBytes($sealedTmp,$sealedBytes)
      $dec = CV2-Invoke @("decrypt","--state",(CV2-StatePath $RepoRoot $NodeId),"--in",$sealedTmp,"--out",$plainTmp)
      if($dec.Code -ne 0){ throw ("VTP2_DECRYPT_FAILED:" + (CV2-Token $dec.Text ("EXIT_" + $dec.Code))) }
      $payloadBytes = [System.IO.File]::ReadAllBytes($plainTmp)
    } finally {
      foreach($t in @($sealedTmp,$plainTmp)){ if(Test-Path -LiteralPath $t){ Remove-Item -LiteralPath $t -Force } }
    }
    Write-Host ("COURIER_RECEIVE_DECRYPTED: vtp2 session=" + [string]$binding.vtp2_session_id)
  }
  $actual = CC-Sha256Bytes $payloadBytes
  if($actual -cne [string]$m.payload_sha256 -or $actual -cne $payloadSha){ throw "PAYLOAD_HASH_MISMATCH" }
  $pd = $envelope.policy_decision
  if([string]$pd.schema -cne "covenant_courier.policy_decision.v1" -or [string]$pd.message_id -cne $messageId){ throw "POLICY_DECISION_BINDING_MISMATCH" }
  if(@("allow","redact_notification") -cnotcontains [string]$pd.decision){ throw "POLICY_DECISION_NOT_DELIVERABLE" }
  $n = $envelope.notification
  if([string]$n.schema -cne "covenant_courier.notification.v1" -or [string]$n.message_id -cne $messageId){ throw "NOTIFICATION_BINDING_MISMATCH" }

  # The sender's policy_decision is its claim, not this node's decision: re-decide with this node's own
  # policy (the profile the session names, else the message's) on the bytes actually received, and build
  # the notification from that profile. Covenant Gate is not re-consulted here (see SECURITY.md).
  $rpPath = Join-Path $RepoRoot "policy\courier_product_policy_v1.json"
  if(-not (Test-Path -LiteralPath $rpPath -PathType Leaf)){ throw "RECEIVER_POLICY_MISSING" }
  $rp = CC-ReadJsonFile $rpPath
  $sessPath = Join-Path $RepoRoot ("registry\sessions\" + [string]$m.session_id + ".json")
  $sess = $(if(Test-Path -LiteralPath $sessPath -PathType Leaf){ CC-ReadJsonFile $sessPath } else { $null })
  $pn = CCP-ResolveProfileName $m $sess
  if(-not ((CC-HasProp $rp "profiles") -and (CC-HasProp $rp.profiles $pn))){ throw "RECEIVER_POLICY_PROFILE_UNKNOWN" }
  $rprof = $rp.profiles.$pn
  $org = $(if(CC-HasProp $m "organization_id"){ [string]$m.organization_id } else { "" })
  $again = CCP-EvaluateLocal -RepoRoot $RepoRoot -Profile $rprof -PayloadBytes $payloadBytes -RecipientNodeId $NodeId -Fields @([string]$m.notification_preview,[string]$m.sender_identity,[string]$m.recipient_identity,$org)
  if(@("allow","redact_notification") -cnotcontains $again.Decision){ throw ("RECEIVER_POLICY_" + $again.Decision.ToUpperInvariant() + ":" + $again.Reason) }
  $rMode = $(if($again.Decision -ceq "redact_notification" -or [string]$pd.decision -ceq "redact_notification"){ "redacted" } else { [string]$rprof.notification_display_mode })
  $receiverNotification = CCP-BuildNotification $messageId ([string]$m.recipient_identity) $rMode ([string]$m.notification_preview)
} catch {
  $verdict = ([string]$_.Exception.Message -replace '[^A-Za-z0-9_:]','_')
}

if($null -ne $verdict){
  Write-Receipt $messageId $frameId $payloadSha "rejected" ("DELIVERY_ENVELOPE_INVALID:" + $verdict) "covenant_courier.product.receive_reject.v1"
  throw ("COURIER_RECEIVE_FAIL:DELIVERY_ENVELOPE_INVALID:" + $verdict)
}

$inboxParent = Join-Path $RepoRoot ("runtime\product_messages\inbox\" + $NodeId)
CC-EnsureDir $inboxParent
$inbox = Join-Path $inboxParent $messageId
# A delivered message is never overwritten: an existing inbox entry (same id, in any letter case on a
# case-insensitive file system) is a replay.
if(Test-Path -LiteralPath $inbox){
  Write-Receipt $messageId $frameId $payloadSha "rejected" "DELIVERY_ENVELOPE_INVALID:MESSAGE_ALREADY_IN_INBOX" "covenant_courier.product.receive_reject.v1"
  throw "COURIER_RECEIVE_FAIL:DELIVERY_ENVELOPE_INVALID:MESSAGE_ALREADY_IN_INBOX"
}
[void][IO.Directory]::CreateDirectory($inbox)
[IO.File]::WriteAllBytes((Join-Path $inbox "payload.bin"),$payloadBytes)
[void](CC-WriteDocument (Join-Path $inbox "message.json") (CC-ToOrderedTree $envelope.message))
[void](CC-WriteDocument (Join-Path $inbox "policy_decision.json") (CC-ToOrderedTree $envelope.policy_decision))
[void](CC-WriteDocument (Join-Path $inbox "notification.json") $receiverNotification)

Write-Receipt $messageId $frameId $payloadSha "accepted" "VTP_POLICY_ALLOW" "covenant_courier.product.accept.v1"

Write-Host ("COURIER_RECEIVE_MESSAGE_ID: " + $messageId)
Write-Host ("COURIER_RECEIVE_FRAME_ID: " + $frameId)
Write-Host ("COURIER_RECEIVE_ACCEPTED_PATH: " + $acceptedPath)
Write-Host ("COURIER_RECEIVE_INBOX: " + $inbox)
Write-Host ("COURIER_RECEIVE_PRODUCT_RECEIPT_OK: " + $ProductReceipt)
Write-Host "COVENANT_COURIER_RECEIVE_OK"
