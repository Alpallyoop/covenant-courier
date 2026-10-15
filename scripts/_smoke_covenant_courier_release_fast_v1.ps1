param(
  [string]$RepoRoot = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path $RepoRoot).Path
$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Courier = Join-Path $RepoRoot "courier.ps1"
$Vtp = Join-Path $RepoRoot "vtp.ps1"
$VtpVerify = Join-Path $RepoRoot "vtp_verify_all.ps1"

function Fail([string]$Code){
  throw $Code
}

function Parse-GateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){
    Fail ("FAST_SMOKE_FAIL:MISSING_SCRIPT:" + $Path)
  }

  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  if($err -and $err.Count -gt 0){
    Fail ("FAST_SMOKE_FAIL:PARSE:" + $Path + ":" + $err[0].ToString())
  }

  Write-Host ("FAST_SMOKE_PARSE_OK: " + $Path)
}

function Require-File([string]$Rel){
  $path = Join-Path $RepoRoot $Rel
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){
    Fail ("FAST_SMOKE_FAIL:MISSING_REQUIRED_FILE:" + $Rel)
  }
  Write-Host ("FAST_SMOKE_REQUIRED_FILE_OK: " + $Rel)
}

function Require-Dir([string]$Rel){
  $path = Join-Path $RepoRoot $Rel
  if(-not (Test-Path -LiteralPath $path -PathType Container)){
    Fail ("FAST_SMOKE_FAIL:MISSING_REQUIRED_DIR:" + $Rel)
  }
  Write-Host ("FAST_SMOKE_REQUIRED_DIR_OK: " + $Rel)
}

function Run-Courier([string]$Command){
  Write-Host ("FAST_SMOKE_STEP_START: " + $Command)

  Push-Location $RepoRoot
  try {
    $out = & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Courier $Command 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }

  $text = ($out | Out-String).Trim()

  if($exitCode -ne 0){
    Write-Host $text
    Fail ("FAST_SMOKE_FAIL:COMMAND_EXIT:" + $Command + ":" + $exitCode)
  }

  if(-not [string]::IsNullOrWhiteSpace($text)){
    Write-Host $text
  }

  Write-Host ("FAST_SMOKE_STEP_OK: " + $Command)
}

Parse-GateFile $Courier
Parse-GateFile $Vtp
Parse-GateFile $VtpVerify

foreach($dir in @(
  "docs",
  "schemas",
  "scripts",
  "test_vectors",
  "policy",
  "trust"
)){
  Require-Dir $dir
}

foreach($file in @(
  "README.md",
  "courier.ps1",
  "vtp.ps1",
  "vtp_full_green.ps1",
  "vtp_verify_all.ps1",
  "policy\vtp_dlp_policy_v1.json",
  "trust\allowed_signers",
  "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json",
  "test_vectors\courier_v1\transport_hardening\prep\message.tokenized.json.sig"
)){
  Require-File $file
}

Run-Courier "schema-test"
Run-Courier "prepare"
Run-Courier "send"
Run-Courier "receive-negative"
Run-Courier "receive"
Run-Courier "receipts"
Run-Courier "receipt-chain"

Write-Host "COVENANT_COURIER_RELEASE_FAST_SMOKE_OK"
