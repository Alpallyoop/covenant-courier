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

$RepoRoot = (Resolve-Path $RepoRoot).Path
$MaxPayloadBytes = 786432
$ReceiptLog = Join-Path $RepoRoot "proofs\receipts\covenant_courier_product.ndjson"
if([string]::IsNullOrWhiteSpace($PolicyPath)){ $PolicyPath = Join-Path $RepoRoot "policy\courier_product_policy_v1.json" }

$IdPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z'

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
  $chain = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_receipt_chain_v1.ps1") -RepoRoot $RepoRoot 2>&1
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
    CC-RequireExactProps $message @("schema","message_id","sender_identity","recipient_identity","sender_node_id","recipient_node_id","session_id","policy_profile","notification_preview","payload_sha256","created_utc") @("organization_id") "MESSAGE"
    if([string]$message.schema -cne "covenant_courier.message.v1"){ throw "MESSAGE:BAD_SCHEMA" }
    foreach($f in @("message_id","sender_node_id","recipient_node_id","session_id","policy_profile")){
      if(([string]$message.$f) -cnotmatch $IdPattern -or ([string]$message.$f).Contains("..")){ throw ("MESSAGE:BAD_" + $f.ToUpperInvariant()) }
    }
    foreach($f in @("sender_identity","recipient_identity")){ if([string]::IsNullOrWhiteSpace([string]$message.$f)){ throw ("MESSAGE:EMPTY_" + $f.ToUpperInvariant()) } }
    if($null -eq $message.notification_preview -or $message.notification_preview -isnot [string]){ throw "MESSAGE:BAD_NOTIFICATION_PREVIEW" }
    if([string]::IsNullOrWhiteSpace((CC-StringField $message "created_utc"))){ throw "MESSAGE:EMPTY_CREATED_UTC" }
    if([string]$message.payload_sha256 -cnotmatch '^[a-f0-9]{64}\z'){ throw "MESSAGE:BAD_PAYLOAD_SHA256" }
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

[System.IO.File]::Copy($MessagePath,(Join-Path $OutDir "message.json"),$true)
Write-Host ("COVENANT_COURIER_DELIVER_MESSAGE_ID: " + $messageId)

# ---------------------------------------------------------------- 2. policy
$profileName = [string]$message.policy_profile
$profile = $null
$policyHash = $null
try {
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
  CC-RequireExactProps $profile @("allowed_recipient_nodes","max_payload_bytes","require_utf8_payload","restricted_dictionary","restricted_action","notification_display_mode","covenant_gate") @("covenant_gate_signer") "POLICY_PROFILE"
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
    if([string]$session.status -cne "open"){ Decide "reject" "SESSION_NOT_OPEN" }
    elseif([string]$session.sender_node_id -cne [string]$message.sender_node_id -or [string]$session.recipient_node_id -cne [string]$message.recipient_node_id){ Decide "reject" "SESSION_BINDING_MISMATCH" }
    elseif([string]$senderNode.status -cne "active" -or [string]$recipientNode.status -cne "active"){ Decide "reject" "NODE_INACTIVE" }
    elseif([string]::IsNullOrWhiteSpace([string]$senderNode.principal) -or [string]::IsNullOrWhiteSpace([string]$recipientNode.principal)){ Decide "reject" "NODE_PRINCIPAL_MISSING" }
    elseif($payloadTooLarge -or $payloadBytes.Length -gt [int64]$profile.max_payload_bytes){ Decide "reject" "PAYLOAD_TOO_LARGE" }
    else {
      try { $text = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($payloadBytes) } catch { $text = $null }
      if($null -eq $text -and [bool]$profile.require_utf8_payload){ Decide "reject" "PAYLOAD_NOT_UTF8" }
      else {
        # Restricted terms (whole words, case-insensitive) in the payload text and the preview.
        $hits = New-Object System.Collections.Generic.List[string]
        if($null -ne $profile.restricted_dictionary){
          $dictPath = Join-Path $RepoRoot ([string]$profile.restricted_dictionary)
          $dict = CC-ReadJsonFile $dictPath
          foreach($e in @($dict.entries)){
            if([string]$e.sensitivity -ne "controlled"){ continue }
            foreach($form in @($e.surface_forms)){
              $rx = '(?i)(?<![\p{L}\p{N}])' + [regex]::Escape([string]$form) + '(?![\p{L}\p{N}])'
              if((($null -ne $text) -and [regex]::IsMatch($text,$rx)) -or [regex]::IsMatch([string]$message.notification_preview,$rx)){ $hits.Add([string]$e.token); break }
            }
          }
        }
        if($hits.Count -gt 0){
          switch([string]$profile.restricted_action){
            "reject" { Decide "reject" "RESTRICTED_TERM" }
            "quarantine" { Decide "quarantine" "RESTRICTED_TERM" }
            "require_approval" { Decide "require_approval" "RESTRICTED_TERM" }
            "redact_notification" { Decide "redact_notification" "RESTRICTED_TERM_NOTIFICATION_REDACTED" }
            default { Decide "reject" "POLICY_PROFILE_BAD_RESTRICTED_ACTION" }
          }
        }
        # Covenant Gate (only when the profile asks; never on an already-refused delivery).
        $gateMode = [string]$profile.covenant_gate
        if(@("allow","redact_notification") -contains $decision -and $gateMode -ne "off"){
          $signer = $(if(CC-HasProp $profile "covenant_gate_signer"){ [string]$profile.covenant_gate_signer } else { "" })
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

$decisionDoc = [ordered]@{
  schema = "covenant_courier.policy_decision.v1"
  decision_id = ("ccdec-" + (CC-Sha256Text ($messageId + "|" + $actualPayloadSha + "|" + $policyHash + "|" + $decision + "|" + $reason)).Substring(0,32))
  message_id = $messageId
  decision = $decision
  reason_code = $reason
  policy_profile = $profileName
  decided_utc = (CC-UtcNow)
}
$preview = switch($displayMode){
  "full_safe" { [string]$message.notification_preview }
  "redacted" { "[redacted]" }
  "generic" { "New secure message" }
  default { "" }
}
$notification = [ordered]@{
  schema = "covenant_courier.notification.v1"
  message_id = $messageId
  recipient_identity = [string]$message.recipient_identity
  display_mode = $displayMode
  preview = $preview
  created_utc = (CC-UtcNow)
}
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
  [System.IO.File]::Copy($PayloadPath,(Join-Path $q "payload.bin"),$true)
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
    payload_b64 = [Convert]::ToBase64String($payloadBytes)
  }
  $deliveryPath = Join-Path $OutDir "delivery.json"
  [void](CC-WriteDocument $deliveryPath $envelope)

  $senderPrincipal = [string]$senderNode.principal
  $recipientPrincipal = [string]$recipientNode.principal
  $safe = ($senderPrincipal -replace '[^A-Za-z0-9._-]','_')
  if(-not (Test-Path -LiteralPath (Join-Path $RepoRoot ("proofs\keys\courier_" + $safe + "_ed25519")) -PathType Leaf)){ throw ("SIGNER_KEY_MISSING:" + $senderPrincipal) }

  $sign = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_sign_message_v1.ps1") -RepoRoot $RepoRoot -MessagePath $deliveryPath -SignerIdentity $senderPrincipal -Namespace "courier/message" 2>&1
  if($LASTEXITCODE -ne 0){ Write-Host ($sign | Out-String).Trim(); throw "SIGN_FAILED" }

  $drop = Join-Path $RepoRoot ("runtime\nodes\" + [string]$message.recipient_node_id + "\inbox\drop")
  $send = & (CC-HostExe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "courier_transport_send_v1.ps1") `
    -RepoRoot $RepoRoot -MessagePath $deliveryPath -SenderIdentity $senderPrincipal -RecipientIdentity $recipientPrincipal `
    -SenderNodeId ([string]$message.sender_node_id) -RecipientNodeId ([string]$message.recipient_node_id) -NetworkId ([string]$session.network_id) `
    -SessionId ([string]$message.session_id) -SenderRole ([string]$session.session_role) -DropRoot $drop 2>&1
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
