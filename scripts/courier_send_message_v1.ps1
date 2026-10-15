param(
  [string]$RepoRoot = ".",
  [string]$From = "local/sender/demo",
  [string]$RecipientNodeId = "node-beta",
  [string]$RecipientIdentity = "local/recipient/demo",
  [string]$PayloadText = "hello from covenant courier",
  [string]$PolicyProfile = "default"
)

# Product send: prepare a covenant_courier.message.v1 and deliver it through the governed
# delivery path (policy -> signed delivery envelope -> VTP frame -> product receipt).
# The frame carries this message and its payload; nothing else is sent in its name.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Scripts = Join-Path $RepoRoot "scripts"
$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

function Run-Child([string]$Script,[string[]]$ChildArgs,[int[]]$OkCodes = @(0)){
  $out = & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ChildArgs 2>&1
  $code = $LASTEXITCODE
  $text = ($out | Out-String)
  Write-Host $text.Trim()
  if($OkCodes -notcontains $code){ throw ("COURIER_SEND_FAIL:CHILD_EXIT:" + $code + ":" + (Split-Path -Leaf $Script)) }
  return @{ Text = $text; Code = $code }
}

# Local demo prerequisites: registered nodes and network, an open session, and the local signer.
$sessionId = "session-alpha-beta-001"
Run-Child (Join-Path $Scripts "courier_seed_demo_registry_v1.ps1") @("-RepoRoot",$RepoRoot,"-RecipientNodeId",$RecipientNodeId) | Out-Null
Run-Child (Join-Path $Scripts "courier_open_session_v1.ps1") @("-RepoRoot",$RepoRoot,"-SessionId",$sessionId,"-SenderNodeId","node-alpha","-RecipientNodeId",$RecipientNodeId,"-NetworkId","courier-internal-net-v1","-SessionRole","message-delivery") | Out-Null
Run-Child (Join-Path $Scripts "courier_bootstrap_local_trust_v1.ps1") @("-RepoRoot",$RepoRoot) | Out-Null

$prep = Run-Child (Join-Path $Scripts "courier_prepare_message_v1.ps1") @("-RepoRoot",$RepoRoot,"-From",$From,"-To",$RecipientIdentity,"-RecipientNodeId",$RecipientNodeId,"-SessionId",$sessionId,"-PolicyProfile",$PolicyProfile,"-PayloadText",$PayloadText)
$messagePath = $null; $payloadPath = $null
foreach($line in ($prep.Text -split "`n")){
  if($line -match 'COURIER_PREPARE_MESSAGE_OK:\s+(.+)$'){ $messagePath = $Matches[1].Trim() }
  if($line -match 'COURIER_PREPARE_PAYLOAD_OK:\s+(.+)$'){ $payloadPath = $Matches[1].Trim() }
}
if([string]::IsNullOrWhiteSpace($messagePath) -or [string]::IsNullOrWhiteSpace($payloadPath)){ throw "COURIER_SEND_FAIL:PREPARE_OUTPUT_NOT_FOUND" }

$deliver = Run-Child (Join-Path $Scripts "courier_deliver_v1.ps1") @("-RepoRoot",$RepoRoot,"-MessagePath",$messagePath,"-PayloadPath",$payloadPath) @(0,42)
$frameId = $null; $messageId = $null; $receiptSha = $null
foreach($line in ($deliver.Text -split "`n")){
  if($line -match 'COVENANT_COURIER_DELIVER_FRAME_ID:\s+(.+)$'){ $frameId = $Matches[1].Trim() }
  if($line -match 'COVENANT_COURIER_DELIVER_MESSAGE_ID:\s+(.+)$'){ $messageId = $Matches[1].Trim() }
  if($line -match 'COVENANT_COURIER_DELIVER_RECEIPT_SHA256:\s+(.+)$'){ $receiptSha = $Matches[1].Trim() }
}
if($deliver.Code -ne 0){ throw ("COURIER_SEND_FAIL:DELIVERY_REFUSED:" + $messageId) }
if([string]::IsNullOrWhiteSpace($frameId)){ throw "COURIER_SEND_FAIL:FRAME_ID_NOT_FOUND" }

$message = Get-Content -LiteralPath $messagePath -Raw | ConvertFrom-Json
Write-Host ("COURIER_SEND_MESSAGE_ID: " + $messageId)
Write-Host ("COURIER_SEND_FRAME_ID: " + $frameId)
Write-Host ("COURIER_SEND_PAYLOAD_SHA256: " + [string]$message.payload_sha256)
Write-Host ("COURIER_SEND_PRODUCT_RECEIPT_SHA256: " + $receiptSha)
Write-Host ("COURIER_SEND_PRODUCT_RECEIPT_OK: " + (Join-Path $RepoRoot "proofs\receipts\covenant_courier_product.ndjson"))
Write-Host "COVENANT_COURIER_SEND_OK"
