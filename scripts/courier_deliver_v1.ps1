param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$MessagePath,
  [Parameter(Mandatory=$true)][string]$PayloadPath,
  [string]$OutDir,
  [string]$PolicyPath,
  [string]$CovenantGateRoot = $env:COVENANT_GATE_ROOT,
  [string]$CovenantGateDecisionPath
)

# Covenant Courier product delivery (v1): no delivery without policy, receipts and traceability.
#
#   1. validate the covenant_courier.message.v1 and recompute the payload hash
#   2. evaluate the delivery policy (policy/courier_product_policy_v1.json, the message's profile)
#      and, when the profile asks for it, Covenant Gate
#   3. write covenant_courier.policy_decision.v1 and covenant_courier.notification.v1
#   4. allowed: sign a covenant_courier.delivery.v1 envelope and send it as a VTP transport frame
#      refused: keep it (quarantine) or drop it (reject); nothing is sent
#   5. write covenant_courier.product_receipt.v1 for every outcome, append it to the product
#      receipt log and extend the append-only receipt chain
#
# Outputs in -OutDir: message.json, policy_decision.json, notification.json, product_receipt.json
# (+ delivery.json and delivery.json.sig when sent). product_receipt.json holds exactly the receipt
# line, so its SHA-256 equals the chain's receipt_sha256: that is the hash a consumer carries.
# Exit codes: 0 sent; 42 refused by policy (rejected or quarantined); 1 failed.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_lib_covenant_courier_product_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_courier_covenant_gate_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_courier_vtp2_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_courier_policy_eval_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$MaxPayloadBytes = 786432
$ReceiptLog = Join-Path $RepoRoot "proofs\receipts\covenant_courier_product.ndjson"
if([string]::IsNullOrWhiteSpace($PolicyPath)){ $PolicyPath = Join-Path $RepoRoot "policy\courier_product_policy_v1.json" }

# IDs become folder names: no trailing dot or space (Windows drops them, so "abc." would be "abc"),
# no reserved device names. Folders are compared case-insensitively where the file system does.
$IdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[A-Za-z0-9_-]\z|^[A-Za-z0-9]\z'
function Test-ReservedName([string]$Id){ return ($Id -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?\z') }

function Write-ProductReceipt([string]$MessageId,[string]$FrameId,[string]$PayloadSha,[string]$Decision,$ReasonCode,[string]$EventType){
  $receipt = [ordered]@{
    schema = "covenant_courier.product_receipt.v1"
    receipt_id = ("ccreceipt-" + (CC-UtcStampId) + "-" + ([guid]::NewGuid().ToString("N").Substring(0,8)))
    message_id = $MessageId
    event_type = $EventType
    time_utc = (CC-UtcNow)
    frame_id = $FrameId
    payload_sha256 = $PayloadSha
    decision = $Decision
    reason_code = $ReasonCode
  }
  $line = CC-ToJson $receipt
  CC-WriteTextFile (Join-Path $script:Out "product_receipt.json") $line
  CC-AppendLine $ReceiptLog $line
  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $chain = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") -RepoRoot $RepoRoot 2>&1; $ErrorActionPreference = $eapPrev
  if($LASTEXITCODE -ne 0){ Write-Host ($chain | Out-String).Trim(); Write-Host "COVENANT_COURIER_DELIVER_RECEIPT_CHAIN_FAILED"; Write-Host "COVENANT_COURIER_DELIVER_FAILED"; exit 1 }
  $sha = CC-Sha256Text $line
  Write-Host ("COVENANT_COURIER_DELIVER_RECEIPT: " + (Join-Path $script:Out "product_receipt.json"))
  Write-Host ("COVENANT_COURIER_DELIVER_RECEIPT_SHA256: " + $sha)
  return $sha
}

function Finish([string]$Decision,[string]$Reason,[int]$Code){
  Write-Host ("COVENANT_COURIER_DELIVER_DECISION: " + $Decision)
  if($Reason){ Write-Host ("COVENANT_COURIER_DELIVER_REASON: " + $Reason) }
  if($Code -eq 0){ Write-Host "COVENANT_COURIER_DELIVER_OK" }
  elseif($Code -eq 42){ Write-Host "COVENANT_COURIER_DELIVER_REFUSED" }
  else { Write-Host "COVENANT_COURIER_DELIVER_FAILED" }
  exit $Code
}

# ---------------------------------------------------------------- 1. input
# Every outcome, including an unusable input, ends with a product receipt. Until the message is
# known, receipts for early failures go to runtime/product_messages/delivered/failed-<stamp>/.
$script:Out = $(if([string]::IsNullOrWhiteSpace($OutDir)){ Join-Path $RepoRoot ("runtime\product_messages\delivered\failed-" + (CC-UtcStampId)) } else { $OutDir })
function Fail-Early([string]$Token,[string]$PayloadSha){
  CC-EnsureDir $script:Out
  [void](Write-ProductReceipt "unknown-message" "no-frame" $PayloadSha "failed" ("COURIER_DELIVER_FAILED:" + $Token) "covenant_courier.product.reject.v1")
  Finish "failed" ("COURIER_DELIVER_FAILED:" + $Token) 1
}
$emptySha = CC-Sha256Bytes ([byte[]]@())
if([string]::IsNullOrWhiteSpace($PayloadPath) -or -not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)){ Fail-Early "MISSING_PAYLOAD" $emptySha }
$payloadTooLarge = ((Get-Item -LiteralPath $PayloadPath).Length -gt $MaxPayloadBytes)
$payloadBytes = [byte[]]@()
if($payloadTooLarge){ $actualPayloadSha = CC-Sha256File $PayloadPath }
else {
  # Hash exactly the bytes that will be sent (one read, no re-read).
  $payloadBytes = [System.IO.File]::ReadAllBytes($PayloadPath)
  $actualPayloadSha = CC-Sha256Bytes $payloadBytes
}

$message = $null
$inputError = $null
try { $message = CC-ReadJsonFile $MessagePath } catch { $inputError = "MESSAGE_INVALID_JSON" }
if($null -eq $inputError){
  try {
    CC-RequireExactProps $message @("schema","message_id","sender_identity","recipient_identity","sender_node_id","recipient_node_id","session_id","policy_profile","notification_preview","payload_sha256","created_utc") @("organization_id","origin") "MESSAGE"
    if([string]$message.schema -cne "covenant_courier.message.v1"){ throw "MESSAGE:BAD_SCHEMA" }
    foreach($f in @("message_id","sender_node_id","recipient_node_id","session_id","policy_profile")){
      if(([string]$message.$f) -cnotmatch $IdPattern -or ([string]$message.$f).Contains("..") -or (Test-ReservedName ([string]$message.$f))){ throw ("MESSAGE:BAD_" + $f.ToUpperInvariant()) }
    }
    foreach($f in @("sender_identity","recipient_identity")){ if([string]::IsNullOrWhiteSpace([string]$message.$f)){ throw ("MESSAGE:EMPTY_" + $f.ToUpperInvariant()) } }
    if($null -eq $message.notification_preview -or $message.notification_preview -isnot [string]){ throw "MESSAGE:BAD_NOTIFICATION_PREVIEW" }
    if([string]::IsNullOrWhiteSpace((CC-StringField $message "created_utc"))){ throw "MESSAGE:EMPTY_CREATED_UTC" }
    if([string]$message.payload_sha256 -cnotmatch '^[a-f0-9]{64}\z'){ throw "MESSAGE:BAD_PAYLOAD_SHA256" }
    if(CC-HasProp $message "origin"){ if(@("human","ai","service") -cnotcontains [string]$message.origin){ throw "MESSAGE:BAD_ORIGIN" } }
    if(CC-HasProp $message "organization_id"){ if($null -ne $message.organization_id -and $message.organization_id -isnot [string]){ throw "MESSAGE:BAD_ORGANIZATION_ID" } }
  } catch { $inputError = ([string]$_.Exception.Message -replace '[^A-Za-z0-9_:]','_') }
}

$messageId = $(if($null -eq $inputError){ [string]$message.message_id } else { "invalid-" + $actualPayloadSha.Substring(0,16) })
if([string]::IsNullOrWhiteSpace($OutDir)){ $OutDir = Join-Path $RepoRoot ("runtime\product_messages\delivered\" + $messageId) }
$script:Out = $OutDir
try { CC-EnsureDir $OutDir } catch { $script:Out = Join-Path $RepoRoot ("runtime\product_messages\delivered\failed-" + (CC-UtcStampId)); Fail-Early "OUTDIR_UNUSABLE" $actualPayloadSha }

if($null -ne $inputError){
  [void](Write-ProductReceipt $messageId "no-frame" $actualPayloadSha "rejected" ("MESSAGE_INVALID:" + $inputError) "covenant_courier.product.reject.v1")
  Finish "rejected" ("MESSAGE_INVALID:" + $inputError) 42
}

# The parsed message, not a re-read of the caller's file (what is kept is what was checked).
[void](CC-WriteDocument (Join-Path $OutDir "message.json") (CC-ToOrderedTree $message))
Write-Host ("COVENANT_COURIER_DELIVER_MESSAGE_ID: " + $messageId)

# ---------------------------------------------------------------- 2. policy
$profileName = [string]$message.policy_profile
$profile = $null
$policyHash = $null
try {
  # The policy is this installation's own: a file under <repo>\policy\, never one the caller brings.
  $policyDir = [IO.Path]::GetFullPath((Join-Path $RepoRoot "policy")).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  $cmp = $(if($env:OS -eq "Windows_NT"){ [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
  if(-not [IO.Path]::GetFullPath($PolicyPath).StartsWith($policyDir,$cmp)){ throw "POLICY_PATH_NOT_IN_REPOSITORY" }
  $policy = CC-ReadJsonFile $PolicyPath
  if([string]$policy.schema -cne "covenant_courier.product_policy.v1"){ throw "POLICY_BAD_SCHEMA" }
  $policyHash = CC-Sha256File $PolicyPath
  if(CC-HasProp $policy.profiles $profileName){ $profile = $policy.profiles.$profileName }
} catch {
  $tok = ([string]$_.Exception.Message -replace '[^A-Za-z0-9_:@.-]','_')
  [void](Write-ProductReceipt $messageId "no-frame" $actualPayloadSha "failed" ("COURIER_POLICY_FAILED:" + $tok) "covenant_courier.product.reject.v1")
  Finish "failed" ("COURIER_POLICY_FAILED:" + $tok) 1
}

$decision = "allow"
$reason = "POLICY_ALLOW"
$displayMode = "minimal"
$cg = $null
$text = $null

function Decide([string]$D,[string]$R){ $script:decision = $D; $script:reason = $R }

try {
if($null -eq $profile){
  Decide "reject" "POLICY_PROFILE_UNKNOWN"
} else {
  CC-RequireExactProps $profile @("allowed_recipient_nodes","max_payload_bytes","require_utf8_payload","restricted_dictionary","restricted_action","notification_display_mode","covenant_gate") @("covenant_gate_signer","payload_encryption") "POLICY_PROFILE"
  $encryption = $(if(CC-HasProp $profile "payload_encryption"){ [string]$profile.payload_encryption } else { "none" })
  if(@("none","vtp2") -cnotcontains $encryption){ throw "POLICY_PROFILE_BAD_PAYLOAD_ENCRYPTION" }
  $displayMode = [string]$profile.notification_display_mode
  if(@("minimal","generic","redacted","full_safe") -cnotcontains $displayMode){ throw "POLICY_PROFILE_BAD_DISPLAY_MODE" }
  if(@("off","advisory","required") -cnotcontains [string]$profile.covenant_gate){ throw "POLICY_PROFILE_BAD_COVENANT_GATE" }
  if(@("reject","quarantine","require_approval","redact_notification") -cnotcontains [string]$profile.restricted_action){ throw "POLICY_PROFILE_BAD_RESTRICTED_ACTION" }
  $sessionPath = Join-Path $RepoRoot ("registry\sessions\" + [string]$message.session_id + ".json")
  $senderNodePath = Join-Path $RepoRoot ("registry\nodes\" + [string]$message.sender_node_id + ".json")
  $recipientNodePath = Join-Path $RepoRoot ("registry\nodes\" + [string]$message.recipient_node_id + ".json")

  if(@($profile.allowed_recipient_nodes) -cnotcontains [string]$message.recipient_node_id){ Decide "reject" "RECIPIENT_NODE_NOT_ALLOWED" }
  elseif($actualPayloadSha -cne [string]$message.payload_sha256){ Decide "reject" "PAYLOAD_HASH_MISMATCH" }
  elseif(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ Decide "reject" "SESSION_UNKNOWN" }
  elseif(-not (Test-Path -LiteralPath $senderNodePath -PathType Leaf) -or -not (Test-Path -LiteralPath $recipientNodePath -PathType Leaf)){ Decide "reject" "NODE_UNKNOWN" }
  else {
    $session = CC-ReadJsonFile $sessionPath
    $senderNode = CC-ReadJsonFile $senderNodePath
    $recipientNode = CC-ReadJsonFile $recipientNodePath
    $sessionProfile = $(if((CC-HasProp $session "session_policy_ref") -and -not [string]::IsNullOrWhiteSpace([string]$session.session_policy_ref)){ [string]$session.session_policy_ref } else { $null })
    if([string]$session.status -cne "open"){ Decide "reject" "SESSION_NOT_OPEN" }
    elseif([string]$session.sender_node_id -cne [string]$message.sender_node_id -or [string]$session.recipient_node_id -cne [string]$message.recipient_node_id){ Decide "reject" "SESSION_BINDING_MISMATCH" }
    elseif($null -ne $sessionProfile -and $sessionProfile -cne $profileName){ Decide "reject" "POLICY_PROFILE_NOT_SESSION_PROFILE" }
    elseif([string]$senderNode.status -cne "active" -or [string]$recipientNode.status -cne "active"){ Decide "reject" "NODE_INACTIVE" }
    elseif([string]::IsNullOrWhiteSpace([string]$senderNode.principal) -or [string]::IsNullOrWhiteSpace([string]$recipientNode.principal)){ Decide "reject" "NODE_PRINCIPAL_MISSING" }
    else {
      # Recipient allow-list, size, text and restricted terms (also in the preview and the identities
      # the recipient sees): the same evaluation the receiver repeats with its own policy.
      $orgField = $(if(CC-HasProp $message "organization_id"){ [string]$message.organization_id } else { "" })
      $local = CCP-EvaluateLocal -RepoRoot $RepoRoot -Profile $profile -PayloadBytes $payloadBytes -RecipientNodeId ([string]$message.recipient_node_id) -Fields @([string]$message.notification_preview,[string]$message.sender_identity,[string]$message.recipient_identity,$orgField) -PayloadTooLarge:$payloadTooLarge
      Decide $local.Decision $local.Reason
      if($true){
        # Covenant Gate (only when the profile asks; never on an already-refused delivery).
        $gateMode = [string]$profile.covenant_gate
        if(@("allow","redact_notification") -contains $decision -and $gateMode -ne "off"){
          $signer = $(if(CC-HasProp $profile "covenant_gate_signer"){ [string]$profile.covenant_gate_signer } else { "" })
          # The gate's decision must come from someone other than the sender: a node principal never
          # signs its own gate decision.
          if(-not [string]::IsNullOrWhiteSpace($signer) -and ($signer -ceq [string]$senderNode.principal -or $signer -ceq [string]$recipientNode.principal)){ throw "POLICY_PROFILE_GATE_SIGNER_IS_A_NODE" }
          $cg = Invoke-CourierCovenantGate -RepoRoot $RepoRoot -Message $message -PayloadSha256 $actualPayloadSha -SenderPrincipal ([string]$senderNode.principal) -RecipientPrincipal ([string]$recipientNode.principal) -WorkDir (Join-Path $OutDir "covenant_gate") -CovenantGateRoot $CovenantGateRoot -DecisionDocumentPath $CovenantGateDecisionPath -DocumentSigner $signer
          Write-Host ("COVENANT_COURIER_DELIVER_COVENANT_GATE: mode=" + $cg.Mode + " outcome=" + $cg.Outcome + " decision=" + $cg.Decision + " token=" + $cg.Token)
          if($cg.Consulted -and $cg.Decision -eq "deny"){ Decide "reject" ("COVENANT_GATE_DENY:" + ((@($cg.ReasonCodes) -join ",") -replace '[^A-Z0-9_,]','_')) }
          elseif(-not $cg.Consulted){
            if($cg.Outcome -eq "refused"){ Decide "reject" ("COVENANT_GATE_REFUSED:" + $cg.Token) }
            elseif($gateMode -eq "required"){ Decide "require_approval" ("COVENANT_GATE_REQUIRED:" + $cg.Token) }
            # advisory: only "unavailable" (gate not reachable) falls back to local policy; a gate that
            # was reached but failed is not silently ignored.
            elseif($cg.Outcome -ne "unavailable"){ Decide "require_approval" ("COVENANT_GATE_FAILED:" + $cg.Token) }
          }
        }
      }
    }
  }
}

} catch {
  $tok = ([string]$_.Exception.Message -replace '[^A-Za-z0-9_:@.-]','_')
  [void](Write-ProductReceipt $messageId "no-frame" $actualPayloadSha "failed" ("COURIER_POLICY_FAILED:" + $tok) "covenant_courier.product.reject.v1")
  Finish "failed" ("COURIER_POLICY_FAILED:" + $tok) 1
}

if($decision -eq "redact_notification"){ $displayMode = "redacted" }

# Payload encryption. A session bound to a VTP v2 session always carries the payload encrypted,
# whatever the profile (its receiver refuses plaintext). A profile that requires vtp2 sends nothing
# without a binding (the message waits in quarantine as require_stronger_session).
$vtp2Binding = $null
# The payload is base64-encoded inside the VTP v2 envelope and again in the delivery envelope; above
# this size the delivery envelope would exceed what a receiver reads (1,200,000 bytes).
$Vtp2MaxPayloadBytes = 600000
if(@("allow","redact_notification") -contains $decision -and $null -ne $profile){
  try { $vtp2Binding = CV2-ReadBinding $RepoRoot ([string]$message.session_id) ([string]$message.sender_node_id) ([string]$message.recipient_node_id) }
  catch { $vtp2Binding = $null; Decide "reject" ("VTP2_BINDING_INVALID:" + ([string]$_.Exception.Message -replace '[^A-Za-z0-9_:]','_')) }
  if($null -eq $vtp2Binding -and $encryption -eq "vtp2" -and @("allow","redact_notification") -contains $decision){ Decide "require_stronger_session" "VTP2_SESSION_NOT_BOUND" }
  if($null -ne $vtp2Binding -and $payloadBytes.Length -gt $Vtp2MaxPayloadBytes){ $vtp2Binding = $null; Decide "reject" "PAYLOAD_TOO_LARGE" }
}

$decisionDoc = [ordered]@{
  schema = "covenant_courier.policy_decision.v1"
  decision_id = ("ccdec-" + (CC-Sha256Text ($messageId + "|" + $actualPayloadSha + "|" + $policyHash + "|" + $decision + "|" + $reason)).Substring(0,32))
  message_id = $messageId
  decision = $decision
  reason_code = $reason
  policy_profile = $profileName
  decided_utc = (CC-UtcNow)
}
$notification = CCP-BuildNotification $messageId ([string]$message.recipient_identity) $displayMode ([string]$message.notification_preview)
[void](CC-WriteDocument (Join-Path $OutDir "policy_decision.json") $decisionDoc)
[void](CC-WriteDocument (Join-Path $OutDir "notification.json") $notification)
Write-Host ("COVENANT_COURIER_DELIVER_POLICY: " + $decision + ":" + $reason)

# ---------------------------------------------------------------- 3. outcome
if($decision -eq "reject"){
  [void](Write-ProductReceipt $messageId "no-frame" $actualPayloadSha "rejected" $reason "covenant_courier.product.reject.v1")
  Finish "rejected" $reason 42
}
if(@("quarantine","require_approval","require_stronger_session") -contains $decision){
  $q = Join-Path $RepoRoot ("runtime\product_messages\quarantine\" + $messageId)
  CC-EnsureDir $q
  foreach($n in @("message.json","policy_decision.json","notification.json")){ Copy-Item -LiteralPath (Join-Path $OutDir $n) -Destination (Join-Path $q $n) -Force }
  # The bytes that were evaluated (no re-read of the caller's file).
  [System.IO.File]::WriteAllBytes((Join-Path $q "payload.bin"),[byte[]]$payloadBytes)
  [void](Write-ProductReceipt $messageId "no-frame" $actualPayloadSha "quarantined" ($decision.ToUpperInvariant() + ":" + $reason) "covenant_courier.product.quarantine.v1")
  Finish "quarantined" $reason 42
}

# allow / redact_notification: sign and send the delivery envelope.
try {
  $envelope = [ordered]@{
    schema = "covenant_courier.delivery.v1"
    message = (CC-ToOrderedTree $message)
    policy_decision = $decisionDoc
    notification = $notification
  }
  # The sender's free-text preview travels only when the recipient is meant to see it (full_safe): a
  # redacted, generic or minimal notification must not leave it readable in the envelope.
  if($displayMode -cne "full_safe"){ $envelope.message["notification_preview"] = "" }
  if($null -ne $vtp2Binding){
    # The sender's free-text preview is not part of the encrypted payload: it is not carried at all
    # (the recipient sees the notification document, built from the profile's display mode).
    $envelope.message["notification_preview"] = ""
    # Encrypt exactly the bytes that were hashed and checked by policy (no re-read of the input).
    $tmpDir = Join-Path $RepoRoot "runtime\tmp"; CC-EnsureDir $tmpDir
    $plainTmp = Join-Path $tmpDir ("vtp2-plain-" + [guid]::NewGuid().ToString("N") + ".bin")
    $cipherOut = Join-Path $OutDir "payload.vtp2.json"
    try {
      [System.IO.File]::WriteAllBytes($plainTmp,[byte[]]$payloadBytes)
      $enc = CV2-Invoke @("encrypt","--state",(CV2-StatePath $RepoRoot ([string]$message.sender_node_id)),"--session",[string]$vtp2Binding.vtp2_session_id,"--in",$plainTmp,"--out",$cipherOut,"--content-type","application/octet-stream")
    } finally { if(Test-Path -LiteralPath $plainTmp){ Remove-Item -LiteralPath $plainTmp -Force } }
    if($enc.Code -ne 0){ Write-Host $enc.Text.Trim(); throw ("VTP2_ENCRYPT_FAILED:" + (CV2-Token $enc.Text ("EXIT_" + $enc.Code))) }
    $envelope["payload_vtp2_b64"] = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($cipherOut))
    Write-Host ("COVENANT_COURIER_DELIVER_ENCRYPTION: vtp2 session=" + [string]$vtp2Binding.vtp2_session_id)
  } else {
    $envelope["payload_b64"] = [Convert]::ToBase64String([byte[]]$payloadBytes)
  }
  $deliveryPath = Join-Path $OutDir "delivery.json"
  [void](CC-WriteDocument $deliveryPath $envelope)

  $senderPrincipal = [string]$senderNode.principal
  $recipientPrincipal = [string]$recipientNode.principal
  $safe = ($senderPrincipal -replace '[^A-Za-z0-9._-]','_')
  if(-not (Test-Path -LiteralPath (Join-Path $RepoRoot ("proofs\keys\courier_" + $safe + "_ed25519")) -PathType Leaf)){ throw ("SIGNER_KEY_MISSING:" + $senderPrincipal) }

  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $sign = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_sign_message_v1.ps1") -RepoRoot $RepoRoot -MessagePath $deliveryPath -SignerIdentity $senderPrincipal -Namespace "courier/message" 2>&1; $ErrorActionPreference = $eapPrev
  if($LASTEXITCODE -ne 0){ Write-Host ($sign | Out-String).Trim(); throw "SIGN_FAILED" }

  $drop = Join-Path $RepoRoot ("runtime\nodes\" + [string]$message.recipient_node_id + "\inbox\drop")
  $eapPrev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  $send = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_transport_send_v1.ps1") `
    -RepoRoot $RepoRoot -MessagePath $deliveryPath -SenderIdentity $senderPrincipal -RecipientIdentity $recipientPrincipal `
    -SenderNodeId ([string]$message.sender_node_id) -RecipientNodeId ([string]$message.recipient_node_id) -NetworkId ([string]$session.network_id) `
    -SessionId ([string]$message.session_id) -SenderRole ([string]$session.session_role) -DropRoot $drop 2>&1
  $ErrorActionPreference = $eapPrev
  $sendText = ($send | Out-String)
  if($LASTEXITCODE -ne 0){ Write-Host $sendText.Trim(); throw "TRANSPORT_SEND_FAILED" }
  $frameId = $null
  foreach($l in ($sendText -split "`n")){ if($l -match 'COURIER_TRANSPORT_SEND_OK:\s+(.+)$'){ $frameId = Split-Path -Leaf $Matches[1].Trim() } }
  if([string]::IsNullOrWhiteSpace($frameId)){ throw "FRAME_ID_NOT_REPORTED" }
} catch {
  $tok = ([string]$_.Exception.Message -replace '[^A-Za-z0-9_:@.-]','_')
  [void](Write-ProductReceipt $messageId "no-frame" $actualPayloadSha "failed" ("COURIER_DELIVER_FAILED:" + $tok) "covenant_courier.product.send.v1")
  Finish "failed" ("COURIER_DELIVER_FAILED:" + $tok) 1
}

Write-Host ("COVENANT_COURIER_DELIVER_FRAME_ID: " + $frameId)
[void](Write-ProductReceipt $messageId $frameId $actualPayloadSha "sent" $reason "covenant_courier.product.send.v1")
Finish "sent" $reason 0
