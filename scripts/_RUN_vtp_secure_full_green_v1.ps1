param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$Tier0      = Join-Path $PSScriptRoot "_RUN_vtp_tier0_full_green_v1.ps1"
$Trust      = Join-Path $PSScriptRoot "_selftest_vtp_trust_bootstrap_v1.ps1"
$Secure     = Join-Path $PSScriptRoot "_selftest_vtp_secure_join_encrypted_v1.ps1"
$CryptoNeg  = Join-Path $PSScriptRoot "_selftest_vtp_secure_crypto_negative_v1.ps1"
$Replay     = Join-Path $PSScriptRoot "_selftest_vtp_replay_guard_v1.ps1"
$SessionKey = Join-Path $PSScriptRoot "_selftest_vtp_session_key_upgrade_v1.ps1"
$Outbox     = Join-Path $PSScriptRoot "_selftest_vtp_outbox_persistence_v1.ps1"
$NodeLoop   = Join-Path $PSScriptRoot "_selftest_vtp_node_loop_v1.ps1"

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunRoot = Join-Path $RepoRoot ("proofs\secure_full_green\vtp_secure_full_green_" + $RunId)
$StdoutPath = Join-Path $RunRoot "stdout.log"
$StderrPath = Join-Path $RunRoot "stderr.log"
$MetaPath = Join-Path $RunRoot "meta.json"
$ShaPath = Join-Path $RunRoot "sha256sums.txt"

function Ensure-Dir([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){ [void][System.IO.Directory]::CreateDirectory($Path) }
}

function Get-Sha256Hex([string]$Path){
  $sha=[System.Security.Cryptography.SHA256]::Create()
  $fs=[System.IO.File]::OpenRead($Path)
  try { $h=$sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-RelPath([string]$Root,[string]$Path){
  return $Path.Substring($Root.Length).TrimStart('\','/').Replace('\','/')
}

function Run-Step([string]$Name,[string]$Script){
  $out = Join-Path $RunRoot ($Name + ".stdout.tmp")
  $err = Join-Path $RunRoot ($Name + ".stderr.tmp")

  $p = Start-Process -FilePath $PSExe -ArgumentList @(
    "-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass",
    "-File",$Script,
    "-RepoRoot",$RepoRoot
  ) -RedirectStandardOutput $out -RedirectStandardError $err -Wait -PassThru

  $stdout = ""
  $stderr = ""
  if(Test-Path -LiteralPath $out){ $stdout = Get-Content -LiteralPath $out -Raw }
  if(Test-Path -LiteralPath $err){ $stderr = Get-Content -LiteralPath $err -Raw }

  Add-Content -LiteralPath $StdoutPath -Value ("===== " + $Name + " =====`n" + $stdout)
  Add-Content -LiteralPath $StderrPath -Value ("===== " + $Name + " =====`n" + $stderr)

  if($p.ExitCode -ne 0){
    throw ("VTP_SECURE_FULL_GREEN_FAIL:" + $Name + "_EXIT_" + $p.ExitCode)
  }
}

Ensure-Dir $RunRoot
New-Item -ItemType File -Path $StdoutPath -Force | Out-Null
New-Item -ItemType File -Path $StderrPath -Force | Out-Null

Run-Step "tier0" $Tier0
Run-Step "trust_bootstrap" $Trust
Run-Step "secure_join_encrypted" $Secure
Run-Step "crypto_negatives" $CryptoNeg
Run-Step "replay_guard" $Replay
Run-Step "session_key_upgrade" $SessionKey
Run-Step "outbox_persistence" $Outbox
Run-Step "node_loop" $NodeLoop

$meta = [ordered]@{
  schema = "vtp.secure_full_green.run.v1"
  run_id = $RunId
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  implementation = "Courier Reference Engine"
  protocol_name = "Verifiable Transport Protocol"
  protocol_version = "v1"
  required_tokens = @(
    "VTP_TIER0_FULL_GREEN",
    "VTP_TRUST_BOOTSTRAP_SELFTEST_OK",
    "VTP_SECURE_JOIN_ENCRYPTED_SELFTEST_OK",
    "VTP_SECURE_CRYPTO_NEGATIVE_SELFTEST_OK",
    "VTP_REPLAY_GUARD_SELFTEST_OK",
    "VTP_SESSION_KEY_UPGRADE_SELFTEST_OK",
    "VTP_OUTBOX_PERSISTENCE_SELFTEST_OK",
    "VTP_NODE_LOOP_SELFTEST_OK"
  )
  final_token = "VTP_SECURE_FULL_GREEN"
}

$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($MetaPath, (($meta | ConvertTo-Json -Depth 20 -Compress) + "`n"), $enc)

$files = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -File | Where-Object { $_.FullName -ne $ShaPath } | Sort-Object FullName)
$lines = New-Object System.Collections.Generic.List[string]
foreach($f in $files){
  [void]$lines.Add((Get-Sha256Hex $f.FullName) + "  " + (Get-RelPath $RunRoot $f.FullName))
}
[System.IO.File]::WriteAllText($ShaPath, (($lines.ToArray() -join "`n") + "`n"), $enc)

Write-Host ("RUN_ROOT: " + $RunRoot)
Write-Host ("SHA256SUMS_OK: " + $ShaPath)
Write-Host "VTP_SECURE_FULL_GREEN"
