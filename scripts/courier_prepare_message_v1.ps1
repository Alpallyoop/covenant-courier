param(
  [string]$RepoRoot = ".",
  [string]$From = "local/sender/demo",
  [string]$To = "local/recipient/demo",
  [string]$SenderNodeId = "node-alpha",
  [string]$RecipientNodeId = "node-beta",
  [string]$SessionId = "session-alpha-beta-001",
  [string]$PolicyProfile = "default",
  [string]$Preview = "Covenant Courier prepared message",
  [string]$PayloadText = "hello from covenant courier"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$OutRoot = Join-Path $RepoRoot "runtime\product_messages\prepared"
[void][IO.Directory]::CreateDirectory($OutRoot)

function Sha256Hex {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $sha.Dispose()
  }
}

$created = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
$messageId = "ccmsg-" + $created
$payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($PayloadText)
$payloadSha = Sha256Hex -Bytes $payloadBytes

$msg = [ordered]@{
  schema = "covenant_courier.message.v1"
  message_id = $messageId
  sender_identity = $From
  recipient_identity = $To
  sender_node_id = $SenderNodeId
  recipient_node_id = $RecipientNodeId
  organization_id = $null
  session_id = $SessionId
  policy_profile = $PolicyProfile
  notification_preview = $Preview
  payload_sha256 = $payloadSha
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$msgDir = Join-Path $OutRoot $messageId
[void][IO.Directory]::CreateDirectory($msgDir)

$messagePath = Join-Path $msgDir "message.json"
$payloadPath = Join-Path $msgDir "payload.txt"

[IO.File]::WriteAllText($messagePath, (($msg | ConvertTo-Json -Depth 20) + [string][char]10), [Text.UTF8Encoding]::new($false))
# The payload file holds exactly the bytes payload_sha256 covers.
[IO.File]::WriteAllBytes($payloadPath, $payloadBytes)

$check = Get-Content -LiteralPath $messagePath -Raw | ConvertFrom-Json
foreach($name in @("schema","message_id","sender_identity","recipient_identity","sender_node_id","recipient_node_id","session_id","policy_profile","notification_preview","payload_sha256","created_utc")){
  if($check.PSObject.Properties.Name -notcontains $name){
    throw ("COURIER_PREPARE_FAIL:MISSING_FIELD:" + $name)
  }
}

if([string]$check.schema -ne "covenant_courier.message.v1"){
  throw "COURIER_PREPARE_FAIL:BAD_SCHEMA"
}

if(([string]$check.payload_sha256) -notmatch "^[a-f0-9]{64}$"){
  throw "COURIER_PREPARE_FAIL:BAD_PAYLOAD_SHA256"
}

Write-Host ("COURIER_PREPARE_MESSAGE_OK: " + $messagePath)
Write-Host ("COURIER_PREPARE_PAYLOAD_OK: " + $payloadPath)
Write-Host "COVENANT_COURIER_PREPARE_OK"
