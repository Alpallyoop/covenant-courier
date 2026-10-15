param(
  [string]$RepoRoot = ".",
  [string]$NodeId = "node-beta",
  [int]$Port = 47732,
  [int]$TimeoutMs = 10000,
  [string]$PacketPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "vtp_wire_key_envelope_v1.ps1")
. (Join-Path $PSScriptRoot "_lib_vtp_wire_session_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path
$PolicyGate = Join-Path $RepoRoot "scripts\vtp_policy_gate_v1.ps1"
$ReplayGuard = Join-Path $RepoRoot "scripts\vtp_replay_guard_check_v1.ps1"
$MaxPacketBytes = 1048576
$Runtime = Join-Path $RepoRoot ("runtime\wire_ingest\nodes\" + $NodeId)
$Drop = Join-Path $Runtime "drop"
$Accepted = Join-Path $Runtime "accepted"
$Rejected = Join-Path $Runtime "rejected"
$Receipts = Join-Path $RepoRoot "proofs\receipts"
$ReceiptPath = Join-Path $Receipts "vtp_udp_wire_ingest.ndjson"
$enc = [Text.UTF8Encoding]::new($false)

foreach($dir in @($Runtime,$Drop,$Accepted,$Rejected,$Receipts)){
  if(-not (Test-Path -LiteralPath $dir)){ [void][IO.Directory]::CreateDirectory($dir) }
}
if(-not (Test-Path -LiteralPath $PolicyGate -PathType Leaf)){ throw "VTP_UDP_WIRE_INGEST_FAIL:MISSING_POLICY_GATE" }
if(-not (Test-Path -LiteralPath $ReplayGuard -PathType Leaf)){ throw "VTP_UDP_WIRE_INGEST_FAIL:MISSING_REPLAY_GUARD" }

function Sha256Hex([byte[]]$Bytes){
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($Bytes)
    return ([BitConverter]::ToString($hash).Replace("-","").ToLowerInvariant())
  } finally {
    $sha.Dispose()
  }
}

function Derive-Key([string]$Purpose){
  return Get-VtpWireKeyBytes -RepoRoot $RepoRoot -RecipientNodeId $NodeId -Purpose $Purpose -SessionId $SessionId -SenderNodeId $SenderNodeId
}

function Write-Receipt([string]$FrameId,[string]$Decision,[string]$Reason,[string]$PathValue,[string]$PayloadSha256){
  $obj = [ordered]@{}
  $obj.schema = "vtp.udp_wire_ingest.receipt.v1"
  $obj.time_utc = (Get-Date).ToUniversalTime().ToString("o")
  $obj.node_id = $NodeId
  $obj.frame_id = $FrameId
  $obj.decision = $Decision
  $obj.reason = $Reason
  $obj.path = $PathValue
  $obj.payload_sha256 = $PayloadSha256
  $json = $obj | ConvertTo-Json -Depth 20 -Compress
  [IO.File]::AppendAllText($ReceiptPath, ($json + [string][char]10), $enc)
}

if(-not [string]::IsNullOrWhiteSpace($PacketPath)){
  if(-not (Test-Path -LiteralPath $PacketPath -PathType Leaf)){
    throw "VTP_UDP_WIRE_INGEST_FAIL:MISSING_PACKET_PATH"
  }
  if((Get-Item -LiteralPath $PacketPath).Length -gt $MaxPacketBytes){ throw "VTP_UDP_WIRE_INGEST_FAIL:PACKET_TOO_LARGE" }
  $bytes = [IO.File]::ReadAllBytes($PacketPath)
} else {
  $udp = New-Object Net.Sockets.UdpClient($Port)
  $udp.Client.ReceiveTimeout = $TimeoutMs
  $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
  try {
    $bytes = $udp.Receive([ref]$remote)
  } finally {
    $udp.Close()
  }
}
if($bytes.Length -gt $MaxPacketBytes){ throw "VTP_UDP_WIRE_INGEST_FAIL:PACKET_TOO_LARGE" }

$json = [Text.Encoding]::UTF8.GetString($bytes)
$packet = $json | ConvertFrom-Json
if([string]$packet.header.magic -ne "VTP1"){ throw "VTP_UDP_WIRE_INGEST_FAIL:BAD_MAGIC" }
if([int]$packet.header.version -ne 1){ throw "VTP_UDP_WIRE_INGEST_FAIL:BAD_VERSION" }
if([string]$packet.header.cipher_suite -ne "AES-CBC-256-HMAC-SHA256-DEV"){ throw "VTP_UDP_WIRE_INGEST_FAIL:UNSUPPORTED_CIPHER" }

$frameId = [string]$packet.header.frame_id
if($frameId -notmatch '^frame-[0-9]{8}T[0-9]{9}Z$'){
  throw "VTP_UDP_WIRE_INGEST_FAIL:BAD_FRAME_ID"
}
# Bindings come from the one open registered session for this node whose ID hash the header names.
$session = Find-VtpWireSessionByHash $RepoRoot ([string]$packet.header.session_id_hash) $NodeId "VTP_UDP_WIRE_INGEST_FAIL"
$SessionId = [string]$session.session_id
$SenderNodeId = [string]$session.sender_node_id
$expectedSenderHash = Sha256Hex ([Text.Encoding]::UTF8.GetBytes($SenderNodeId))
$expectedRecipientHash = Sha256Hex ([Text.Encoding]::UTF8.GetBytes($NodeId))
$expectedNetworkHash = Sha256Hex ([Text.Encoding]::UTF8.GetBytes([string]$session.network_id))
if([string]$packet.header.sender_node_id_hash -ne $expectedSenderHash){ throw "VTP_UDP_WIRE_INGEST_FAIL:SENDER_BINDING_MISMATCH" }
if([string]$packet.header.recipient_node_id_hash -ne $expectedRecipientHash){ throw "VTP_UDP_WIRE_INGEST_FAIL:RECIPIENT_BINDING_MISMATCH" }
if([string]$packet.header.network_id_hash -ne $expectedNetworkHash){ throw "VTP_UDP_WIRE_INGEST_FAIL:NETWORK_BINDING_MISMATCH" }

$headerJson = ($packet.header | ConvertTo-Json -Depth 20 -Compress)
$headerBytes = [Text.Encoding]::UTF8.GetBytes($headerJson)
$iv = [Convert]::FromBase64String([string]$packet.iv_b64)
$cipherBytes = [Convert]::FromBase64String([string]$packet.ciphertext_b64)
$tag = [Convert]::FromBase64String([string]$packet.tag_b64)
$macKey = Derive-Key "hmac"
$macInput = New-Object byte[] ($headerBytes.Length + $iv.Length + $cipherBytes.Length)
[Array]::Copy($headerBytes,0,$macInput,0,$headerBytes.Length)
[Array]::Copy($iv,0,$macInput,$headerBytes.Length,$iv.Length)
[Array]::Copy($cipherBytes,0,$macInput,$headerBytes.Length + $iv.Length,$cipherBytes.Length)
$hmac = New-Object Security.Cryptography.HMACSHA256(,$macKey)
try {
  $expectedTag = $hmac.ComputeHash($macInput)
} finally {
  $hmac.Dispose()
}
if((Sha256Hex $expectedTag) -ne (Sha256Hex $tag)){ throw "VTP_UDP_WIRE_INGEST_FAIL:BAD_AUTH_TAG" }

$aesKey = Derive-Key "aes"
$aes = [Security.Cryptography.Aes]::Create()
$aes.Mode = [Security.Cryptography.CipherMode]::CBC
$aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
$aes.KeySize = 256
$aes.Key = $aesKey
$aes.IV = $iv
$decryptor = $aes.CreateDecryptor()
try {
  $plainBytes = $decryptor.TransformFinalBlock($cipherBytes,0,$cipherBytes.Length)
} finally {
  $decryptor.Dispose()
  $aes.Dispose()
}

$plainHash = Sha256Hex $plainBytes
if($plainHash -ne [string]$packet.header.payload_sha256){ throw "VTP_UDP_WIRE_INGEST_FAIL:PAYLOAD_HASH_MISMATCH" }

# Replay: keyed on the authenticated MAC tag, so a re-sent captured packet is refused even
# though the frame written below carries a fresh created_utc.
$tagKey = Sha256Hex ([Convert]::FromBase64String([string]$packet.tag_b64))
$replayRoot = Join-Path $RepoRoot "proofs\state\wire_replay"
if(-not (Test-Path -LiteralPath $replayRoot)){ [void][IO.Directory]::CreateDirectory($replayRoot) }
$replayIndex = Join-Path $replayRoot ($NodeId + ".seen_tags.txt")
if((Test-Path -LiteralPath $replayIndex -PathType Leaf) -and (@(Get-Content -LiteralPath $replayIndex) -ccontains $tagKey)){
  throw "VTP_UDP_WIRE_INGEST_FAIL:REPLAY_DETECTED"
}
[IO.File]::AppendAllText($replayIndex, ($tagKey + [string][char]10), $enc)

$FrameDir = Join-Path $Drop $frameId
if(Test-Path -LiteralPath $FrameDir){ throw "VTP_UDP_WIRE_INGEST_FAIL:REPLAY_DETECTED" }
[void][IO.Directory]::CreateDirectory($FrameDir)
[void][IO.Directory]::CreateDirectory((Join-Path $FrameDir "payload"))

$frame = [ordered]@{}
$frame.schema = "courier.transport_frame.v2"
$frame.frame_id = $frameId
$frame.created_utc = (Get-Date).ToUniversalTime().ToString("o")
$frame.sender_identity = "wire@covenant"
$frame.recipient_identity = "courier-local@covenant"
$frame.sender_node_id = $SenderNodeId
$frame.recipient_node_id = $NodeId
$frame.network_id = [string]$session.network_id
$frame.session_id = $SessionId
$frame.sender_role = [string]$session.session_role
$frame.message_rel = "payload/message.tokenized.json"
$frame.signature_rel = "payload/wire.verified"
$frame.payload_sha256 = $plainHash

[IO.File]::WriteAllText((Join-Path $FrameDir "frame.json"), (($frame | ConvertTo-Json -Depth 20 -Compress) + [string][char]10), $enc)
[IO.File]::WriteAllText((Join-Path $FrameDir "payload\message.tokenized.json"), ([Text.Encoding]::UTF8.GetString($plainBytes) + [string][char]10), $enc)
[IO.File]::WriteAllText((Join-Path $FrameDir "payload\wire.verified"), "wire-auth-ok" + [string][char]10, $enc)
[IO.File]::WriteAllText((Join-Path $FrameDir "wire_packet.json"), ($json + [string][char]10), $enc)

# Replay state is checked before policy or acceptance. It is keyed from the
# authenticated frame representation and persists across listener restarts.
& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ReplayGuard -RepoRoot $RepoRoot -FrameDir $FrameDir | Out-Null
if($LASTEXITCODE -ne 0){ throw "VTP_UDP_WIRE_INGEST_FAIL:REPLAY_GUARD_FAILED" }

$policyOut = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PolicyGate -RepoRoot $RepoRoot -FrameDir $FrameDir 2>&1
$policyText = ($policyOut | Out-String).Trim()
$policyCode = $LASTEXITCODE

if($policyCode -eq 42){
  $dest = Join-Path $Rejected $frameId
  if(Test-Path -LiteralPath $dest){ $dest = $dest + "-dup-" + [guid]::NewGuid().ToString("N").Substring(0,8) }
  Move-Item -LiteralPath $FrameDir -Destination $dest -ErrorAction Stop
  [IO.File]::WriteAllText((Join-Path $dest "reject_reason.txt"), ($policyText + [string][char]10), $enc)
  Write-Receipt $frameId "rejected" $policyText $dest $plainHash
  Write-Host ("VTP_UDP_WIRE_INGEST_REJECT_OK: " + $dest)
  exit 0
}

if($policyCode -ne 0){
  throw ("VTP_UDP_WIRE_INGEST_FAIL:POLICY_GATE_EXIT_" + $policyCode + ":" + $policyText)
}

$dest = Join-Path $Accepted $frameId
if(Test-Path -LiteralPath $dest){ throw "VTP_UDP_WIRE_INGEST_FAIL:REPLAY_DETECTED" }
Move-Item -LiteralPath $FrameDir -Destination $dest -ErrorAction Stop
Write-Receipt $frameId "accepted" "VTP_POLICY_ALLOW" $dest $plainHash
Write-Host ("VTP_UDP_WIRE_INGEST_ACCEPT_OK: " + $dest)
Write-Host ("VTP_UDP_WIRE_INGEST_RECEIPT_OK: " + $ReceiptPath)
