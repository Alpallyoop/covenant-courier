param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunRoot = Join-Path $RepoRoot ("proofs\conformance\vtp_conformance_" + $RunId)
$StdoutPath = Join-Path $RunRoot "stdout.log"
$StderrPath = Join-Path $RunRoot "stderr.log"
$MetaPath   = Join-Path $RunRoot "meta.json"
$ShaPath    = Join-Path $RunRoot "sha256sums.txt"

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

function Run-Step([string]$Name,[string]$Script,[string[]]$RequiredTokens){
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
    throw ("VTP_CONFORMANCE_FAIL:" + $Name + "_EXIT_" + $p.ExitCode)
  }

  foreach($token in $RequiredTokens){
    if($stdout -notmatch [regex]::Escape($token)){
      throw ("VTP_CONFORMANCE_FAIL:" + $Name + ":MISSING_TOKEN:" + $token)
    }
  }
}

Ensure-Dir $RunRoot
New-Item -ItemType File -Path $StdoutPath -Force | Out-Null
New-Item -ItemType File -Path $StderrPath -Force | Out-Null

$steps = @(
  @{ name="tier0"; script=Join-Path $PSScriptRoot "_RUN_vtp_tier0_full_green_v1.ps1"; tokens=@("VTP_TIER0_FULL_GREEN") },
  @{ name="trust_bootstrap"; script=Join-Path $PSScriptRoot "_selftest_vtp_trust_bootstrap_v1.ps1"; tokens=@("VTP_TRUST_BOOTSTRAP_SELFTEST_OK") },
  @{ name="secure_join_encrypted"; script=Join-Path $PSScriptRoot "_selftest_vtp_secure_join_encrypted_v1.ps1"; tokens=@("VTP_SECURE_JOIN_ENCRYPTED_SELFTEST_OK") },
  @{ name="crypto_negatives"; script=Join-Path $PSScriptRoot "_selftest_vtp_secure_crypto_negative_v1.ps1"; tokens=@("VTP_SECURE_CRYPTO_NEGATIVE_SELFTEST_OK") },
  @{ name="replay_guard"; script=Join-Path $PSScriptRoot "_selftest_vtp_replay_guard_v1.ps1"; tokens=@("VTP_REPLAY_GUARD_SELFTEST_OK") },
  @{ name="session_key_upgrade"; script=Join-Path $PSScriptRoot "_selftest_vtp_session_key_upgrade_v1.ps1"; tokens=@("VTP_SESSION_KEY_UPGRADE_SELFTEST_OK") },
  @{ name="outbox_persistence"; script=Join-Path $PSScriptRoot "_selftest_vtp_outbox_persistence_v1.ps1"; tokens=@("VTP_OUTBOX_PERSISTENCE_SELFTEST_OK") },
  @{ name="node_loop"; script=Join-Path $PSScriptRoot "_selftest_vtp_node_loop_v1.ps1"; tokens=@("VTP_NODE_LOOP_SELFTEST_OK") },
  @{ name="secure_full_green"; script=Join-Path $PSScriptRoot "_RUN_vtp_secure_full_green_v1.ps1"; tokens=@("VTP_SECURE_FULL_GREEN") }
)

foreach($s in $steps){
  Run-Step -Name $s.name -Script $s.script -RequiredTokens $s.tokens
}

$meta = [ordered]@{
  schema = "vtp.conformance.run.v1"
  run_id = $RunId
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  protocol = "VTP"
  version = "v1"
  implementation = "Courier Reference Engine"
  required_tokens = @(
    "VTP_TIER0_FULL_GREEN",
    "VTP_TRUST_BOOTSTRAP_SELFTEST_OK",
    "VTP_SECURE_JOIN_ENCRYPTED_SELFTEST_OK",
    "VTP_SECURE_CRYPTO_NEGATIVE_SELFTEST_OK",
    "VTP_REPLAY_GUARD_SELFTEST_OK",
    "VTP_SESSION_KEY_UPGRADE_SELFTEST_OK",
    "VTP_OUTBOX_PERSISTENCE_SELFTEST_OK",
    "VTP_NODE_LOOP_SELFTEST_OK",
    "VTP_SECURE_FULL_GREEN"
  )
  result = "PASS"
  final_token = "VTP_CONFORMANCE_V1_PASS"
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
Write-Host "VTP_CONFORMANCE_V1_PASS"
