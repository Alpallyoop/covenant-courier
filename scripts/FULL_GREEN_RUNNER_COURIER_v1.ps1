param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Self  = Join-Path $RepoRoot "scripts\_selftest_courier_v1.ps1"
$Lib   = Join-Path $RepoRoot "scripts\_lib_courier_v1.ps1"

. $Lib

function Fail([string]$Code){
  throw $Code
}

function Get-FileSha256Hex([string]$Path){
  if(-not (Test-Path -LiteralPath $Path)){
    return $null
  }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if(-not (Test-Path -LiteralPath $PSExe)){
  Fail ("RUNNER_FAIL:MISSING_POWERSHELL:" + $PSExe)
}
if(-not (Test-Path -LiteralPath $Self)){
  Fail ("RUNNER_FAIL:MISSING_SELFTEST:" + $Self)
}

$RunUtc = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$RunDir = Join-Path $RepoRoot ("proofs\receipts\courier_tier0\" + $RunUtc)

Ensure-Dir $RunDir

$StdOutPath = Join-Path $RunDir "stdout.txt"
$StdErrPath = Join-Path $RunDir "stderr.txt"
$SummaryPath = Join-Path $RunDir "summary.json"
$SumsPath = Join-Path $RunDir "sha256sums.txt"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $PSExe
$psi.Arguments = (
  '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f
  $Self, $RepoRoot
)
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi

[void]$proc.Start()
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

Write-Utf8NoBomLf $StdOutPath $stdout
Write-Utf8NoBomLf $StdErrPath $stderr

if($proc.ExitCode -ne 0){
  $summary = [ordered]@{
    schema        = "courier.run.summary.v1"
    result        = "FAIL"
    run_utc       = $RunUtc
    repo_root     = $RepoRoot
    selftest_path = $Self
    exit_code     = $proc.ExitCode
    stdout_rel    = "proofs/receipts/courier_tier0/$RunUtc/stdout.txt"
    stderr_rel    = "proofs/receipts/courier_tier0/$RunUtc/stderr.txt"
  }

  Write-JsonCanonical $SummaryPath $summary

  $sumLines = New-Object System.Collections.Generic.List[string]
  foreach($p in @($StdOutPath,$StdErrPath,$SummaryPath,$Self)){
    $h = Get-FileSha256Hex $p
    if($h){
      $rel = $p.Substring($RepoRoot.Length).TrimStart('\','/').Replace('\','/')
      [void]$sumLines.Add(($h + " *" + $rel))
    }
  }
  Write-Utf8NoBomLf $SumsPath (($sumLines.ToArray()) -join "`n")

  Append-Receipt $RepoRoot ([ordered]@{
    schema        = "courier.receipt.v1"
    event_type    = "courier.tier0.runner.v1"
    timestamp_utc = [DateTime]::UtcNow.ToString("o")
    details       = [ordered]@{
      result       = "FAIL"
      run_utc      = $RunUtc
      exit_code    = $proc.ExitCode
      stdout_rel   = "proofs/receipts/courier_tier0/$RunUtc/stdout.txt"
      stderr_rel   = "proofs/receipts/courier_tier0/$RunUtc/stderr.txt"
      summary_rel  = "proofs/receipts/courier_tier0/$RunUtc/summary.json"
      sha256sums_rel = "proofs/receipts/courier_tier0/$RunUtc/sha256sums.txt"
      selftest_sha256 = Get-FileSha256Hex $Self
    }
  })

  Fail ("RUNNER_FAIL:SELFTEST_EXIT_" + $proc.ExitCode)
}

if($stdout -notmatch 'COURIER_SELFTEST_OK'){
  Fail "RUNNER_FAIL:MISSING_SELFTEST_TOKEN"
}

$summary = [ordered]@{
  schema        = "courier.run.summary.v1"
  result        = "FULL_GREEN"
  run_utc       = $RunUtc
  repo_root     = $RepoRoot
  selftest_path = $Self
  exit_code     = 0
  stdout_rel    = "proofs/receipts/courier_tier0/$RunUtc/stdout.txt"
  stderr_rel    = "proofs/receipts/courier_tier0/$RunUtc/stderr.txt"
}

Write-JsonCanonical $SummaryPath $summary

$sumLines = New-Object System.Collections.Generic.List[string]
foreach($p in @($StdOutPath,$StdErrPath,$SummaryPath,$Self)){
  $h = Get-FileSha256Hex $p
  if($h){
    $rel = $p.Substring($RepoRoot.Length).TrimStart('\','/').Replace('\','/')
    [void]$sumLines.Add(($h + " *" + $rel))
  }
}
Write-Utf8NoBomLf $SumsPath (($sumLines.ToArray()) -join "`n")

Append-Receipt $RepoRoot ([ordered]@{
  schema        = "courier.receipt.v1"
  event_type    = "courier.tier0.runner.v1"
  timestamp_utc = [DateTime]::UtcNow.ToString("o")
  details       = [ordered]@{
    result         = "FULL_GREEN"
    run_utc        = $RunUtc
    exit_code      = 0
    stdout_rel     = "proofs/receipts/courier_tier0/$RunUtc/stdout.txt"
    stderr_rel     = "proofs/receipts/courier_tier0/$RunUtc/stderr.txt"
    summary_rel    = "proofs/receipts/courier_tier0/$RunUtc/summary.json"
    sha256sums_rel = "proofs/receipts/courier_tier0/$RunUtc/sha256sums.txt"
    selftest_sha256 = Get-FileSha256Hex $Self
  }
})

Write-Host ("RUN_DIR: " + $RunDir)
Write-Host "COURIER_TIER0_FULL_GREEN"