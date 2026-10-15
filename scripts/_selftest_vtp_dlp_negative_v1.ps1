param(
  [string]$RepoRoot = ".",
  [string]$NodeId = "node-beta"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$PolicyGate = Join-Path $RepoRoot "scripts\vtp_policy_gate_v1.ps1"
if(-not (Test-Path -LiteralPath $PolicyGate -PathType Leaf)){
  throw "VTP_DLP_NEGATIVE_FAIL:MISSING_POLICY_GATE"
}

$RunRoot = Join-Path $RepoRoot "runtime\dlp_selftest\negative_blocked_role"
$FrameDir = Join-Path $RunRoot "frame-dlp-negative-blocked-role"

if(Test-Path -LiteralPath $RunRoot){
  Remove-Item -LiteralPath $RunRoot -Recurse -Force
}
[void][IO.Directory]::CreateDirectory($FrameDir)

$frame = [ordered]@{
  schema = "courier.transport_frame.v2"
  frame_id = "frame-dlp-negative-blocked-role"
  created_utc = "2026-01-01T00:00:00.0000000Z"
  sender_identity = "courier-local@covenant"
  recipient_identity = "courier-local@covenant"
  sender_node_id = "node-alpha"
  recipient_node_id = $NodeId
  network_id = "courier-internal-net-v1"
  session_id = "session-alpha-beta-001"
  sender_role = "blocked"
  message_rel = "payload/message.tokenized.json"
  signature_rel = "payload/message.tokenized.json.sig"
  payload_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
}

[IO.File]::WriteAllText(
  (Join-Path $FrameDir "frame.json"),
  (($frame | ConvertTo-Json -Depth 20 -Compress) + "`n"),
  [Text.UTF8Encoding]::new($false)
)

$out = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PolicyGate -RepoRoot $RepoRoot -FrameDir $FrameDir 2>&1
$text = ($out | Out-String).Trim()
$code = $LASTEXITCODE

if($code -ne 42){
  throw ("VTP_DLP_NEGATIVE_FAIL:EXPECTED_DENY_EXIT_42:GOT_" + $code + ":" + $text)
}

if($text -notmatch "VTP_POLICY_DENY:SENDER_ROLE_DENIED:blocked"){
  throw ("VTP_DLP_NEGATIVE_FAIL:WRONG_REASON:" + $text)
}

Write-Host "VTP_DLP_NEGATIVE_REJECT_OK"