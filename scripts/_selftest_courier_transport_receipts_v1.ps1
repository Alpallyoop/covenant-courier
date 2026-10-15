param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$Pos   = Join-Path $PSScriptRoot "_selftest_courier_node_to_node_positive_v1.ps1"
$Neg   = Join-Path $PSScriptRoot "_selftest_courier_node_to_node_negative_closed_session_v1.ps1"

$ReceiptPath = Join-Path $RepoRoot "proofs\receipts\courier_transport.ndjson"
if(Test-Path -LiteralPath $ReceiptPath){
  Remove-Item -LiteralPath $ReceiptPath -Force
}

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Pos -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("COURIER_RECEIPT_SELFTEST_FAIL:POS_EXIT_" + $LASTEXITCODE) }

& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Neg -RepoRoot $RepoRoot
if($LASTEXITCODE -ne 0){ throw ("COURIER_RECEIPT_SELFTEST_FAIL:NEG_EXIT_" + $LASTEXITCODE) }

if(-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)){
  throw "COURIER_RECEIPT_SELFTEST_FAIL:MISSING_RECEIPT_FILE"
}

$lines = @(Get-Content -LiteralPath $ReceiptPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if($lines.Count -lt 3){
  throw "COURIER_RECEIPT_SELFTEST_FAIL:TOO_FEW_RECEIPTS"
}

$joined = ($lines -join "`n")
if($joined -notmatch 'courier\.transport\.send\.v1'){
  throw "COURIER_RECEIPT_SELFTEST_FAIL:MISSING_SEND_RECEIPT"
}
if($joined -notmatch 'courier\.transport\.accept\.v1'){
  throw "COURIER_RECEIPT_SELFTEST_FAIL:MISSING_ACCEPT_RECEIPT"
}
if($joined -notmatch 'courier\.transport\.reject\.v1'){
  throw "COURIER_RECEIPT_SELFTEST_FAIL:MISSING_REJECT_RECEIPT"
}

Write-Host "COURIER_RECEIPT_SELFTEST_OK"
