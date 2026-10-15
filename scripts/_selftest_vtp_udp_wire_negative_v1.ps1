param(
  [string]$RepoRoot = ".",
  [string]$To = "node-beta",
  [int]$Port = 47733
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path

# Precondition: the demo registry and an open demo session (the wire bindings come from it).
& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\courier_seed_demo_registry_v1.ps1") -RepoRoot $RepoRoot -RecipientNodeId $To | Out-Null
if($LASTEXITCODE -ne 0){ throw "VTP_WIRE_SELFTEST_FAIL:SEED_REGISTRY" }
& ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\courier_open_session_v1.ps1") -RepoRoot $RepoRoot -SessionId "session-alpha-beta-001" -SenderNodeId "node-alpha" -RecipientNodeId $To -NetworkId "courier-internal-net-v1" -SessionRole "message-delivery" | Out-Null
if($LASTEXITCODE -ne 0){ throw "VTP_WIRE_SELFTEST_FAIL:OPEN_SESSION" }
$Scripts = Join-Path $RepoRoot "scripts"
$RunRoot = Join-Path $RepoRoot ("proofs\wire_negative_selftest\" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ"))
[void][IO.Directory]::CreateDirectory($RunRoot)

$ps = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$send = Join-Path $Scripts "vtp_udp_wire_send_v1.ps1"
$ingest = Join-Path $Scripts "vtp_udp_wire_ingest_once_v1.ps1"
$keyLib = Join-Path $Scripts "vtp_wire_key_envelope_v1.ps1"

if(-not (Test-Path -LiteralPath $send -PathType Leaf)){ throw "VTP_WIRE_NEGATIVE_FAIL:MISSING_SEND" }
if(-not (Test-Path -LiteralPath $ingest -PathType Leaf)){ throw "VTP_WIRE_NEGATIVE_FAIL:MISSING_INGEST" }
if(-not (Test-Path -LiteralPath $keyLib -PathType Leaf)){ throw "VTP_WIRE_NEGATIVE_FAIL:MISSING_KEY_LIB" }
. $keyLib

function Capture-GoodPacket {
  param([string]$OutPath)

  $udp = New-Object Net.Sockets.UdpClient($Port)
  $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
  try {
    $async = $udp.BeginReceive($null,$null)
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $send -RepoRoot $RepoRoot -To $To -HostName "127.0.0.1" -Port $Port -PlainText "{""message"":""negative vector base""}"
    if($LASTEXITCODE -ne 0){ throw "VTP_WIRE_NEGATIVE_FAIL:SEND_EXIT" }
    if(-not $async.AsyncWaitHandle.WaitOne(10000)){ throw "VTP_WIRE_NEGATIVE_FAIL:RECEIVE_TIMEOUT" }
    $bytes = $udp.EndReceive($async,[ref]$remote)
  } finally {
    $udp.Close()
  }

  [IO.File]::WriteAllBytes($OutPath,$bytes)
}

function B64([byte[]]$Bytes){
  return [Convert]::ToBase64String($Bytes)
}

function Recompute-Tag {
  param($Packet)

  $headerJson = ($Packet.header | ConvertTo-Json -Depth 20 -Compress)
  $headerBytes = [Text.Encoding]::UTF8.GetBytes($headerJson)
  $iv = [Convert]::FromBase64String([string]$Packet.iv_b64)
  $cipherBytes = [Convert]::FromBase64String([string]$Packet.ciphertext_b64)
  $macKey = Get-VtpWireKeyBytes -RepoRoot $RepoRoot -RecipientNodeId $To -Purpose "hmac"

  $macInput = New-Object byte[] ($headerBytes.Length + $iv.Length + $cipherBytes.Length)
  [Array]::Copy($headerBytes,0,$macInput,0,$headerBytes.Length)
  [Array]::Copy($iv,0,$macInput,$headerBytes.Length,$iv.Length)
  [Array]::Copy($cipherBytes,0,$macInput,$headerBytes.Length + $iv.Length,$cipherBytes.Length)

  $hmac = New-Object Security.Cryptography.HMACSHA256(,$macKey)
  try {
    return $hmac.ComputeHash($macInput)
  } finally {
    $hmac.Dispose()
  }
}

function Write-PacketJson {
  param($Packet,[string]$Path)
  $json = $Packet | ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllText($Path, ($json + [string][char]10), [Text.UTF8Encoding]::new($false))
}

function Expect-IngestFail {
  param(
    [string]$Name,
    [string]$PacketPath,
    [string]$ExpectedToken
  )

  $safeName = ($Name -replace "[^A-Za-z0-9_.-]","_")
  $stdoutPath = Join-Path $RunRoot ($safeName + ".stdout.txt")
  $stderrPath = Join-Path $RunRoot ($safeName + ".stderr.txt")

  $childArgs = @(
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $ingest,
    "-RepoRoot",
    $RepoRoot,
    "-NodeId",
    $To,
    "-PacketPath",
    $PacketPath
  )

  $startArgs = @{ FilePath = $ps; ArgumentList = $childArgs; RedirectStandardOutput = $stdoutPath; RedirectStandardError = $stderrPath; PassThru = $true }
if($env:OS -eq "Windows_NT"){ $startArgs.WindowStyle = "Hidden" }
$proc = Start-Process @startArgs
  $proc.WaitForExit()

  $code = $proc.ExitCode
  $stdout = ""
  $stderr = ""

  if(Test-Path -LiteralPath $stdoutPath -PathType Leaf){
    $stdout = Get-Content -LiteralPath $stdoutPath -Raw
  }

  if(Test-Path -LiteralPath $stderrPath -PathType Leaf){
    $stderr = Get-Content -LiteralPath $stderrPath -Raw
  }

  $text = $stdout + "`n" + $stderr

  if($code -eq 0){
    throw ("VTP_WIRE_NEGATIVE_FAIL:" + $Name + ":UNEXPECTED_SUCCESS")
  }

  if($text -notmatch [regex]::Escape($ExpectedToken)){
    Write-Host $text
    throw ("VTP_WIRE_NEGATIVE_FAIL:" + $Name + ":EXPECTED_TOKEN_MISSING:" + $ExpectedToken)
  }

  Write-Host ("VTP_WIRE_NEGATIVE_EXPECTED_FAIL_OK: " + $Name + ":" + $ExpectedToken)
}

$goodPath = Join-Path $RunRoot "good.packet.json"
Capture-GoodPacket -OutPath $goodPath
$goodPacket = Get-Content -LiteralPath $goodPath -Raw | ConvertFrom-Json

$badMagic = Get-Content -LiteralPath $goodPath -Raw | ConvertFrom-Json
$badMagic.header.magic = "BAD1"
$badMagicPath = Join-Path $RunRoot "bad_magic.packet.json"
Write-PacketJson -Packet $badMagic -Path $badMagicPath
Expect-IngestFail -Name "bad-magic" -PacketPath $badMagicPath -ExpectedToken "VTP_UDP_WIRE_INGEST_FAIL:BAD_MAGIC"

$badTag = Get-Content -LiteralPath $goodPath -Raw | ConvertFrom-Json
$badTag.tag_b64 = B64 (New-Object byte[] 32)
$badTagPath = Join-Path $RunRoot "bad_tag.packet.json"
Write-PacketJson -Packet $badTag -Path $badTagPath
Expect-IngestFail -Name "bad-auth-tag" -PacketPath $badTagPath -ExpectedToken "VTP_UDP_WIRE_INGEST_FAIL:BAD_AUTH_TAG"

$badHash = Get-Content -LiteralPath $goodPath -Raw | ConvertFrom-Json
$badHash.header.payload_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
$badHash.tag_b64 = B64 (Recompute-Tag -Packet $badHash)
$badHashPath = Join-Path $RunRoot "bad_payload_hash.packet.json"
Write-PacketJson -Packet $badHash -Path $badHashPath
Expect-IngestFail -Name "bad-payload-hash" -PacketPath $badHashPath -ExpectedToken "VTP_UDP_WIRE_INGEST_FAIL:PAYLOAD_HASH_MISMATCH"

function Sha256HexText([string]$t){ $sha=[Security.Cryptography.SHA256]::Create(); try { return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t)) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $sha.Dispose() } }

$unknownSession = Get-Content -LiteralPath $goodPath -Raw | ConvertFrom-Json
$unknownSession.header.session_id_hash = Sha256HexText "session-not-registered"
$unknownSessionPath = Join-Path $RunRoot "unknown_session.packet.json"
Write-PacketJson -Packet $unknownSession -Path $unknownSessionPath
Expect-IngestFail -Name "unknown-session" -PacketPath $unknownSessionPath -ExpectedToken "VTP_UDP_WIRE_INGEST_FAIL:UNKNOWN_SESSION"

$wrongSender = Get-Content -LiteralPath $goodPath -Raw | ConvertFrom-Json
$wrongSender.header.sender_node_id_hash = Sha256HexText "node-mallory"
$wrongSenderPath = Join-Path $RunRoot "wrong_sender.packet.json"
Write-PacketJson -Packet $wrongSender -Path $wrongSenderPath
Expect-IngestFail -Name "wrong-sender-binding" -PacketPath $wrongSenderPath -ExpectedToken "VTP_UDP_WIRE_INGEST_FAIL:SENDER_BINDING_MISMATCH"

$oversize = Join-Path $RunRoot "oversize.packet.json"
[IO.File]::WriteAllBytes($oversize,(New-Object byte[] (1048576 + 1)))
Expect-IngestFail -Name "oversize-packet" -PacketPath $oversize -ExpectedToken "VTP_UDP_WIRE_INGEST_FAIL:PACKET_TOO_LARGE"

# Replay: the authentic packet is accepted once, then refused.
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ingest -RepoRoot $RepoRoot -NodeId $To -PacketPath $goodPath *> (Join-Path $RunRoot "good.ingest.txt")
if($LASTEXITCODE -ne 0){ throw "VTP_WIRE_NEGATIVE_FAIL:GOOD_PACKET_NOT_INGESTED" }
Expect-IngestFail -Name "replayed-packet" -PacketPath $goodPath -ExpectedToken "VTP_UDP_WIRE_INGEST_FAIL:REPLAY_DETECTED"

Write-Host ("VTP_WIRE_NEGATIVE_SELFTEST_RUN: " + $RunRoot)
Write-Host "VTP_WIRE_NEGATIVE_SELFTEST_OK"
