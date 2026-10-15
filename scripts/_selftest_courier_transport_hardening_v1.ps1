param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$Cli        = Join-Path $RepoRoot "scripts\courier_cli_v1.ps1"
$Send       = Join-Path $RepoRoot "scripts\courier_transport_send_v1.ps1"
$Listen     = Join-Path $RepoRoot "scripts\courier_transport_listen_v1.ps1"
$Bootstrap  = Join-Path $RepoRoot "scripts\courier_bootstrap_local_trust_v1.ps1"
$Sign       = Join-Path $RepoRoot "scripts\courier_sign_message_v1.ps1"
$ConfigPath = Join-Path $RepoRoot "test_vectors\courier_v1\transport\listener.config.json"

$ComposeIn = Join-Path $RepoRoot "test_vectors\courier_v1\pipeline\compose.input.json"
$DictIn    = Join-Path $RepoRoot "policies\lexicon\default_dictionary_v1.json"

$Root      = Join-Path $RepoRoot "test_vectors\courier_v1\transport_hardening"
$Prep      = Join-Path $Root "prep"
$Drop      = Join-Path $Root "drop"
$Accepted  = Join-Path $Root "accepted"
$Rejected  = Join-Path $Root "rejected"
$Cfg       = Join-Path $Root "listener.config.json"

function Fail([string]$Code){
  throw $Code
}

function Run-ChildCapture {
  param(
    [Parameter(Mandatory=$true)][string]$File,
    [Parameter(Mandatory=$true)][string]$ArgumentString
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PSExe
  $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" {1}' -f $File, $ArgumentString)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  [pscustomobject]@{
    ExitCode = $p.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
    Text     = ($stdout + "`n" + $stderr)
  }
}

function Reset-Roots {
  foreach($p in @($Prep,$Drop,$Accepted,$Rejected)){
    if(Test-Path -LiteralPath $p){
      Remove-Item -LiteralPath $p -Recurse -Force
    }
    [void][System.IO.Directory]::CreateDirectory($p)
  }

  $cfgObj = [ordered]@{
    schema        = "courier.transport_listener_config.v1"
    listener_id   = "courier-hardening-listener"
    drop_root     = "test_vectors/courier_v1/transport_hardening/drop"
    accepted_root = "test_vectors/courier_v1/transport_hardening/accepted"
    rejected_root = "test_vectors/courier_v1/transport_hardening/rejected"
  }

  $cfgObj | ConvertTo-Json -Depth 20 -Compress | Set-Content -LiteralPath $Cfg -NoNewline
}

function Build-ValidPipeline {
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Cli `
    -RepoRoot $RepoRoot `
    -Command run-pipeline `
    -ComposePath $ComposeIn `
    -DictionaryPath $DictIn `
    -WorkRoot $Prep
  if($LASTEXITCODE -ne 0){
    Fail ("COURIER_TRANSPORT_HARDEN_FAIL:PIPELINE_EXIT_" + $LASTEXITCODE)
  }
}

function Bootstrap-Trust {
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Bootstrap `
    -RepoRoot $RepoRoot `
    -SignerIdentity "courier-local@covenant"
  if($LASTEXITCODE -ne 0){
    Fail ("COURIER_TRANSPORT_HARDEN_FAIL:BOOTSTRAP_LOCAL_EXIT_" + $LASTEXITCODE)
  }
}

# Registry preconditions: nodes, network and an open session for this test's frames.
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\_selftest_courier_registry_v1.ps1") -RepoRoot $RepoRoot | Out-Null
if($LASTEXITCODE -ne 0){ throw ("COURIER_TRANSPORT_HARDEN_FAIL:REGISTRY_EXIT_" + $LASTEXITCODE) }
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "scripts\courier_open_session_v1.ps1") -RepoRoot $RepoRoot -SessionId "session-transport-selftest-001" -SenderNodeId "node-alpha" -RecipientNodeId "node-beta" -NetworkId "courier-internal-net-v1" -SessionRole "message-delivery" | Out-Null
if($LASTEXITCODE -ne 0){ throw ("COURIER_TRANSPORT_HARDEN_FAIL:OPEN_SESSION_EXIT_" + $LASTEXITCODE) }

function Send-Frame([string]$MessagePath,[string]$SenderIdentity){
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Send `
    -RepoRoot $RepoRoot `
    -SenderNodeId "node-alpha" `
    -RecipientNodeId "node-beta" `
    -NetworkId "courier-internal-net-v1" `
    -SessionId "session-transport-selftest-001" `
    -SenderRole "message-delivery" `
    -MessagePath $MessagePath `
    -DropRoot $Drop `
    -SenderIdentity $SenderIdentity `
    -RecipientIdentity "recipient-a"
  if($LASTEXITCODE -ne 0){
    Fail ("COURIER_TRANSPORT_HARDEN_FAIL:SEND_EXIT_" + $LASTEXITCODE)
  }
}

function Listen-Once {
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Listen `
    -RepoRoot $RepoRoot `
    -ConfigPath $Cfg
  if($LASTEXITCODE -ne 0){
    Fail ("COURIER_TRANSPORT_HARDEN_FAIL:LISTEN_EXIT_" + $LASTEXITCODE)
  }
}

function Get-AcceptedCount {
  $dirs = @(Get-ChildItem -LiteralPath $Accepted -Directory -ErrorAction SilentlyContinue)
  return $dirs.Count
}

function Get-RejectedCount {
  $dirs = @(Get-ChildItem -LiteralPath $Rejected -Directory -ErrorAction SilentlyContinue)
  return $dirs.Count
}

function Get-OnlyDir([string]$RootPath){
  $dirs = @(Get-ChildItem -LiteralPath $RootPath -Directory)
  if($dirs.Count -ne 1){
    Fail ("COURIER_TRANSPORT_HARDEN_FAIL:EXPECTED_ONE_DIR:" + $RootPath + ":COUNT_" + $dirs.Count)
  }
  return $dirs[0]
}

Bootstrap-Trust

# 1) replay / duplicate frame -> reject duplicate
Reset-Roots
Build-ValidPipeline
$msgPath = Join-Path $Prep "message.tokenized.json"
Send-Frame $msgPath "courier-local@covenant"
Listen-Once
if((Get-AcceptedCount) -ne 1){
  Fail "COURIER_TRANSPORT_HARDEN_FAIL:REPLAY_SETUP_ACCEPT_COUNT"
}

$acceptedDir = Get-OnlyDir $Accepted
$replayDir   = Join-Path $Drop ($acceptedDir.Name + "-replay")
Copy-Item -LiteralPath $acceptedDir.FullName -Destination $replayDir -Recurse -Force
Listen-Once

if((Get-RejectedCount) -lt 1){
  Fail "COURIER_TRANSPORT_HARDEN_FAIL:REPLAY_NOT_REJECTED"
}
Write-Host "COURIER_TRANSPORT_HARDEN_OK: replay_duplicate -> REJECTED"

# 2) missing frame field -> reject
Reset-Roots
Build-ValidPipeline
Send-Frame (Join-Path $Prep "message.tokenized.json") "courier-local@covenant"
$frameDir = Get-OnlyDir $Drop
$frameJson = Join-Path $frameDir.FullName "frame.json"
$frameObj = Get-Content -Raw -LiteralPath $frameJson | ConvertFrom-Json
$frameObj.PSObject.Properties.Remove("payload_sha256")
$frameObj | ConvertTo-Json -Depth 50 -Compress | Set-Content -LiteralPath $frameJson -NoNewline
Listen-Once

if((Get-RejectedCount) -ne 1){
  Fail "COURIER_TRANSPORT_HARDEN_FAIL:MISSING_FIELD_NOT_REJECTED"
}
Write-Host "COURIER_TRANSPORT_HARDEN_OK: missing_frame_field -> REJECTED"

# 3) missing message artifact -> reject
Reset-Roots
Build-ValidPipeline
Send-Frame (Join-Path $Prep "message.tokenized.json") "courier-local@covenant"
$frameDir = Get-OnlyDir $Drop
$frameObj = Get-Content -Raw -LiteralPath (Join-Path $frameDir.FullName "frame.json") | ConvertFrom-Json
$msgArtifact = Join-Path $frameDir.FullName (($frameObj.message_rel) -replace '/','\')
Remove-Item -LiteralPath $msgArtifact -Force
Listen-Once

if((Get-RejectedCount) -ne 1){
  Fail "COURIER_TRANSPORT_HARDEN_FAIL:MISSING_ARTIFACT_NOT_REJECTED"
}
Write-Host "COURIER_TRANSPORT_HARDEN_OK: missing_message_artifact -> REJECTED"

# 4) wrong signer at transport boundary -> reject
Reset-Roots
Build-ValidPipeline

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Bootstrap `
  -RepoRoot $RepoRoot `
  -SignerIdentity "courier-other@covenant"
if($LASTEXITCODE -ne 0){
  Fail ("COURIER_TRANSPORT_HARDEN_FAIL:BOOTSTRAP_OTHER_EXIT_" + $LASTEXITCODE)
}

$otherMsg = Join-Path $Prep "message.tokenized.other.json"
Copy-Item -LiteralPath (Join-Path $Prep "message.tokenized.json") -Destination $otherMsg -Force
Copy-Item -LiteralPath ((Join-Path $Prep "message.tokenized.json") + ".sig") -Destination ($otherMsg + ".sig") -Force -ErrorAction SilentlyContinue
if(Test-Path -LiteralPath ($otherMsg + ".sig")){
  Remove-Item -LiteralPath ($otherMsg + ".sig") -Force
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $Sign `
  -RepoRoot $RepoRoot `
  -MessagePath $otherMsg `
  -SignerIdentity "courier-other@covenant"
if($LASTEXITCODE -ne 0){
  Fail ("COURIER_TRANSPORT_HARDEN_FAIL:SIGN_OTHER_EXIT_" + $LASTEXITCODE)
}

Send-Frame $otherMsg "courier-other@covenant"
Listen-Once

if((Get-RejectedCount) -ne 1){
  Fail "COURIER_TRANSPORT_HARDEN_FAIL:WRONG_SIGNER_NOT_REJECTED"
}
Write-Host "COURIER_TRANSPORT_HARDEN_OK: wrong_signer_boundary -> REJECTED"

Write-Host "COURIER_TRANSPORT_SUITE_ALL_GREEN"
