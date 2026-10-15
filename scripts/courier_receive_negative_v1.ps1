param(
  [string]$RepoRoot = ".",
  [string]$NodeId = "node-beta"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$Receive = Join-Path $RepoRoot "scripts\courier_receive_message_v1.ps1"
$RunRoot = Join-Path $RepoRoot ("proofs\product_receive_negative\" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ"))
$TempReceipt = Join-Path $RunRoot "covenant_courier_product.no_unaccepted_sent.ndjson"

[void][IO.Directory]::CreateDirectory($RunRoot)

if(-not (Test-Path -LiteralPath $Receive -PathType Leaf)){
  throw "COVENANT_COURIER_RECEIVE_NEGATIVE_FAIL:MISSING_RECEIVE_SCRIPT"
}

$frameId = "frame-product-negative-already-accepted"
$messageId = "ccmsg-product-negative-already-accepted"
$payloadSha = "0000000000000000000000000000000000000000000000000000000000000000"

$sent = [ordered]@{
  schema = "covenant_courier.product_receipt.v1"
  receipt_id = "ccreceipt-negative-sent"
  message_id = $messageId
  event_type = "covenant_courier.product.send.v1"
  time_utc = (Get-Date).ToUniversalTime().ToString("o")
  frame_id = $frameId
  payload_sha256 = $payloadSha
  decision = "sent"
  reason_code = $null
}

$accepted = [ordered]@{
  schema = "covenant_courier.product_receipt.v1"
  receipt_id = "ccreceipt-negative-accepted"
  message_id = $messageId
  event_type = "covenant_courier.product.accept.v1"
  time_utc = (Get-Date).ToUniversalTime().ToString("o")
  frame_id = $frameId
  payload_sha256 = $payloadSha
  decision = "accepted"
  reason_code = "VTP_POLICY_ALLOW"
}

$lines = @(
  ($sent | ConvertTo-Json -Depth 20 -Compress),
  ($accepted | ConvertTo-Json -Depth 20 -Compress)
)

[IO.File]::WriteAllText($TempReceipt, (($lines -join [string][char]10) + [string][char]10), [Text.UTF8Encoding]::new($false))

$ps = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$stdoutPath = Join-Path $RunRoot "receive-negative.stdout.txt"
$stderrPath = Join-Path $RunRoot "receive-negative.stderr.txt"

$childArgs = @(
  "-NoProfile",
  "-NonInteractive",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  $Receive,
  "-RepoRoot",
  $RepoRoot,
  "-NodeId",
  $NodeId,
  "-ProductReceiptPath",
  $TempReceipt
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
  Write-Host $text.Trim()
  throw "COVENANT_COURIER_RECEIVE_NEGATIVE_FAIL:UNEXPECTED_SUCCESS"
}

$expected = "COURIER_RECEIVE_FAIL:NO_UNACCEPTED_SENT_PRODUCT_FRAME"

if($text -notmatch [regex]::Escape($expected)){
  Write-Host $text.Trim()
  throw ("COVENANT_COURIER_RECEIVE_NEGATIVE_FAIL:EXPECTED_TOKEN_MISSING:" + $expected)
}

Write-Host ("COVENANT_COURIER_RECEIVE_NEGATIVE_EXPECTED_FAIL_OK: " + $expected)
Write-Host ("COVENANT_COURIER_RECEIVE_NEGATIVE_RUN: " + $RunRoot)
Write-Host "COVENANT_COURIER_RECEIVE_NEGATIVE_OK"
