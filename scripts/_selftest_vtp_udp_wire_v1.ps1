param(
  [string]$RepoRoot = ".",
  [string]$To = "node-beta",
  [int]$Port = 47731
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "vtp_wire_key_envelope_v1.ps1")

$RepoRoot = (Resolve-Path $RepoRoot).Path

# Precondition: the demo registry and an open demo session (the wire bindings come from it).
& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\courier_seed_demo_registry_v1.ps1") -RepoRoot $RepoRoot -RecipientNodeId $To | Out-Null
if($LASTEXITCODE -ne 0){ throw "VTP_WIRE_SELFTEST_FAIL:SEED_REGISTRY" }
& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\courier_open_session_v1.ps1") -RepoRoot $RepoRoot -SessionId "session-alpha-beta-001" -SenderNodeId "node-alpha" -RecipientNodeId $To -NetworkId "courier-internal-net-v1" -SessionRole "message-delivery" | Out-Null
if($LASTEXITCODE -ne 0){ throw "VTP_WIRE_SELFTEST_FAIL:OPEN_SESSION" }
$Scripts = Join-Path $RepoRoot "scripts"
$Runtime = Join-Path $RepoRoot "runtime\wire_udp"
$RunRoot = Join-Path $RepoRoot ("proofs\wire_udp_selftest\" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ"))
if(-not (Test-Path -LiteralPath $Runtime)){ [void][IO.Directory]::CreateDirectory($Runtime) }
[void][IO.Directory]::CreateDirectory($RunRoot)
$enc = [Text.UTF8Encoding]::new($false)
$send = Join-Path $Scripts "vtp_udp_wire_send_v1.ps1"
if(-not (Test-Path -LiteralPath $send -PathType Leaf)){ throw "VTP_UDP_WIRE_SELFTEST_FAIL:MISSING_SEND_SCRIPT" }

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
  return Get-VtpWireKeyBytes -RepoRoot $RepoRoot -RecipientNodeId $To -Purpose $Purpose
}

$udp = New-Object Net.Sockets.UdpClient($Port)
$remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
try {
  $async = $udp.BeginReceive($null,$null)
  & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $send -RepoRoot $RepoRoot -To $To -HostName "127.0.0.1" -Port $Port
  if($LASTEXITCODE -ne 0){ throw "VTP_UDP_WIRE_SELFTEST_FAIL:SEND_EXIT" }
  if(-not $async.AsyncWaitHandle.WaitOne(10000)){ throw "VTP_UDP_WIRE_SELFTEST_FAIL:RECEIVE_TIMEOUT" }
  $bytes = $udp.EndReceive($async,[ref]$remote)
} finally {
  $udp.Close()
}

$json = [Text.Encoding]::UTF8.GetString($bytes)
$packet = $json | ConvertFrom-Json
if([string]$packet.header.magic -ne "VTP1"){ throw "VTP_UDP_WIRE_SELFTEST_FAIL:BAD_MAGIC" }

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
if((Sha256Hex $expectedTag) -ne (Sha256Hex $tag)){ throw "VTP_UDP_WIRE_SELFTEST_FAIL:BAD_AUTH_TAG" }

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
if($plainHash -ne [string]$packet.header.payload_sha256){ throw "VTP_UDP_WIRE_SELFTEST_FAIL:PAYLOAD_HASH_MISMATCH" }

$frameId = [string]$packet.header.frame_id
$packetPath = Join-Path $Runtime ($frameId + ".received.packet.json")
$plainPath = Join-Path $Runtime ($frameId + ".plaintext.txt")
[IO.File]::WriteAllText($packetPath, ($json + [string][char]10), $enc)
[IO.File]::WriteAllText($plainPath, ([Text.Encoding]::UTF8.GetString($plainBytes) + [string][char]10), $enc)

$summary = Join-Path $RunRoot "summary.txt"
$summaryLines = New-Object System.Collections.Generic.List[string]
[void]$summaryLines.Add("frame_id=" + $frameId)
[void]$summaryLines.Add("packet_path=" + $packetPath)
[void]$summaryLines.Add("plaintext_path=" + $plainPath)
[IO.File]::WriteAllText($summary, (($summaryLines.ToArray() -join [string][char]10) + [string][char]10), $enc)

Write-Host ("VTP_UDP_WIRE_LISTEN_OK: " + $frameId)
Write-Host ("VTP_UDP_WIRE_RECEIVED_PACKET: " + $packetPath)
Write-Host ("VTP_UDP_WIRE_SELFTEST_RUN: " + $RunRoot)
Write-Host "VTP_UDP_WIRE_SELFTEST_OK"
